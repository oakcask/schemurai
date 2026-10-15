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
}
impl BranchResult for Verdict {
    fn valid() -> Self {
        Valid
    }
    fn status(&self) -> Verdict {
        *self
    }
}
impl BranchResult for Tracked {
    fn valid() -> Self {
        Self::new(Valid)
    }
    fn status(&self) -> Verdict {
        self.status
    }
}

pub(super) struct BranchMatches<R> {
    pub matches: usize,
    pub coverage: R,
}
pub(super) fn scan_branches<R: BranchResult>(
    nodes: &[(usize, usize)],
    policy: BranchPolicy,
    separate_calls: bool,
    mut evaluate: impl FnMut(usize) -> R,
    mut merge: impl FnMut(&mut R, R) -> Result<(), Verdict>,
) -> Result<BranchMatches<R>, Verdict> {
    let mut result = BranchMatches {
        matches: 0,
        coverage: R::valid(),
    };
    'groups: for &(node, multiplicity) in nodes {
        for _ in 0..if separate_calls { multiplicity } else { 1 } {
            let branch = evaluate(node);
            match branch.status() {
                Unsupported => return Err(Unsupported),
                Invalid => {}
                Valid => {
                    result.matches += if separate_calls { 1 } else { multiplicity };
                    merge(&mut result.coverage, branch)?;
                }
            }
            if policy.finished(result.matches) {
                break 'groups;
            }
        }
    }
    Ok(result)
}

#[derive(Clone, Copy)]
pub(super) enum ContainsPolicy {
    FirstMatch,
    AllMatches,
}

// Older dialects use any? for untracked validity; counted validity,
// diagnostic counts and annotations need every match.
pub(super) fn scan_contains(
    len: usize,
    policy: ContainsPolicy,
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
                if matches!(policy, ContainsPolicy::FirstMatch) {
                    break;
                }
            }
        }
    }
    Ok(matches)
}

// Use only after proving every remaining predicate evaluation is supported.
// Annotation and diagnostic policies continue using the complete scan above.
pub(super) fn contains_validity(
    len: usize,
    min: usize,
    max: Option<usize>,
    mut evaluate: impl FnMut(usize) -> bool,
) -> Verdict {
    if len < min || max.is_some_and(|max| max < min) {
        return Invalid;
    }
    // Infinity and any bound at least as large as the array cannot constrain
    // its match count. The VM represents an absent maxContains as +Infinity.
    let max = max.filter(|&max| max < len);
    if min == 0 && max.is_none() {
        return Valid;
    }
    let mut matches = 0;
    for index in 0..len {
        matches += usize::from(evaluate(index));
        if max.is_some_and(|max| matches > max) {
            return Invalid;
        }
        if max.is_none() && matches >= min {
            return Valid;
        }
        if matches + (len - index - 1) < min {
            return Invalid;
        }
    }
    bounds(matches, Some(min), max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contains_termination_matches_complete_counts() {
        for len in 0..8 {
            for mask in 0..(1 << len) {
                let count = (mask as u32).count_ones() as usize;
                for min in 0..9 {
                    for max in [None, Some(0), Some(1), Some(4), Some(8)] {
                        assert_eq!(
                            contains_validity(len, min, max, |i| mask & (1 << i) != 0),
                            bounds(count, Some(min), max)
                        );
                    }
                }
            }
        }
        let mut calls = 0;
        assert_eq!(
            contains_validity(1000, 1, None, |_| {
                calls += 1;
                true
            }),
            Valid
        );
        assert_eq!(calls, 1);
    }

    #[test]
    fn termination_preserves_multiplicity_and_complete_scan_errors() {
        let nodes = [(0, 2), (1, 1)];
        let evaluate = |node| if node == 0 { Valid } else { Unsupported };
        for kind in [BranchKind::Any, BranchKind::One] {
            let result = scan_branches(
                &nodes,
                BranchPolicy::Validity(kind),
                false,
                evaluate,
                |_, _| Ok(()),
            )
            .unwrap();
            assert_eq!(result.matches, 2);
            assert_eq!(
                kind.accepts(result.matches),
                matches!(kind, BranchKind::Any)
            );
        }
        assert!(matches!(
            scan_branches(&nodes, BranchPolicy::Complete, false, evaluate, |_, _| Ok(
                ()
            )),
            Err(Unsupported)
        ));
    }

    #[test]
    fn contains_records_only_matches_and_retains_later_unsupported_results() {
        let mut recorded = vec![];
        let result = scan_contains(
            4,
            ContainsPolicy::AllMatches,
            |index| verdict(index % 2 == 0),
            |index| recorded.push(index),
        );
        assert_eq!(result, Ok(2));
        assert_eq!(recorded, [0, 2]);
        assert_eq!(
            scan_contains(
                2,
                ContainsPolicy::FirstMatch,
                |index| if index == 0 { Valid } else { Unsupported },
                |_| {}
            ),
            Ok(1)
        );
        assert_eq!(
            scan_contains(
                2,
                ContainsPolicy::AllMatches,
                |index| if index == 0 { Valid } else { Unsupported },
                |_| {}
            ),
            Err(Unsupported)
        );
    }
}
