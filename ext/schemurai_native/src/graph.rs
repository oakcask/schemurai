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
    fn deep_chains_use_an_explicit_stack() {
        let count = 100_000;
        let mut edges: Vec<_> = (1..count).map(|child| vec![child]).collect();
        edges.push(vec![]);
        let order = postorder(&edges, &mut vec![false; count]);
        assert!(order.into_iter().eq((0..count).rev()));
    }
}
