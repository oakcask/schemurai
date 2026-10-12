//! Exact reachable scope dependencies, shared across schema components.
use super::*;
use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::Arc;

const MAX_NAMES: usize = 65536;

#[derive(Default)]
pub(super) struct Projection {
    names: Vec<Option<Arc<[usize]>>>,
    // If materialized closures exceed the budget, retain the linear dependency
    // graph and compute those exact projections on demand, never all names.
    graph: Option<Vec<Vec<usize>>>,
}
impl Projection {
    pub(super) fn compile(edges: &[Vec<usize>], parents: &[Vec<usize>], count: usize) -> Self {
        Self::bounded(edges, parents, count, MAX_NAMES)
    }
    fn bounded(edges: &[Vec<usize>], parents: &[Vec<usize>], count: usize, limit: usize) -> Self {
        let mut seen = vec![false; edges.len()];
        let order = graph::postorder(edges, &mut seen);
        let mut component = vec![usize::MAX; edges.len()];
        let mut members = vec![];
        for root in order.into_iter().rev() {
            if component[root] != usize::MAX {
                continue;
            }
            let id = members.len();
            let mut nodes = vec![];
            let mut stack = vec![root];
            component[root] = id;
            while let Some(node) = stack.pop() {
                nodes.push(node);
                for &parent in &parents[node] {
                    if component[parent] == usize::MAX {
                        component[parent] = id;
                        stack.push(parent);
                    }
                }
            }
            members.push(nodes);
        }
        // Kosaraju components are ordered from sources to sinks. Every member
        // of a cycle has the same reachable reference names; solve it once.
        let mut closures: Vec<Option<Arc<[usize]>>> = vec![None; members.len()];
        let mut interned: HashSet<Arc<[usize]>> = HashSet::new();
        let mut slots = 0;
        for (id, nodes) in members.iter().enumerate().rev() {
            let mut names = vec![];
            let mut children = HashSet::new();
            let mut dependencies = HashSet::new();
            let mut complete = true;
            for &node in nodes {
                if node >= count {
                    names.push(node - count);
                }
                for &child in &edges[node] {
                    let child = component[child];
                    if child != id && children.insert(child) {
                        match &closures[child] {
                            Some(dependency) => {
                                if dependencies.insert(dependency.as_ptr()) {
                                    names.extend(dependency.iter().copied());
                                }
                            }
                            None => complete = false,
                        }
                        if names.len() > limit {
                            names.sort_unstable();
                            names.dedup();
                            if names.len() > limit {
                                complete = false;
                                break;
                            }
                        }
                    }
                }
                // Bound temporary concatenation too. Deduplicate overlapping
                // dependencies before choosing the on-demand representation.
                if names.len() > limit {
                    names.sort_unstable();
                    names.dedup();
                    if names.len() > limit {
                        complete = false;
                        break;
                    }
                }
            }
            if !complete {
                continue;
            }
            names.sort_unstable();
            names.dedup();
            if let Some(existing) = interned.get(names.as_slice()) {
                closures[id] = Some(existing.clone());
            } else if names.len() <= limit - slots {
                slots += names.len();
                let names: Arc<[usize]> = names.into();
                interned.insert(names.clone());
                closures[id] = Some(names);
            }
        }
        let names: Vec<_> = component[..count]
            .iter()
            .map(|&id| closures[id].clone())
            .collect();
        let graph = names.iter().any(Option::is_none).then(|| edges.to_vec());
        Self { names, graph }
    }
    pub(super) fn names(
        &self,
        node: usize,
        count: usize,
        anchors: usize,
        guarded: bool,
        budget: &budget::Budget,
    ) -> Option<Cow<'_, [usize]>> {
        if self.names.is_empty() {
            // Hand-built engines in key tests have no compiled dependency graph.
            return Some(Cow::Owned((0..anchors + usize::from(guarded)).collect()));
        }
        if let Some(names) = &self.names[node] {
            return Some(Cow::Borrowed(names));
        }
        let graph = self.graph.as_ref()?;
        let mut seen = vec![false; graph.len()];
        let mut stack = vec![node];
        let mut names = vec![];
        seen[node] = true;
        while let Some(node) = stack.pop() {
            if !budget.checkpoint() {
                return None;
            }
            if node >= count {
                names.push(node - count);
            }
            for &child in &graph[node] {
                if !seen[child] {
                    seen[child] = true;
                    stack.push(child);
                }
            }
        }
        names.sort_unstable();
        Some(Cow::Owned(names))
    }
    pub(super) fn memory_usage(&self) -> usize {
        let mut seen = HashSet::new();
        self.names.capacity() * std::mem::size_of::<Option<Arc<[usize]>>>()
            + self
                .names
                .iter()
                .flatten()
                .filter(|names| seen.insert(names.as_ptr()))
                .map(|names| (names.len() + 2) * std::mem::size_of::<usize>())
                .sum::<usize>()
            + self.graph.as_ref().map_or(0, |graph| {
                graph.capacity() * std::mem::size_of::<Vec<usize>>()
                    + graph
                        .iter()
                        .map(|row| row.capacity() * std::mem::size_of::<usize>())
                        .sum::<usize>()
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parents(edges: &[Vec<usize>]) -> Vec<Vec<usize>> {
        let mut parents = vec![vec![]; edges.len()];
        for (node, children) in edges.iter().enumerate() {
            for &child in children {
                parents[child].push(node);
            }
        }
        parents
    }
    #[test]
    fn projects_cycles_and_transitive_dynamic_dispatch_targets() {
        // Four nodes, two dynamic names and the recursive dispatch vertex.
        let edges = vec![
            vec![1],
            vec![0, 4],
            vec![5],
            vec![],
            vec![2],
            vec![3],
            vec![0],
        ];
        for limit in [0, 1, MAX_NAMES] {
            let projection = Projection::bounded(&edges, &parents(&edges), 4, limit);
            let names = |node| {
                projection
                    .names(node, 4, 2, true, &budget::Budget::default())
                    .unwrap()
                    .into_owned()
            };
            assert_eq!(names(0), [0, 1]);
            assert_eq!(names(1), [0, 1]);
            assert_eq!(names(2), [1]);
            assert!(names(3).is_empty());
        }
    }
    #[test]
    fn retains_recursive_dispatch_only_where_reachable() {
        let edges = vec![vec![1], vec![4], vec![3], vec![], vec![0]];
        let projection = Projection::compile(&edges, &parents(&edges), 3);
        let names = |node| {
            projection
                .names(node, 3, 1, true, &budget::Budget::default())
                .unwrap()
                .into_owned()
        };
        assert_eq!(names(0), [1]);
        assert_eq!(names(1), [1]);
        assert_eq!(names(2), [0]);
    }

    #[test]
    fn shares_equal_closures_and_retains_exact_projection_after_budget_exhaustion() {
        let edges = vec![vec![1, 2], vec![3], vec![3], vec![4], vec![], vec![]];
        let projection = Projection::bounded(&edges, &parents(&edges), 4, MAX_NAMES);
        assert!(projection.graph.is_none());
        assert!(Arc::ptr_eq(
            projection.names[0].as_ref().unwrap(),
            projection.names[3].as_ref().unwrap()
        ));
        let projection = Projection::bounded(&edges, &parents(&edges), 4, 0);
        assert!(projection.graph.is_some());
        assert_eq!(
            &*projection
                .names(0, 4, 1, false, &budget::Budget::default())
                .unwrap(),
            &[0]
        );
    }
}
