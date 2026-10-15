//! Iterative schema graph traversal used by compilation analyses.

// Callers own the visited buffer so cycle analysis can reuse it in the
// reverse pass. Keep discovery and child order identical for both analyses.
pub(super) fn postorder(edges: &[Vec<usize>], seen: &mut [bool]) -> Vec<usize> {
    let mut order = vec![];
    for root in 0..edges.len() {
        if seen[root] {
            continue;
        }
        seen[root] = true;
        let mut stack = vec![(root, 0)];
        while let Some((node, next)) = stack.last_mut() {
            if let Some(&child) = edges[*node].get(*next) {
                *next += 1;
                if !seen[child] {
                    seen[child] = true;
                    stack.push((child, 0));
                }
            } else {
                order.push(*node);
                stack.pop();
            }
        }
    }
    order
}

pub(super) fn parents(edges: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let mut parents = vec![vec![]; edges.len()];
    for (parent, children) in edges.iter().enumerate() {
        for &child in children {
            parents[child].push(parent);
        }
    }
    parents
}

// Reachability flags flow from children to parents, including through cycles.
// Each newly marked node enters the queue once.
pub(super) fn propagate(flags: &mut [bool], parents: &[Vec<usize>]) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orders_disconnected_cycles_and_shared_children() {
        let edges = vec![vec![1, 2], vec![2], vec![0], vec![3], vec![]];
        let mut seen = vec![false; edges.len()];
        assert_eq!(postorder(&edges, &mut seen), [2, 1, 0, 3, 4]);
        assert!(seen.iter().all(|&visited| visited));
        assert!(postorder(&[], &mut []).is_empty());
    }

    #[test]
    fn flags_propagate_through_cycles_without_marking_disconnected_nodes() {
        let parents = vec![vec![2], vec![0], vec![1, 3], vec![], vec![4]];
        let mut flags = vec![false, true, false, false, false];
        propagate(&mut flags, &parents);
        assert_eq!(flags, [true, true, true, true, false]);
        propagate(&mut [], &[]);
    }

    #[test]
    fn deep_chains_use_an_explicit_stack() {
        let count = 100_000;
        let mut edges: Vec<_> = (1..count).map(|child| vec![child]).collect();
        edges.push(vec![]);
        let order = postorder(&edges, &mut vec![false; count]);
        assert!(order.into_iter().eq((0..count).rev()));
    }
}
