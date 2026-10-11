//! Invocation-local results for shared acyclic reference targets and scopes.
use super::*;
use std::cell::RefCell;
use tracking::Tracked;

pub(super) type Key = (usize, Value, usize);
const MAX_SCOPE_SLOTS: usize = 65536;
const MAX_ENTRIES: usize = 4096;
const MAX_ANNOTATION_SLOTS: usize = 65536;

// Evict old results instead of permanently refusing new results once an
// invocation reaches a limit. FIFO admission keeps later instance locations
// eligible for reuse, with constant expected work per admission/eviction.
struct Cache<K, T> {
    results: HashMap<K, (T, usize)>,
    order: std::collections::VecDeque<K>,
    slots: usize,
}
impl<K, T> Default for Cache<K, T> {
    fn default() -> Self {
        Self {
            results: HashMap::new(),
            order: std::collections::VecDeque::new(),
            slots: 0,
        }
    }
}
impl<K: Copy + Eq + std::hash::Hash, T: Clone> Cache<K, T> {
    fn get(&self, key: K) -> Option<T> {
        self.results.get(&key).map(|(result, _)| result.clone())
    }
    fn record(&mut self, key: K, result: &T, slots: usize, max_entries: usize) {
        // A single oversized result must not flush useful small results.
        if slots > MAX_ANNOTATION_SLOTS || self.results.contains_key(&key) {
            return;
        }
        while self.results.len() >= max_entries || slots > MAX_ANNOTATION_SLOTS - self.slots {
            let oldest = self.order.pop_front().unwrap();
            let (_, removed) = self.results.remove(&oldest).unwrap();
            self.slots -= removed;
        }
        self.results.insert(key, (result.clone(), slots));
        self.order.push_back(key);
        self.slots += slots;
    }
}

// Exact effective bindings identify a scope, rather than its stack address or
// a probabilistic digest. FIFO eviction bounds the signature buffers; IDs are
// never reused, so still-running evaluations can safely record older keys.
#[derive(Default)]
struct Scopes {
    bindings: HashMap<std::sync::Arc<[Option<usize>]>, usize>,
    order: std::collections::VecDeque<std::sync::Arc<[Option<usize>]>>,
    slots: usize,
    next_id: usize,
}
impl Scopes {
    fn intern(&mut self, bindings: Vec<Option<usize>>) -> Option<usize> {
        if let Some(&id) = self.bindings.get(bindings.as_slice()) {
            return Some(id);
        }
        if bindings.len() > MAX_SCOPE_SLOTS {
            return None;
        }
        let id = self.next_id.checked_add(1)?;
        while self.bindings.len() >= MAX_ENTRIES || bindings.len() > MAX_SCOPE_SLOTS - self.slots {
            let oldest = self.order.pop_front().unwrap();
            self.bindings.remove(oldest.as_ref());
            self.slots -= oldest.len();
        }
        let bindings: std::sync::Arc<[Option<usize>]> = bindings.into();
        self.slots += bindings.len();
        self.bindings.insert(bindings.clone(), id);
        self.order.push_back(bindings);
        self.next_id = id;
        Some(id)
    }
}

