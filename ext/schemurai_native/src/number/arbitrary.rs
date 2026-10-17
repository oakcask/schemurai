//! Cold arithmetic for magnitudes outside the fixed-width scalar paths.
//! Only ordinary numeric scalar operands are read; no Ruby allocation or
//! method dispatch can invalidate the evaluator's borrowed instance storage.
use super::*;
use num_bigint::{BigInt, Sign};
use num_traits::float::FloatCore;
use std::borrow::Cow;

// Use the application's BigInt version rather than num-rational's optional one.
pub(super) type BigRational = num_rational::Ratio<BigInt>;

fn binary_float(value: f64) -> Option<BigRational> {
    if !value.is_finite() {
        return None;
    }
    let (mantissa, exponent, sign) = value.integer_decode();
    let numerator = BigInt::from(mantissa) * BigInt::from(sign);
    Some(if exponent < 0 {
        BigRational::new(
            numerator,
            BigInt::from(1) << exponent.unsigned_abs() as usize,
        )
    } else {
        BigRational::from_integer(numerator << exponent as usize)
    })
}

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
    pub(super) fn arbitrary_check(
        &self,
        caches: &runtime::Caches,
        value: Value,
        budget: &budget::Budget,
        mut failure: impl FnMut(i32) -> bool,
    ) -> Result<i32, Verdict> {
        let float = unsafe { sn_is_float(value) } != 0;
        let n = if float {
            unsafe { sn_float(value) }
        } else {
            0.0
        };
        let actual = if float {
            if self.multiple.is_some() {
                if !n.is_finite() {
                    budget.failure.set(if n.is_nan() {
                        STATUS_DECIMAL_NAN
                    } else if n.is_sign_negative() {
                        STATUS_DECIMAL_NEGATIVE_INFINITY
                    } else {
                        STATUS_DECIMAL_POSITIVE_INFINITY
                    });
                    return Err(Unsupported);
                }
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
            binary_float(n)
        } else {
            None
        };
        let mut bits = 0;
        for (bit, limit) in &self.limits {
            if !budget.checkpoint() {
                return Err(Unsupported);
            }
            let violates = limit.violation(caches, value, *bit, self.multiple.is_some(), || {
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
                violates(*bit, order)
            })?;
            if violates {
                bits |= bit;
                if failure(*bit) {
                    return Ok(bits);
                }
            }
        }
        if let Some(limit) = &self.multiple {
            if !budget.checkpoint() {
                return Err(Unsupported);
            }
            let violates = limit.violation(caches, value, MULTIPLE_OF, true, || {
                let divisor = limit.fraction();
                let actual = actual.as_ref().expect("multipleOf decimal operand");
                let valid = divisor.numer().sign() == Sign::Plus
                    && (actual.numer() % divisor.numer()).sign() == Sign::NoSign
                    && (divisor.denom() % actual.denom()).sign() == Sign::NoSign;
                !valid
            })?;
            if violates {
                bits |= MULTIPLE_OF;
                failure(MULTIPLE_OF);
            }
        }
        Ok(bits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_float_preserves_exact_values() {
        let cases = [
            (0.0, BigRational::from_integer(BigInt::from(0))),
            (-0.0, BigRational::from_integer(BigInt::from(0))),
            (
                0.1,
                BigRational::new(BigInt::from(3602879701896397_u64), BigInt::from(1) << 55),
            ),
            (
                f64::from_bits(1),
                BigRational::new(BigInt::from(1), BigInt::from(1) << 1074),
            ),
            (
                f64::MIN_POSITIVE,
                BigRational::new(BigInt::from(1), BigInt::from(1) << 1022),
            ),
            (
                f64::MAX,
                BigRational::from_integer(BigInt::from((1_u64 << 53) - 1) << 971),
            ),
        ];
        for (value, expected) in cases {
            assert_eq!(binary_float(value), Some(expected.clone()), "{value}");
            assert_eq!(binary_float(-value), Some(-expected), "{}", -value);
        }
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(binary_float(value), None);
        }
    }
}
