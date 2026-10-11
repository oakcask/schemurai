//! Invocation-local results for shared, acyclic, static reference targets.
use super::*;
use std::cell::RefCell;
use tracking::Tracked;

type Key = (usize, Value, usize);
const MAX_ENTRIES: usize = 4096;
const MAX_ANNOTATION_SLOTS: usize = 65536;

#[derive(Default)]
pub(super) struct Memo {
    verdicts: RefCell<HashMap<Key, Verdict>>,
    tracked: RefCell<HashMap<Key, Tracked>>,
    successes: RefCell<HashMap<(Key, bool), Tracked>>,
    annotation_slots: RefCell<usize>,
}
impl Memo {
    pub(super) fn verdict(&self, key: Key) -> Option<Verdict> {
        self.verdicts.borrow().get(&key).copied()
    }
    pub(super) fn record_verdict(&self, key: Key, status: Verdict) {
        let mut results = self.verdicts.borrow_mut();
        if results.len() < MAX_ENTRIES {
            results.insert(key, status);
        }
    }
    pub(super) fn tracked(&self, key: Key) -> Option<Tracked> {
        self.tracked.borrow().get(&key).cloned()
    }
    pub(super) fn record_tracked(&self, key: Key, result: &Tracked) {
        let mut results = self.tracked.borrow_mut();
        if results.len() < MAX_ENTRIES
            && !results.contains_key(&key)
            && self.reserve_annotations(result)
        {
            results.insert(key, result.clone());
        }
    }
    pub(super) fn diagnostic_success(&self, key: Key, annotations: bool) -> Option<Tracked> {
        self.successes.borrow().get(&(key, annotations)).cloned()
    }
    pub(super) fn record_diagnostic_success(&self, key: Key, annotations: bool, result: &Tracked) {
        let mut results = self.successes.borrow_mut();
        if results.len() < MAX_ENTRIES
            && !results.contains_key(&(key, annotations))
            && self.reserve_annotations(result)
        {
            results.insert((key, annotations), result.clone());
        }
    }
    fn reserve_annotations(&self, result: &Tracked) -> bool {
        let mut slots = self.annotation_slots.borrow_mut();
        let added = result.memo_slots();
        if added > MAX_ANNOTATION_SLOTS - *slots {
            return false;
        }
        *slots += added;
        true
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
    fn bounds_retained_annotations_across_both_caches() {
        let memo = Memo::default();
        let mut large = Tracked::new(Valid);
        large.item(MAX_ANNOTATION_SLOTS * 64 - 1);
        memo.record_tracked((1, 2, 3), &large);
        assert!(memo.tracked((1, 2, 3)).is_some());
        let mut small = Tracked::new(Valid);
        small.item(0);
        memo.record_diagnostic_success((2, 2, 3), true, &small);
        assert!(memo.diagnostic_success((2, 2, 3), true).is_none());
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
