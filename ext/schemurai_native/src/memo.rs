//! Invocation-local results for shared, acyclic, static reference targets.
use super::*;
use std::cell::RefCell;
use std::collections::HashSet;

type Key = (usize, Value, usize);
const MAX_ENTRIES: usize = 4096;

#[derive(Default)]
pub(super) struct Memo {
    verdicts: RefCell<HashMap<Key, Verdict>>,
    successes: RefCell<HashSet<Key>>,
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
    pub(super) fn diagnostic_success(&self, key: Key) -> bool {
        self.successes.borrow().contains(&key)
    }
    pub(super) fn record_diagnostic_success(&self, key: Key) {
        let mut results = self.successes.borrow_mut();
        if results.len() < MAX_ENTRIES {
            results.insert(key);
        }
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
