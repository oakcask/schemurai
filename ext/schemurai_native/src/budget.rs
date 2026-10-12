//! Invocation-local native limits. Exhaustion is terminal, not VM delegation.
use super::*;
use std::cell::Cell;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Limits {
    pub max_errors: usize,
    pub max_output_bytes: usize,
    pub max_evaluations: usize,
    pub enabled: u32,
}
#[repr(C)]
#[derive(Default)]
pub struct Outcome {
    pub spent: usize,
    pub kind: u32,
    pub attempted: usize,
}
#[derive(Default)]
pub(super) struct Budget {
    pub limits: Limits,
    pub spent: Cell<usize>,
    pub hit: Cell<(u32, usize)>,
}
impl Budget {
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            ..Self::default()
        }
    }
    pub fn charge(&self, amount: usize) -> bool {
        if self.limits.enabled & 4 == 0 {
            return true;
        }
        if self.hit.get().0 != 0 {
            return false;
        }
        let attempted = self.spent.get().saturating_add(amount);
        self.spent.set(attempted);
        if attempted > self.limits.max_evaluations {
            self.hit.set((3, attempted));
            return false;
        }
        true
    }
    pub fn context(&self, context: scope::Context<'_>) -> bool {
        if self.limits.enabled & 4 == 0 {
            return true;
        }
        let mut frame = context.scope;
        while let Some(current) = frame {
            if !self.charge(1) {
                return false;
            }
            frame = current.parent;
        }
        let mut active = context.active;
        while let Some(current) = active {
            if !self.charge(1) {
                return false;
            }
            active = current.parent;
        }
        true
    }
    pub fn scalar(&self, value: Value) -> bool {
        if self.limits.enabled & 4 == 0 {
            return true;
        }
        self.charge(unsafe { sn_scalar_bytes(value) })
    }
    pub fn node(&self, ops: &[Op], value: Value) -> bool {
        self.charge(1 + ops.len()) && self.scalar(value)
    }
    pub fn array(&self, value: Value) -> bool {
        if self.limits.enabled & 4 == 0 {
            return true;
        }
        let len = unsafe { sn_len(value) };
        if !self.charge(len) {
            return false;
        }
        (0..len).all(|index| self.scalar(unsafe { sn_entry(value, index) }))
    }
    pub fn object(&self, value: Value, rules: &Object) -> bool {
        if self.limits.enabled & 4 == 0 {
            return true;
        }
        let len = unsafe { sn_len(value) };
        if !self.charge(
            len.saturating_mul(1 + rules.patterns.len())
                .saturating_add(rules.required.len()),
        ) {
            return false;
        }
        for &name in &rules.required {
            if !self.scalar(name) {
                return false;
            }
        }
        for &(name, ref required) in &rules.dependent_required {
            if !self.charge(1 + required.len()) || !self.scalar(name) {
                return false;
            }
            for &name in required {
                if !self.scalar(name) {
                    return false;
                }
            }
        }
        if !self.charge(rules.dependent_schemas.len()) {
            return false;
        }
        let context = Walk {
            budget: self,
            factor: 1 + rules.patterns.len(),
        };
        (unsafe {
            sn_hash_each(
                value,
                (&context as *const Walk<'_>).cast_mut().cast(),
                entry,
            )
        }) == VERDICT_VALID
    }
}
struct Walk<'a> {
    budget: &'a Budget,
    factor: usize,
}
unsafe extern "C" fn entry(context: *mut c_void, key: Value, value: Value) -> i32 {
    let c = unsafe { &*context.cast::<Walk<'_>>() };
    verdict(
        c.budget
            .charge((unsafe { sn_scalar_bytes(key) }).saturating_mul(c.factor))
            && c.budget.scalar(value),
    ) as i32
}

pub(super) fn json_bytes(bytes: &[u8]) -> usize {
    bytes.iter().fold(0_usize, |count, &byte| {
        count.saturating_add(match byte {
            b'"' | b'\\' | 8 | 9 | 10 | 12 | 13 => 2,
            0..=31 => 6,
            _ => 1,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exhaustion_is_sticky_and_reports_the_attempted_work() {
        let budget = Budget::new(Limits {
            max_evaluations: 10,
            enabled: 4,
            ..Limits::default()
        });
        assert!(budget.charge(10));
        assert!(!budget.charge(1));
        assert_eq!(budget.hit.get(), (3, 11));
        assert!(!budget.charge(100));
        assert_eq!(budget.spent.get(), 11);
        assert!(Budget::default().charge(usize::MAX));
    }

    #[test]
    fn json_size_counts_utf8_and_escaping_without_serialization() {
        assert_eq!(json_bytes("日本語".as_bytes()), 9);
        assert_eq!(json_bytes(b"\"\\\n\x01/"), 13);
    }
}
