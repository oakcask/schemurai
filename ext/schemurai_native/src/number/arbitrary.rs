//! Cold arithmetic for magnitudes outside the fixed-width scalar paths.
//! Only ordinary numeric scalar operands are read; no Ruby allocation or
//! method dispatch can invalidate the evaluator's borrowed instance storage.
use super::*;
use num_bigint::{BigInt, Sign};
use std::borrow::Cow;

fn integer(value: Value) -> BigInt {
    if unsafe { sn_fixnum(value) } != 0 {
        return BigInt::from(unsafe { sn_integer(value) });
    }
    let (words, sign) = unbounded_integer_words(value);
    let digits = words
        .into_iter()
        .flat_map(|word| [word as u32, (word >> 32) as u32])
        .collect();
    BigInt::new(if sign < 0 { Sign::Minus } else { Sign::Plus }, digits)
}

pub(super) fn fraction(numerator: Value, denominator: Option<Value>) -> BigRational {
    BigRational::new(
        integer(numerator),
        denominator.map_or_else(|| BigInt::from(1), integer),
    )
}

fn decimal(value: f64) -> Option<BigRational> {
    let Decimal { coefficient, power } = decimal_parts(value)?;
    let scale = BigInt::from(10).pow(power.unsigned_abs());
    Some(if power >= 0 {
        BigRational::from_integer(BigInt::from(coefficient) * scale)
    } else {
        BigRational::new(BigInt::from(coefficient), scale)
    })
}

impl Limit {
    fn fraction(&self) -> Cow<'_, BigRational> {
        if let Some(fraction) = &self.arbitrary {
            Cow::Borrowed(fraction)
        } else {
            let fraction = self.exact.expect("compiled numeric fraction");
            Cow::Owned(BigRational::new_raw(
                BigInt::from(fraction.numerator),
                BigInt::from(fraction.denominator),
            ))
        }
    }

    pub(super) fn arbitrary_memory_usage(&self) -> usize {
        self.arbitrary.as_ref().map_or(0, |fraction| {
            // num-bigint exposes used digits rather than allocation capacity.
            std::mem::size_of::<BigRational>()
                + (fraction.numer().bits().div_ceil(64) + fraction.denom().bits().div_ceil(64))
                    as usize
                    * 8
        })
    }
}

impl Rules {
    pub(super) fn arbitrary_failures(&self, value: Value) -> Result<i32, Verdict> {
        let float = unsafe { sn_is_float(value) } != 0;
        let n = if float {
            unsafe { sn_float(value) }
        } else {
            0.0
        };
        let actual = if float {
            if self.multiple.is_some() {
                Some(decimal(n).ok_or(Unsupported)?)
            } else {
                None
            }
        } else {
            if unsafe { sn_kind(value) } & TYPE_INTEGER == 0 {
                return Err(Unsupported);
            }
            Some(BigRational::from_integer(integer(value)))
        };
        // Without multipleOf, Ruby compares a Float to Integer bounds exactly
        // in binary, but rounds Rational bounds to Float. With multipleOf,
        // Ruby first converts the instance's decimal spelling to a Rational.
        let binary = if actual.is_none() && self.limits.iter().any(|(_, limit)| limit.integer) {
            BigRational::from_float(n)
        } else {
            None
        };
        let mut bits = 0;
        for (bit, limit) in &self.limits {
            let order = if let Some(actual) = &actual {
                Some(actual.cmp(limit.fraction().as_ref()))
            } else if !limit.integer {
                n.partial_cmp(&limit.rounded)
            } else if let Some(binary) = &binary {
                Some(binary.cmp(limit.fraction().as_ref()))
            } else if n.is_nan() {
                None
            } else {
                Some(if n.is_sign_negative() {
                    Ordering::Less
                } else {
                    Ordering::Greater
                })
            };
            if violates(*bit, order) {
                bits |= bit;
            }
        }
        if let Some(limit) = &self.multiple {
            let divisor = limit.fraction();
            let actual = actual.as_ref().expect("multipleOf decimal operand");
            let valid = divisor.numer().sign() == Sign::Plus
                && (actual.numer() % divisor.numer()).sign() == Sign::NoSign
                && (divisor.denom() % actual.denom()).sign() == Sign::NoSign;
            if !valid {
                bits |= MULTIPLE_OF;
            }
        }
        Ok(bits)
    }
}
