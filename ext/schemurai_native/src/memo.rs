//! Invocation-local results for shared, acyclic, static reference targets.
use super::*;
use std::cell::RefCell;
use tracking::Tracked;

type Key = (usize, Value, usize);
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

#[derive(Default)]
pub(super) struct Memo {
    verdicts: RefCell<Cache<Key, Verdict>>,
    // None is tracked validity; Some(bool) is the diagnostic annotation policy.
    // Coverage results share both admission order and the allocation budget.
    coverage: RefCell<Cache<(Key, Option<bool>), Tracked>>,
}
impl Memo {
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
        let mut eligible = vec![true; self.nodes.len()];
        let mut edges = vec![vec![]; self.nodes.len()];
        for (index, ops) in self.nodes.iter().enumerate() {
            for op in ops {
                match op {
                    Op::Unsupported => eligible[index] = false,
                    Op::Ref(reference) => {
                        if let Some(target) = reference.static_target() {
                            incoming[target] += 1;
                            edges[index].push(target);
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
                        edges[index].extend(&rules.prefix);
                        edges[index].extend(&rules.items);
                        edges[index].extend(rules.additional);
                        edges[index].extend(rules.contains);
                        edges[index].extend(rules.unevaluated);
                    }
                    Op::Object(_, rules) => {
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
        // Reject cycles and every node that can reach a context-dependent ref.
        // Bound analysis depth just as evaluation is bounded; conservatively
        // leave longer chains uncached rather than risking compilation overflow.
        fn independent(
            node: usize,
            depth: usize,
            edges: &[Vec<usize>],
            eligible: &[bool],
            states: &mut [u8],
        ) -> bool {
            match states[node] {
                1 | 3 => return false,
                2 => return true,
                _ => {}
            }
            if depth > MAX_EVALUATION_DEPTH || !eligible[node] {
                states[node] = 3;
                return false;
            }
            states[node] = 1;
            let safe = edges[node]
                .iter()
                .all(|&child| independent(child, depth + 1, edges, eligible, states));
            states[node] = if safe { 2 } else { 3 };
            safe
        }
        let mut states = vec![0; self.nodes.len()];
        self.memoizable = (0..self.nodes.len())
            .map(|node| incoming[node] > 1 && independent(node, 0, &edges, &eligible, &mut states))
            .collect();
    }
}
