//! Shared branch and contains scans with separate result and termination policies.
use super::*;
use tracking::Tracked;

#[derive(Clone, Copy)]
pub(super) enum BranchKind {
    Any,
    One,
}
impl BranchKind {
    pub(super) fn accepts(self, matches: usize) -> bool {
        match self {
            Self::Any => matches > 0,
            Self::One => matches == 1,
        }
    }
    pub(super) fn keyword(self) -> &'static str {
        match self {
            Self::Any => "anyOf",
            Self::One => "oneOf",
        }
    }
}

#[derive(Clone, Copy)]
pub(super) enum BranchPolicy {
    Validity(BranchKind),
    // Annotations, exact diagnostic counts and compatibility exceptions can
    // require later branches even after validity alone is conclusive.
    Complete,
}
impl BranchPolicy {
    fn finished(self, matches: usize) -> bool {
        match self {
            Self::Validity(BranchKind::Any) => matches > 0,
            Self::Validity(BranchKind::One) => matches > 1,
            Self::Complete => false,
        }
    }
}

pub(super) trait BranchResult {
    fn valid() -> Self;
    fn status(&self) -> Verdict;
    fn merge(&mut self, branch: Self);
}
impl BranchResult for Verdict {
    fn valid() -> Self {
        Valid
    }
    fn status(&self) -> Verdict {
        *self
    }
    fn merge(&mut self, _: Self) {}
}
impl BranchResult for Tracked {
    fn valid() -> Self {
        Self::new(Valid)
    }
    fn status(&self) -> Verdict {
        self.status
    }
    fn merge(&mut self, branch: Self) {
        self.merge(branch);
    }
}

pub(super) struct BranchMatches<R> {
    pub matches: usize,
    pub coverage: R,
}
pub(super) fn scan_branches<R: BranchResult>(
    nodes: &[(usize, usize)],
    policy: BranchPolicy,
    mut evaluate: impl FnMut(usize) -> R,
) -> Result<BranchMatches<R>, Verdict> {
    let mut result = BranchMatches {
        matches: 0,
        coverage: R::valid(),
    };
    for &(node, multiplicity) in nodes {
        let branch = evaluate(node);
        match branch.status() {
            Unsupported => return Err(Unsupported),
            Invalid => {}
            Valid => {
                result.matches += multiplicity;
                result.coverage.merge(branch);
            }
        }
        if policy.finished(result.matches) {
            break;
        }
    }
    Ok(result)
}

// Diagnostic counts and annotations need every match. Keep the same complete
// traversal for ordinary validity so unsupported later items retain fallback.
pub(super) fn scan_contains(
    len: usize,
    mut evaluate: impl FnMut(usize) -> Verdict,
    mut record: impl FnMut(usize),
) -> Result<usize, Verdict> {
    let mut matches = 0;
    for index in 0..len {
        match evaluate(index) {
            Unsupported => return Err(Unsupported),
            Invalid => {}
            Valid => {
                matches += 1;
                record(index);
            }
        }
    }
    Ok(matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn termination_preserves_multiplicity_and_complete_scan_errors() {
        let nodes = [(0, 2), (1, 1)];
        let evaluate = |node| if node == 0 { Valid } else { Unsupported };
        for kind in [BranchKind::Any, BranchKind::One] {
            let result = scan_branches(&nodes, BranchPolicy::Validity(kind), evaluate).unwrap();
            assert_eq!(result.matches, 2);
            assert_eq!(
                kind.accepts(result.matches),
                matches!(kind, BranchKind::Any)
            );
        }
        assert!(matches!(
            scan_branches(&nodes, BranchPolicy::Complete, evaluate),
            Err(Unsupported)
        ));
    }

    #[test]
    fn contains_records_only_matches_and_retains_later_unsupported_results() {
        let mut recorded = vec![];
        let result = scan_contains(
            4,
            |index| verdict(index % 2 == 0),
            |index| recorded.push(index),
        );
        assert_eq!(result, Ok(2));
        assert_eq!(recorded, [0, 2]);
        assert_eq!(
            scan_contains(
                2,
                |index| if index == 0 { Valid } else { Unsupported },
                |_| {}
            ),
            Err(Unsupported)
        );
    }
}