#[derive(Default)]
pub(super) struct Memo {
    verdicts: RefCell<Cache<Key, Verdict>>,
    scopes: RefCell<Scopes>,
    // None is tracked validity; Some(bool) is the diagnostic annotation policy.
    // Coverage results share both admission order and the allocation budget.
    coverage: RefCell<Cache<(Key, Option<bool>), Tracked>>,
}
impl Memo {
    pub(super) fn key(
        &self,
        engine: &Engine,
        node: usize,
        value: Value,
        depth: usize,
        context: scope::Context<'_>,
    ) -> Option<Key> {
        if !engine.memoizable[node] {
            return None;
        }
        if !engine.memo_contextual[node] {
            return Some((node, value, depth));
        }
        let scope = if engine.anchor_tables.len() == 1 {
            // The existing frame already retains the outermost binding.
            // Zero means unbound; compiled node IDs start at zero.
            context
                .scope
                .and_then(|frame| frame.primary_binding)
                .map_or(0, |target| target + 1)
        } else {
            let names = engine.anchor_tables.len();
            if names > MAX_SCOPE_SLOTS {
                return None;
            }
            let mut bindings = vec![None; names];
            let mut current = context.scope;
            while let Some(frame) = current {
                for (name, binding) in bindings.iter_mut().enumerate() {
                    if let Some(target) = engine.dynamic_bindings.get(&(frame.resource, name)) {
                        *binding = Some(*target);
                    }
                }
                current = frame.parent;
            }
            self.scopes.borrow_mut().intern(bindings)?
        };
        // Each scope gets a disjoint block of native node IDs. Checked
        // arithmetic keeps compact three-word result keys without aliasing
        // after scope eviction, even if monotonic IDs eventually overflow.
        let node = scope.checked_mul(engine.nodes.len())?.checked_add(node)?;
        Some((node, value, depth))
    }
    pub(super) fn verdict(&self, key: Key) -> Option<Verdict> {
        self.verdicts.borrow().get(key)
    }
    pub(super) fn record_verdict(&self, key: Key, status: Verdict) {
        self.verdicts
            .borrow_mut()
            .record(key, &status, 0, MAX_ENTRIES);
    }
    pub(super) fn tracked(&self, key: Key) -> Option<Tracked> {
        self.coverage.borrow().get((key, None))
    }
    pub(super) fn record_tracked(&self, key: Key, result: &Tracked) {
        self.coverage.borrow_mut().record(
            (key, None),
            result,
            result.memo_slots(),
            MAX_ENTRIES * 2,
        );
    }
    pub(super) fn diagnostic_success(&self, key: Key, annotations: bool) -> Option<Tracked> {
        self.coverage.borrow().get((key, Some(annotations)))
    }
    pub(super) fn record_diagnostic_success(&self, key: Key, annotations: bool, result: &Tracked) {
        self.coverage.borrow_mut().record(
            (key, Some(annotations)),
            result,
            result.memo_slots(),
            MAX_ENTRIES * 2,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_exact_outermost_bindings_and_reuses_equivalent_scopes() {
        let memo = Memo::default();
        let engine = Engine {
            nodes: vec![vec![Op::Boolean(true)]],
            memoizable: vec![true],
            memo_contextual: vec![true],
            anchor_tables: vec![vec![], vec![]],
            dynamic_bindings: HashMap::from([((1, 0), 7), ((2, 0), 8), ((2, 1), 9), ((3, 0), 7)]),
            ..Engine::default()
        };
        let frame = |resource, parent| scope::ScopeFrame {
            resource,
            parent,
            primary_binding: None,
        };
        let outer = frame(1, None);
        let inner = frame(2, Some(&outer));
        let equivalent_outer = frame(3, None);
        let equivalent_inner = frame(2, Some(&equivalent_outer));
        let different = frame(2, None);
        let key = |frame| {
            memo.key(
                &engine,
                0,
                10,
                2,
                scope::Context {
                    scope: Some(frame),
                    ..scope::Context::default()
                },
            )
            .unwrap()
        };
        let first = key(&inner);
        assert_eq!(first, key(&equivalent_inner));
        assert_ne!(first, key(&different));
        memo.record_verdict(first, Valid);
        assert_eq!(memo.verdict(key(&equivalent_inner)), Some(Valid));
        assert_eq!(memo.verdict(key(&different)), None);
        assert_eq!(memo.scopes.borrow().bindings.len(), 2);
    }

    #[test]
    fn compact_scope_blocks_separate_nodes_and_decline_overflow() {
        let engine = Engine {
            nodes: vec![vec![], vec![], vec![]],
            memoizable: vec![true; 3],
            memo_contextual: vec![true, true, false],
            anchor_tables: vec![vec![], vec![]],
            dynamic_bindings: HashMap::from([((1, 0), 0), ((2, 0), 1)]),
            ..Engine::default()
        };
        let first = scope::ScopeFrame {
            resource: 1,
            parent: None,
            primary_binding: None,
        };
        let second = scope::ScopeFrame {
            resource: 2,
            parent: None,
            primary_binding: None,
        };
        let context = |frame| scope::Context {
            scope: Some(frame),
            ..scope::Context::default()
        };
        let memo = Memo::default();
        let a = memo.key(&engine, 1, 10, 2, context(&first)).unwrap();
        let b = memo.key(&engine, 0, 10, 2, context(&second)).unwrap();
        assert_ne!(a, b);
        assert_eq!(
            memo.key(&engine, 2, 10, 2, context(&first)),
            Some((2, 10, 2))
        );
        assert_eq!(
            memo.key(&engine, 2, 10, 2, context(&second)),
            Some((2, 10, 2))
        );
        let exhausted = Memo::default();
        exhausted.scopes.borrow_mut().next_id = usize::MAX / 2;
        assert!(exhausted.key(&engine, 0, 10, 2, context(&first)).is_none());
        assert_eq!(
            exhausted.key(&engine, 2, 10, 2, context(&first)),
            Some((2, 10, 2))
        );
    }

    #[test]
    fn scope_turnover_never_reassigns_ids_still_used_by_results() {
        let mut scopes = Scopes::default();
        let old = scopes.intern(vec![Some(0)]).unwrap();
        for binding in 1..MAX_ENTRIES * 2 {
            scopes.intern(vec![Some(binding)]).unwrap();
        }
        assert_eq!(scopes.bindings.len(), MAX_ENTRIES);
        assert_eq!(scopes.order.len(), MAX_ENTRIES);
        assert_eq!(scopes.slots, MAX_ENTRIES);
        let new = scopes.intern(vec![Some(0)]).unwrap();
        assert_ne!(old, new);
        assert_eq!(scopes.intern(vec![Some(0)]), Some(new));
        let memo = Memo::default();
        memo.record_verdict((old, 2, 3), Invalid);
        assert_eq!(memo.verdict((new, 2, 3)), None);
    }

    #[test]
    fn bounds_scope_buffers_and_skips_oversized_signatures_without_eviction() {
        let mut scopes = Scopes::default();
        let bindings = vec![Some(0); MAX_SCOPE_SLOTS / 2];
        let first = scopes.intern(bindings.clone()).unwrap();
        scopes.intern(vec![Some(1); bindings.len()]).unwrap();
        scopes.intern(vec![Some(2); bindings.len()]).unwrap();
        assert_eq!(scopes.slots, MAX_SCOPE_SLOTS);
        assert_eq!(scopes.bindings.len(), 2);
        assert!(scopes.intern(vec![None; MAX_SCOPE_SLOTS + 1]).is_none());
        assert_eq!(scopes.slots, MAX_SCOPE_SLOTS);
        assert_ne!(scopes.intern(bindings), Some(first));
    }

    #[test]
    fn separates_annotation_policies_and_returns_independent_coverage() {
        let memo = Memo::default();
        let key = (1, 2, 3);
        let mut coverage = Tracked::new(Valid);
        coverage.item(65);
        memo.record_diagnostic_success(key, true, &coverage);
        memo.record_diagnostic_success(key, false, &Tracked::new(Valid));
        let mut copy = memo.diagnostic_success(key, true).unwrap();
        copy.item(0);
        assert!(
            memo.diagnostic_success(key, true)
                .unwrap()
                .contains_item(65)
        );
        assert!(!memo.diagnostic_success(key, true).unwrap().contains_item(0));
        assert!(
            !memo
                .diagnostic_success(key, false)
                .unwrap()
                .contains_item(65)
        );
    }

    #[test]
    fn admits_new_results_after_entry_limits() {
        let memo = Memo::default();
        for node in 0..MAX_ENTRIES * 3 {
            memo.record_verdict((node, 2, 3), Valid);
            memo.record_tracked((node, 2, 3), &Tracked::new(Valid));
        }
        assert!(memo.verdict((0, 2, 3)).is_none());
        assert_eq!(memo.verdict((MAX_ENTRIES * 3 - 1, 2, 3)), Some(Valid));
        assert!(memo.tracked((0, 2, 3)).is_none());
        assert!(memo.tracked((MAX_ENTRIES * 3 - 1, 2, 3)).is_some());
        assert_eq!(memo.verdicts.borrow().results.len(), MAX_ENTRIES);
        assert_eq!(memo.coverage.borrow().results.len(), MAX_ENTRIES * 2);
        assert_eq!(memo.coverage.borrow().order.len(), MAX_ENTRIES * 2);
    }

    #[test]
    fn skips_oversized_results_without_evicting_or_charging_duplicates() {
        let memo = Memo::default();
        let key = (1, 2, 3);
        let mut small = Tracked::new(Valid);
        small.item(0);
        memo.record_tracked(key, &small);
        memo.record_tracked(key, &small);
        let mut huge = Tracked::new(Valid);
        huge.item(MAX_ANNOTATION_SLOTS * 64);
        memo.record_diagnostic_success((2, 2, 3), true, &huge);
        assert!(memo.tracked(key).is_some());
        assert!(memo.diagnostic_success((2, 2, 3), true).is_none());
        assert_eq!(memo.coverage.borrow().slots, small.memo_slots());
        assert_eq!(memo.coverage.borrow().order.len(), 1);
    }

    #[test]
    fn bounds_retained_annotations_across_both_caches() {
        let memo = Memo::default();
        let mut large = Tracked::new(Valid);
        large.item(MAX_ANNOTATION_SLOTS * 64 - 1);
        memo.record_tracked((1, 2, 3), &large);
        assert!(memo.tracked((1, 2, 3)).is_some());
        let mut small = Tracked::new(Valid);
        small.item(0);
        memo.record_diagnostic_success((2, 2, 3), true, &small);
        assert!(memo.diagnostic_success((2, 2, 3), true).is_some());
        assert!(memo.tracked((1, 2, 3)).is_none());
        assert_eq!(memo.coverage.borrow().slots, small.memo_slots());
        memo.record_diagnostic_success((3, 2, 3), false, &Tracked::new(Valid));
        assert!(memo.diagnostic_success((3, 2, 3), false).is_some());
    }
}

impl Engine {
    pub(super) fn compile_memoization(&mut self) {
        let mut incoming = vec![0_usize; self.nodes.len()];
        let mut repeated_position = vec![false; self.nodes.len()];
        // Each dynamic name has one virtual dispatch vertex. Sharing it avoids
        // materializing reference-count × binding-count dependency edges.
        let count = self.nodes.len();
        let mut eligible = vec![true; count + self.anchor_tables.len()];
        let mut edges = vec![vec![]; eligible.len()];
        let mut repeated_subtree = vec![false; eligible.len()];
        for (name, bindings) in self.anchor_tables.iter().enumerate() {
            edges[count + name].extend(bindings.iter().map(|&(_, target)| target));
        }
        for (index, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                match op {
                    Op::Unsupported => eligible[index] = false,
                    Op::Ref(reference) => {
                        if let Some(target) = reference.static_target() {
                            incoming[target] += 1;
                            edges[index].push(target);
                        } else if let Some((name, target)) = reference.dynamic_target() {
                            incoming[target] += 1;
                            edges[index].extend([target, count + name]);
                        } else {
                            eligible[index] = false;
                        }
                    }
                    Op::All(nodes) => edges[index].extend(nodes),
                    Op::Any(nodes) | Op::One(nodes) => {
                        edges[index].extend(nodes.iter().map(|&(node, _)| node))
                    }
                    Op::Not(node) => edges[index].push(*node),
                    Op::Conditional(condition, yes, no) => {
                        edges[index].push(*condition);
                        edges[index].extend(yes);
                        edges[index].extend(no);
                    }
                    Op::Array(_, rules) => {
                        // One schema edge can evaluate many instance positions.
                        // Shared Ruby containers can reach this child repeatedly
                        // at the same depth even with only one source reference.
                        if !rules.list {
                            for &child in &rules.items {
                                repeated_position[child] = true;
                                repeated_subtree[index] = true;
                            }
                        }
                        for child in [rules.additional, rules.contains, rules.unevaluated]
                            .into_iter()
                            .flatten()
                        {
                            repeated_position[child] = true;
                            repeated_subtree[index] = true;
                        }
                        edges[index].extend(&rules.prefix);
                        edges[index].extend(&rules.items);
                        edges[index].extend(rules.additional);
                        edges[index].extend(rules.contains);
                        edges[index].extend(rules.unevaluated);
                    }
                    Op::Object(_, rules) => {
                        for &(_, child) in &rules.patterns {
                            repeated_position[child] = true;
                            repeated_subtree[index] = true;
                        }
                        for child in [rules.additional, rules.names, rules.unevaluated]
                            .into_iter()
                            .flatten()
                        {
                            repeated_position[child] = true;
                            repeated_subtree[index] = true;
                        }
                        edges[index].extend(rules.properties.iter().map(|&(_, child)| child));
                        edges[index].extend(rules.patterns.iter().map(|(_, child)| *child));
                        edges[index]
                            .extend(rules.dependent_schemas.iter().map(|&(_, child)| child));
                        edges[index].extend(rules.additional);
                        edges[index].extend(rules.names);
                        edges[index].extend(rules.unevaluated);
                    }
                    _ => {}
                }
            }
        }
        // Reject cycles through any possible binding, plus recursive refs.
        // States 2 and 4 distinguish scope-independent and scoped successes.
        // Bound analysis depth just as evaluation is bounded; conservatively
        // leave longer chains uncached rather than risking compilation overflow.
        fn reusable(
            node: usize,
            depth: usize,
            edges: &[Vec<usize>],
            eligible: &[bool],
            states: &mut [u8],
            count: usize,
            repeated_subtree: &mut [bool],
        ) -> bool {
            match states[node] {
                1 | 3 => return false,
                2 | 4 => return true,
                _ => {}
            }
            if depth > MAX_EVALUATION_DEPTH || !eligible[node] {
                states[node] = 3;
                return false;
            }
            states[node] = 1;
            let mut scoped = node >= count;
            let safe = edges[node].iter().all(|&child| {
                let safe = reusable(
                    child,
                    depth + 1,
                    edges,
                    eligible,
                    states,
                    count,
                    repeated_subtree,
                );
                repeated_subtree[node] |= repeated_subtree[child];
                scoped |= states[child] == 4;
                safe
            });
            states[node] = if !safe {
                3
            } else if scoped {
                4
            } else {
                2
            };
            safe
        }
        let mut states = vec![0; edges.len()];
        self.memoizable = (0..self.nodes.len())
            .map(|node| {
                (incoming[node] > 1 || repeated_position[node])
                    && reusable(node, 0, &edges, &eligible, &mut states, count, &mut repeated_subtree)
                    // Position-only candidates need nested iteration to amplify
                    // sharing. Simple records/scalars keep their cheap scans.
                    && (incoming[node] > 1 || repeated_subtree[node])
            })
            .collect();
        self.memo_contextual = states[..count].iter().map(|&state| state == 4).collect();
    }
}
