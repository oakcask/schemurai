//! Invocation-local native limits. Exhaustion is terminal, not VM delegation.
use std::cell::Cell;
use std::time::{Duration, Instant};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Limits {
    pub max_errors: usize,
    pub enabled: u32,
    pub timeout: f64,
}
#[repr(C)]
#[derive(Default)]
pub struct Outcome {
    pub kind: u32,
    pub attempted: usize,
}
// Internal exhaustion reasons are converted to numeric tags only at the C boundary.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum LimitHit {
    #[default]
    None,
    MaxErrors {
        attempted: usize,
    },
    Timeout,
}
impl LimitHit {
    pub(super) fn is_hit(self) -> bool {
        self != Self::None
    }
}
impl From<LimitHit> for Outcome {
    fn from(hit: LimitHit) -> Self {
        match hit {
            LimitHit::None => Self::default(),
            LimitHit::MaxErrors { attempted } => Self { kind: 1, attempted },
            LimitHit::Timeout => Self {
                kind: 2,
                attempted: 0,
            },
        }
    }
}
#[derive(Default)]
pub(super) struct Budget {
    pub limits: Limits,
    pub hit: Cell<LimitHit>,
    pub failure: Cell<i32>,
    deadline: Option<Instant>,
    checks: Cell<usize>,
}
impl Budget {
    // Defer Ruby exception construction until all Rust frames have unwound.
    pub fn status(&self, verdict: super::Verdict) -> i32 {
        let failure = self.failure.get();
        if failure != 0 {
            failure
        } else {
            verdict as i32
        }
    }

    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            deadline: if limits.enabled & 2 != 0 {
                Duration::try_from_secs_f64(limits.timeout.max(0.0))
                    .ok()
                    .and_then(|duration| Instant::now().checked_add(duration))
            } else {
                None
            },
            ..Self::default()
        }
    }
    pub fn resume(limits: Limits, deadline: &Cell<Option<Instant>>) -> Self {
        let mut budget = Self::new(limits);
        if let Some(original) = deadline.get() {
            budget.deadline = Some(original);
        } else {
            deadline.set(budget.deadline);
        }
        budget
    }
    pub fn timed(&self) -> bool {
        self.limits.enabled & 2 != 0
    }
    pub fn check_deadline(&self) -> bool {
        if self.hit.get().is_hit() {
            return false;
        }
        if self
            .deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.hit.set(LimitHit::Timeout);
            return false;
        }
        true
    }
    pub fn checkpoint(&self) -> bool {
        if !self.timed() {
            return true;
        }
        let checks = self.checks.get().wrapping_add(1);
        self.checks.set(checks);
        if checks & 255 == 0 {
            self.check_deadline()
        } else {
            !self.hit.get().is_hit()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deadline_is_sampled_and_exhaustion_is_sticky() {
        let mut budget = Budget::new(Limits {
            timeout: 10.0,
            enabled: 2,
            ..Limits::default()
        });
        assert!(budget.check_deadline());
        budget.deadline = Some(Instant::now() - Duration::from_secs(1));
        for _ in 0..255 {
            assert!(budget.checkpoint());
        }
        assert!(!budget.checkpoint());
        assert_eq!(budget.hit.get(), LimitHit::Timeout);
        assert!(!budget.checkpoint());
    }

    #[test]
    fn huge_finite_deadlines_do_not_panic() {
        assert!(
            Budget::new(Limits {
                timeout: f64::MAX,
                enabled: 2,
                ..Limits::default()
            })
            .check_deadline()
        );
    }

    #[test]
    fn runtime_retries_retain_the_original_native_deadline() {
        let original = Instant::now() - Duration::from_secs(1);
        let deadline = Cell::new(Some(original));
        let budget = Budget::resume(
            Limits {
                timeout: 10.0,
                enabled: 2,
                ..Limits::default()
            },
            &deadline,
        );
        assert!(!budget.check_deadline());
        assert_eq!(budget.hit.get(), LimitHit::Timeout);
        assert_eq!(deadline.get(), Some(original));
        deadline.set(None);
        assert!(
            Budget::resume(
                Limits {
                    timeout: 10.0,
                    enabled: 2,
                    ..Limits::default()
                },
                &deadline
            )
            .check_deadline()
        );
    }
}
