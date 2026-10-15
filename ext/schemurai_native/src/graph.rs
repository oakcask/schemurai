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

// A functional graph has at most one outgoing edge per node. Return lengths
// only for cycle members, leaving prefixes and terminal paths unproven. Each
// path is visited once, and a finished marker prevents stale walk positions
// from treating a shared tail as another cycle.
pub(super) fn functional_cycle_lengths(next: &[Option<usize>]) -> Vec<Option<usize>> {
    let mut lengths = vec![None; next.len()];
    let mut positions = vec![usize::MAX; next.len()];
    for root in 0..next.len() {
        if positions[root] != usize::MAX || next[root].is_none() {
            continue;
        }
        let mut path = vec![];
        let mut node = root;
        loop {
            let position = positions[node];
            if position == usize::MAX - 1 {
                break;
            }
            if position != usize::MAX {
                let length = path.len() - position;
                for &member in &path[position..] {
                    lengths[member] = Some(length);
                }
                break;
            }
            positions[node] = path.len();
            path.push(node);
            let Some(child) = next[node] else {
                break;
            };
            node = child;
        }
        for node in path {
            positions[node] = usize::MAX - 1;
        }
    }
    lengths
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
    fn functional_cycles_exclude_prefixes_and_shared_terminal_tails() {
        assert_eq!(
            functional_cycle_lengths(&[Some(1), Some(2), Some(1), Some(2), Some(4), None, Some(5)]),
            [None, Some(2), Some(2), None, Some(1), None, None]
        );
        let count = 100_000;
        let mut next: Vec<_> = (1..count).map(Some).collect();
        next.push(Some(count - 1));
        let result = functional_cycle_lengths(&next);
        assert!(result[..count - 1].iter().all(Option::is_none));
        assert_eq!(result[count - 1], Some(1));
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
