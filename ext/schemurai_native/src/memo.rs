//! Invocation-local results for shared reference targets and guard/scope contexts.
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

// Approximate repeat detection only decides whether to attempt caching.
// False positives are safe: verdict/annotation keys remain fully exact.
// Reset epochs bound density and keep later locations eligible for admission.
#[derive(Default)]
struct Admission {
    bits: Vec<u64>,
    admissions: usize,
}
impl Admission {
    fn admit(&mut self, (node, value, depth): Key) -> bool {
        if self.bits.is_empty() {
            self.bits.resize(1024, 0);
        }
        if self.admissions == MAX_ENTRIES {
            self.bits.fill(0);
            self.admissions = 0;
        }
        let hash =
            mix(node as u64 ^ (value as u64).rotate_left(21) ^ (depth as u64).rotate_left(42));
        let a = hash as usize & 65535;
        let b = (hash >> 32) as usize & 65535;
        let seen =
            self.bits[a / 64] & (1 << (a % 64)) != 0 && self.bits[b / 64] & (1 << (b % 64)) != 0;
        if !seen {
            self.bits[a / 64] |= 1 << (a % 64);
            self.bits[b / 64] |= 1 << (b % 64);
            self.admissions += 1;
        }
        seen
    }
}

#[derive(Default)]
pub(super) struct Memo {
    verdicts: RefCell<Cache<Key, Verdict>>,
    scopes: RefCell<Scopes>,
    instances: RefCell<instance_graph::Graph>,
    guard_admission: RefCell<Admission>,
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
        budget: &budget::Budget,
    ) -> Option<Key> {
        if !engine.memoizable[node] {
            return None;
        }
        let mut object = false;
        if engine.memo_guarded.get(node).copied().unwrap_or(false) {
            let kind = unsafe { sn_shallow_kind(value) };
            object = kind == TYPE_OBJECT;
            if kind != TYPE_ARRAY && !object && !engine.memo_guard_scalar_amplification[node] {
                return None;
            }
            if !self.admit_guard_key((node, value, depth)) {
                return None;
            }
        }
        self.key_with_instance_proof(
            engine,
            node,
            value,
            depth,
            context,
            (
                object,
                |value| self.instances.borrow_mut().acyclic(value, budget),
                budget,
            ),
        )
    }
    fn admit_guard_key(&self, key: Key) -> bool {
        self.guard_admission.borrow_mut().admit(key)
    }
    // Pure Rust key tests do not link CRuby. They exercise the conservative
    // path; Ruby integration tests exercise the actual bounded instance proof.
    #[cfg(test)]
    fn key_without_instance_proof(
        &self,
        engine: &Engine,
        node: usize,
        value: Value,
        depth: usize,
        context: scope::Context<'_>,
    ) -> Option<Key> {
        self.key_with_instance_proof(
            engine,
            node,
            value,
            depth,
            context,
            (false, |_| false, &budget::Budget::default()),
        )
    }
    fn key_with_instance_proof(
        &self,
        engine: &Engine,
        node: usize,
        value: Value,
        depth: usize,
        context: scope::Context<'_>,
        analysis: (bool, impl FnOnce(Value) -> bool, &budget::Budget),
    ) -> Option<Key> {
        let (object, prove_acyclic, budget) = analysis;
        if !engine.memoizable[node] {
            return None;
        }
        if engine.memo_guarded.get(node).copied().unwrap_or(false) {
            let relevant = engine.memo_scope_projection.names(
                node,
                engine.nodes.len(),
                engine.anchor_tables.len(),
                true,
                budget,
            )?;
            let names = relevant.len();
            if names > MAX_SCOPE_SLOTS - 2 {
                return None;
            }
            if !budget.checkpoint() {
                return None;
            }
            let mut pairs = vec![];
            let mut current = context.active;
            while let Some(frame) = current {
                if !budget.checkpoint() {
                    return None;
                }
                // A source outside every schema cycle cannot be revisited from
                // its own descendant evaluation, even under dynamic dispatch.
                if engine.memo_guard_sources[frame.source] {
                    if pairs.len() == (MAX_SCOPE_SLOTS - names - 2) / 2 {
                        return None;
                    }
                    pairs.push((frame.source, frame.value));
                }
                current = frame.parent;
            }
            if !pairs.is_empty() && prove_acyclic(value) {
                // An acyclic input cannot revisit ancestors through position
                // changes. Only same-instance schema cycles retain guards.
                let same = if object {
                    &engine.memo_guard_same_sources
                } else {
                    &engine.memo_guard_scalar_sources
                };
                pairs.retain(|&(source, ancestor)| ancestor == value && same[source]);
            }
            // RefFrame::contains tests membership, independently of order.
            if !budget.checkpoint() {
                return None;
            }
            pairs.sort_unstable();
            pairs.dedup();
            let mut signature = Vec::with_capacity(1 + 2 * pairs.len() + names);
            signature.push(Some(pairs.len()));
            for (source, value) in pairs {
                signature.extend([Some(source), Some(value)]);
            }
            let first_binding = signature.len();
            signature.resize(first_binding + names, None);
            let mut current = context.scope;
            while let Some(frame) = current {
                if !budget.checkpoint() {
                    return None;
                }
                for (slot, &name) in relevant.iter().enumerate() {
                    if name == engine.anchor_tables.len() {
                        if let Some(&root) = engine.resources.get(&frame.resource)
                            && engine.metadata[root].recursive_anchor
                        {
                            signature[first_binding + slot] = Some(root);
                        }
                    } else if let Some(&target) =
                        engine.dynamic_bindings.get(&(frame.resource, name))
                    {
                        signature[first_binding + slot] = Some(target);
                    }
                }
                current = frame.parent;
            }
            if !budget.checkpoint() {
                return None;
            }
            let id = self.scopes.borrow_mut().intern(signature)?;
            let node = id.checked_mul(engine.nodes.len())?.checked_add(node)?;
            return Some((node, value, depth));
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
            let relevant = engine.memo_scope_projection.names(
                node,
                engine.nodes.len(),
                engine.anchor_tables.len(),
                false,
                budget,
            )?;
            let names = relevant.len();
            if names > MAX_SCOPE_SLOTS {
                return None;
            }
            if !budget.checkpoint() {
                return None;
            }
            let mut bindings = vec![None; names];
            let mut current = context.scope;
            while let Some(frame) = current {
                if !budget.checkpoint() {
                    return None;
                }
                for (&name, binding) in relevant.iter().zip(&mut bindings) {
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
    fn approximate_admission_bounds_density_and_resets_for_later_positions() {
        let mut admission = Admission::default();
        assert!(admission.bits.is_empty());
        assert!(!admission.admit((1, 2, 3)));
        assert!(admission.admit((1, 2, 3)));
        for value in 0..MAX_ENTRIES * 3 {
            admission.admit((4, value, 5));
            assert!(admission.admissions <= MAX_ENTRIES);
            assert!(
                admission
                    .bits
                    .iter()
                    .map(|word| word.count_ones() as usize)
                    .sum::<usize>()
                    <= MAX_ENTRIES * 2
            );
        }
        assert_eq!(admission.bits.len(), 1024);
        admission.admissions = MAX_ENTRIES;
        assert!(!admission.admit((1, 2, 3)));
        assert!(admission.admit((1, 2, 3)));
        assert_eq!(admission.admissions, 1);
    }

    #[test]
    fn guarded_keys_distinguish_active_sources_values_scope_order_and_depth() {
        let memo = Memo::default();
        let engine = Engine {
            nodes: (0..3).map(|_| vec![Op::Boolean(true)]).collect(),
            memoizable: vec![true; 3],
            memo_contextual: vec![false; 3],
            memo_guarded: vec![true; 3],
            memo_guard_sources: vec![true; 3],
            memo_guard_same_sources: vec![true; 3],
            memo_guard_scalar_sources: vec![true; 3],
            memo_guard_scalar_amplification: vec![true; 3],
            metadata: vec![
                scope::Metadata {
                    recursive_anchor: true,
                    ..scope::Metadata::default()
                };
                3
            ],
            resources: HashMap::from([(1, 0), (2, 1), (42, 2)]),
            ..Engine::default()
        };
        let frame = |source, value| RefFrame {
            source,
            value,
            parent: None,
        };
        let active = frame(1, 42);
        let equivalent = frame(1, 42);
        let other_source = frame(2, 42);
        let other_value = frame(1, 43);
        let context = |active| scope::Context {
            active: Some(active),
            scope: None,
        };
        let key = memo
            .key_without_instance_proof(&engine, 0, 42, 8, context(&active))
            .unwrap();
        assert_eq!(
            memo.key_without_instance_proof(&engine, 0, 42, 8, context(&equivalent)),
            Some(key)
        );
        assert_ne!(
            memo.key_without_instance_proof(&engine, 0, 42, 8, context(&other_source)),
            Some(key)
        );
        assert_ne!(
            memo.key_without_instance_proof(&engine, 0, 43, 8, context(&other_value)),
            Some(key)
        );
        assert_ne!(
            memo.key_without_instance_proof(&engine, 0, 42, 9, context(&active)),
            Some(key)
        );
        let outer = scope::ScopeFrame {
            resource: 1,
            parent: None,
            primary_binding: None,
        };
        let inner = scope::ScopeFrame {
            resource: 2,
            parent: Some(&outer),
            primary_binding: None,
        };
        let swapped_outer = scope::ScopeFrame {
            resource: 2,
            parent: None,
            primary_binding: None,
        };
        let swapped_inner = scope::ScopeFrame {
            resource: 1,
            parent: Some(&swapped_outer),
            primary_binding: None,
        };
        assert_ne!(
            memo.key_without_instance_proof(
                &engine,
                0,
                7,
                8,
                scope::Context {
                    scope: Some(&inner),
                    ..context(&active)
                }
            ),
            memo.key_without_instance_proof(
                &engine,
                0,
                7,
                8,
                scope::Context {
                    scope: Some(&swapped_inner),
                    ..context(&active)
                }
            ),
        );
        // The pair count separates guard membership from effective scope
        // bindings even when their numeric handles coincide.
        let a = scope::ScopeFrame {
            resource: 42,
            parent: Some(&outer),
            primary_binding: None,
        };
        assert_ne!(
            Some(key),
            memo.key_without_instance_proof(
                &engine,
                0,
                7,
                8,
                scope::Context {
                    active: None,
                    scope: Some(&a)
                }
            )
        );

        let empty = scope::Context::default();
        let other = context(&other_value);
        assert_eq!(
            memo.key_with_instance_proof(
                &engine,
                0,
                42,
                8,
                other,
                (false, |_| true, &budget::Budget::default())
            ),
            memo.key_with_instance_proof(
                &engine,
                0,
                42,
                8,
                empty,
                (false, |_| true, &budget::Budget::default())
            ),
        );
        assert_ne!(
            memo.key_with_instance_proof(
                &engine,
                0,
                42,
                8,
                other,
                (false, |_| false, &budget::Budget::default())
            ),
            memo.key_with_instance_proof(
                &engine,
                0,
                42,
                8,
                empty,
                (false, |_| false, &budget::Budget::default())
            ),
        );
        let a = RefFrame {
            source: 1,
            value: 42,
            parent: Some(&other_source),
        };
        let b = RefFrame {
            source: 2,
            value: 42,
            parent: Some(&active),
        };
        assert_eq!(
            memo.key_without_instance_proof(&engine, 0, 42, 8, context(&a)),
            memo.key_without_instance_proof(&engine, 0, 42, 8, context(&b)),
        );
    }

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
            memo.key_without_instance_proof(
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
    fn projected_keys_ignore_unused_bindings_but_keep_reachable_names() {
        let edges = vec![vec![3], vec![4], vec![], vec![], vec![], vec![]];
        let parents = vec![vec![], vec![], vec![], vec![0], vec![1], vec![]];
        let mut engine = Engine {
            nodes: (0..3).map(|_| vec![Op::Boolean(true)]).collect(),
            memoizable: vec![true; 3],
            memo_contextual: vec![true; 3],
            memo_guarded: vec![false, false, true],
            memo_guard_sources: vec![false; 3],
            memo_scope_projection: memo_scope::Projection::compile(&edges, &parents, 3),
            anchor_tables: vec![vec![], vec![]],
            dynamic_bindings: HashMap::from([((1, 0), 7), ((2, 0), 7), ((1, 1), 8), ((2, 1), 9)]),
            resources: HashMap::from([(1, 0), (2, 1)]),
            metadata: vec![
                scope::Metadata {
                    recursive_anchor: true,
                    ..scope::Metadata::default()
                };
                3
            ],
            ..Engine::default()
        };
        let memo = Memo::default();
        let frame = |resource| scope::ScopeFrame {
            resource,
            parent: None,
            primary_binding: None,
        };
        let a = frame(1);
        let b = frame(2);
        let key = |engine: &Engine, node, frame| {
            memo.key_without_instance_proof(
                engine,
                node,
                10,
                2,
                scope::Context {
                    scope: Some(frame),
                    ..scope::Context::default()
                },
            )
            .unwrap()
        };
        assert_eq!(key(&engine, 0, &a), key(&engine, 0, &b));
        assert_ne!(key(&engine, 1, &a), key(&engine, 1, &b));
        // Neither dynamic nor recursive dispatch can affect node 2.
        assert_eq!(key(&engine, 2, &a), key(&engine, 2, &b));
        engine.dynamic_bindings.insert((2, 0), 8);
        assert_ne!(key(&engine, 0, &a), key(&engine, 0, &b));
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
        let a = memo
            .key_without_instance_proof(&engine, 1, 10, 2, context(&first))
            .unwrap();
        let b = memo
            .key_without_instance_proof(&engine, 0, 10, 2, context(&second))
            .unwrap();
        assert_ne!(a, b);
        assert_eq!(
            memo.key_without_instance_proof(&engine, 2, 10, 2, context(&first)),
            Some((2, 10, 2))
        );
        assert_eq!(
            memo.key_without_instance_proof(&engine, 2, 10, 2, context(&second)),
            Some((2, 10, 2))
        );
        let exhausted = Memo::default();
        exhausted.scopes.borrow_mut().next_id = usize::MAX / 2;
        assert!(
            exhausted
                .key_without_instance_proof(&engine, 0, 10, 2, context(&first))
                .is_none()
        );
        assert_eq!(
            exhausted.key_without_instance_proof(&engine, 2, 10, 2, context(&first)),
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
        let recursive_dispatch = count + self.anchor_tables.len();
        let mut eligible = vec![true; recursive_dispatch + 1];
        let mut unsupported = vec![false; eligible.len()];
        let mut edges = vec![vec![]; eligible.len()];
        let mut repeated_subtree = vec![false; eligible.len()];
        for (name, bindings) in self.anchor_tables.iter().enumerate() {
            edges[count + name].extend(bindings.iter().map(|&(_, target)| target));
        }
        edges[recursive_dispatch].extend(
            self.resources
                .values()
                .copied()
                .filter(|&root| self.metadata[root].recursive_anchor),
        );
        for (index, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                match op {
                    Op::Unsupported => {
                        eligible[index] = false;
                        unsupported[index] = true;
                    }
                    Op::Ref(reference) => {
                        if let Some(target) = reference.static_target() {
                            incoming[target] += 1;
                            edges[index].push(target);
                        } else if let Some((name, target)) = reference.dynamic_target() {
                            incoming[target] += 1;
                            edges[index].extend([target, count + name]);
                        } else if let Some(target) = reference.recursive_target() {
                            incoming[target] += 1;
                            edges[index].extend([target, recursive_dispatch]);
                            // Compact scope-only keys do not encode recursive
                            // dispatch or active guards. Use exact guard contexts.
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
        // Cyclic candidates can reuse results only under an exact guard/scope
        // context. Propagate unsupported instructions and nested iteration
        // through reverse edges without a per-candidate graph walk.
        let mut parents = vec![vec![]; edges.len()];
        for (parent, children) in edges.iter().enumerate() {
            for &child in children {
                parents[child].push(parent);
            }
        }
        fn propagate(flags: &mut [bool], parents: &[Vec<usize>]) {
            let mut queue: std::collections::VecDeque<_> = flags
                .iter()
                .enumerate()
                .filter_map(|(node, &set)| set.then_some(node))
                .collect();
            while let Some(node) = queue.pop_front() {
                for &parent in &parents[node] {
                    if !flags[parent] {
                        flags[parent] = true;
                        queue.push_back(parent);
                    }
                }
            }
        }
        propagate(&mut unsupported, &parents);
        propagate(&mut repeated_subtree, &parents);
        // Iterative Kosaraju analysis identifies the only active sources
        // whose guards can affect descendants: sources lying on a schema cycle.
        fn cycle_nodes(edges: &[Vec<usize>], parents: &[Vec<usize>]) -> Vec<bool> {
            let mut seen = vec![false; edges.len()];
            let order = graph::postorder(edges, &mut seen);
            seen.fill(false);
            let mut cyclic = vec![false; edges.len()];
            for root in order.into_iter().rev() {
                if seen[root] {
                    continue;
                }
                let mut component = vec![];
                let mut stack = vec![root];
                seen[root] = true;
                while let Some(node) = stack.pop() {
                    component.push(node);
                    for &parent in &parents[node] {
                        if !seen[parent] {
                            seen[parent] = true;
                            stack.push(parent);
                        }
                    }
                }
                if component.len() > 1 || edges[root].contains(&root) {
                    for node in component {
                        cyclic[node] = true;
                    }
                }
            }
            cyclic
        }
        let cyclic = cycle_nodes(&edges, &parents);
        // A root schema has no entry reference. Count references originating
        // inside cycles separately so two recursive property edges still
        // establish amplification without requiring a third, external edge.
        let mut cyclic_incoming = vec![0_usize; count];
        for (source, ops) in self.nodes.iter().enumerate() {
            if cyclic[source] {
                for op in ops {
                    if let Op::Ref(reference) = op {
                        let target = reference
                            .static_target()
                            .or_else(|| reference.dynamic_target().map(|(_, target)| target))
                            .or_else(|| reference.recursive_target());
                        if let Some(target) = target {
                            cyclic_incoming[target] += 1;
                        }
                    }
                }
            }
        }
        let mut same_edges = vec![vec![]; edges.len()];
        same_edges[count..].clone_from_slice(&edges[count..]);
        let mut scalar_refs = vec![false; edges.len()];
        for (node, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                match op {
                    Op::Ref(reference) => {
                        scalar_refs[node] = true;
                        if let Some(target) = reference.static_target() {
                            same_edges[node].push(target);
                        } else if let Some((name, target)) = reference.dynamic_target() {
                            same_edges[node].extend([target, count + name]);
                        } else if let Some(target) = reference.recursive_target() {
                            same_edges[node].extend([target, recursive_dispatch]);
                        }
                    }
                    Op::All(children) => same_edges[node].extend(children),
                    Op::Any(children) | Op::One(children) => {
                        same_edges[node].extend(children.iter().map(|&(child, _)| child))
                    }
                    Op::Not(child) => same_edges[node].push(*child),
                    Op::Conditional(condition, yes, no) => {
                        same_edges[node].push(*condition);
                        same_edges[node].extend(yes);
                        same_edges[node].extend(no);
                    }
                    _ => {}
                }
            }
        }
        fn reverse(edges: &[Vec<usize>]) -> Vec<Vec<usize>> {
            let mut parents = vec![vec![]; edges.len()];
            for (parent, children) in edges.iter().enumerate() {
                for &child in children {
                    parents[child].push(parent);
                }
            }
            parents
        }
        let scalar_parents = reverse(&same_edges);
        self.memo_guard_scalar_sources =
            cycle_nodes(&same_edges, &scalar_parents)[..count].to_vec();
        propagate(&mut scalar_refs, &scalar_parents);
        let mut scalar_amplification = vec![false; edges.len()];
        for (node, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                let references = match op {
                    Op::All(children) => {
                        children.iter().filter(|&&child| scalar_refs[child]).count()
                    }
                    Op::Any(children) | Op::One(children) => children
                        .iter()
                        .filter(|&&(child, _)| scalar_refs[child])
                        .count(),
                    Op::Conditional(condition, yes, no) => std::iter::once(*condition)
                        .chain(*yes)
                        .chain(*no)
                        .filter(|&child| scalar_refs[child])
                        .count(),
                    _ => 0,
                };
                scalar_amplification[node] |= references > 1;
            }
        }
        propagate(&mut scalar_amplification, &scalar_parents);
        self.memo_guard_scalar_amplification = scalar_amplification[..count].to_vec();
        // Object dependencies keep the same value; all other container child
        // edges change positions. Scalar/array inputs cannot take dependencies.
        for (node, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                if let Op::Object(_, rules) = op {
                    same_edges[node]
                        .extend(rules.dependent_schemas.iter().map(|&(_, child)| child));
                }
            }
        }
        self.memo_guard_same_sources =
            cycle_nodes(&same_edges, &reverse(&same_edges))[..count].to_vec();
        self.memo_guard_sources = cyclic[..count].to_vec();
        self.memo_guarded = vec![false; count];
        for node in 0..count {
            let amplified_cycle = incoming[node] > 2 || cyclic_incoming[node] > 1;
            if !self.memoizable[node] && !unsupported[node]
                && (incoming[node] > 1 || repeated_position[node] && repeated_subtree[node])
                // A linear recursive property chain has no amplification.
                // Avoid signatures unless a cycle has repeated input positions
                // or multiple recursive edges, with or without an entry ref.
                && (!cyclic[node] || repeated_subtree[node] || amplified_cycle)
                // Position loops already admit their child instruction. Do not
                // duplicate caching at its singly referenced recursive target.
                && (!cyclic[node] || repeated_position[node] || amplified_cycle || scalar_amplification[node])
            {
                self.memoizable[node] = true;
                self.memo_guarded[node] = true;
            }
        }
        self.memo_scope_projection = if self.memo_guarded.iter().any(|&guarded| guarded)
            || self.anchor_tables.len() > 1 && self.memo_contextual.iter().any(|&scoped| scoped)
        {
            memo_scope::Projection::compile(&edges, &parents, count)
        } else {
            memo_scope::Projection::default()
        };
    }
}
