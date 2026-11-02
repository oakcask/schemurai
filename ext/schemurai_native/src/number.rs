//! Numeric instructions distinguish Ruby's ordinary comparison from decimal
//! multipleOf semantics. All evaluation helpers operate under the GVL and
//! allocate no Ruby objects; unsupported magnitudes retain VM compatibility.
use super::*;
use arbitrary::BigRational;
use std::cmp::Ordering;
mod arbitrary;

// Strictly ordered integers are unique without fingerprinting their digits.
// Each comparison checks both original handles; mixed or unordered inputs
// retain the indexed JSON equality path. No Ruby allocation occurs here.
pub(super) fn ordered_big_unique(values: &[Value]) -> Option<Verdict> {
    let direction = unsafe { sn_big_order(values[0], values[1]) };
    match direction {
        0 => return Some(Invalid),
        -1 | 1 => {}
        _ => return None,
    }
    for (offset, pair) in values[1..].windows(2).enumerate() {
        let order = unsafe { sn_big_order(pair[0], pair[1]) };
        if order == 0 {
            return Some(Invalid);
        }
        if order != direction {
            // A return to the first value is a duplicate even when it breaks
            // the order. Otherwise indexing must examine the entire input.
            if order == ADAPTER_UNSUPPORTED {
                return None;
            }
            if unsafe { sn_big_order(values[0], pair[1]) } == 0 {
                return Some(Invalid);
            }
            let tail = offset + 2;
            return (values.len() - tail <= 16)
                .then(|| ordered_tail_unique(values, tail, direction))
                .flatten();
        }
    }
    Some(Valid)
}

// A short unordered tail can search the proven ordered prefix directly.
// Bound the tail to keep its internal pair comparisons constant-sized and
// avoid rebuilding a full fingerprint index after an almost complete scan.
fn ordered_tail_unique(values: &[Value], prefix: usize, direction: i32) -> Option<Verdict> {
    for at in prefix..values.len() {
        let (mut low, mut high) = (0, prefix);
        while low < high {
            let middle = low + (high - low) / 2;
            match unsafe { sn_big_order(values[middle], values[at]) } {
                0 => return Some(Invalid),
                ADAPTER_UNSUPPORTED => return None,
                order if order == direction => low = middle + 1,
                _ => high = middle,
            }
        }
        for previous in prefix..at {
            if unsafe { sn_big_order(values[previous], values[at]) } == 0 {
                return Some(Invalid);
            }
        }
    }
    Some(Valid)
}

// A finite binary64 integer has at most 1,024 magnitude bits. Arithmetic
// adapters fill fixed stack words; there is no instance-tree conversion or
// Ruby allocation. Larger integers cannot equal any finite Float.
pub(super) fn integer_float_equal(integer: Value, float: f64) -> Verdict {
    if !float.is_finite() || float.trunc() != float {
        return Invalid;
    }
    let mut actual = [0_u64; 16];
    let sign = unsafe { sn_integer1024(integer, actual.as_mut_ptr()) };
    if sign.abs() > 1 || (sign < 0) != (float < 0.0) {
        return Invalid;
    }
    let mut expected = [0_u64; 16];
    if float != 0.0 {
        let bits = float.to_bits();
        let mantissa = (bits & ((1_u64 << 52) - 1)) | (1_u64 << 52);
        let shift = ((bits >> 52) & 0x7ff) as i32 - 1023 - 52;
        if shift < 0 {
            expected[0] = mantissa >> shift.unsigned_abs();
        } else {
            let word = shift as usize / 64;
            let bit = shift as usize % 64;
            expected[word] = mantissa << bit;
            if bit != 0 && word + 1 < expected.len() {
                expected[word + 1] = mantissa >> (64 - bit);
            }
        }
    }
    verdict(actual == expected)
}

pub(super) fn integer_fingerprint(integer: Value) -> u64 {
    let mut words = [0_u64; 16];
    let sign = unsafe { sn_integer1024(integer, words.as_mut_ptr()) };
    if sign.abs() > 1 {
        // No finite Float can equal this magnitude, so the full native digit
        // hash needs no Float normalization. Sampling only low digits makes
        // mixed/nested uniqueItems quadratic for differences above bit 1024
        // and collapses large enum indexes into a single candidate bucket.
        // The adapter hashes the original Bignum without Ruby dispatch or
        // allocation; exact equality still decides every hash collision.
        return mix(big_only_fingerprint(integer).unwrap() ^ TYPE_NUMBER as u64);
    }
    exact_integer_fingerprint(&words, sign)
}

pub(super) fn big_fingerprint(integer: Value) -> Option<u64> {
    let mut words = [0_u64; 4];
    let sign = unsafe { sn_big256(integer, words.as_mut_ptr()) };
    if sign == ADAPTER_UNSUPPORTED {
        return None;
    }
    Some(if sign.abs() > 1 {
        integer_fingerprint(integer)
    } else {
        exact_integer_fingerprint(&words, sign)
    })
}

// Only used by an index that restarts with canonical fingerprints if any item
// is not a Bignum. No Float can enter this index, so it needs no binary64
// normalization. Full integer equality resolves every fingerprint collision.
pub(super) fn big_only_fingerprint(integer: Value) -> Option<u64> {
    let mut hash = 0;
    (unsafe { sn_big_hash(integer, &mut hash) } != 0).then_some(hash)
}

// This convention is restricted to Big/Big comparisons. The caller restarts
// with the full hash when collisions accumulate, or canonical fingerprints
// when a non-Bignum appears. No sampled metadata decides equality.
pub(super) fn big_low_fingerprint(integer: Value) -> Option<u64> {
    let sample = unsafe { sn_big_low_word(integer) };
    (sample != 1 << 33).then(|| {
        // Fold the short magnitude sample without scrambling adjacent low
        // words. Exact equality and wider bounded retries resolve collisions.
        let bits = u64::from(sample as u32) ^ if sample & (1 << 32) != 0 { u64::MAX } else { 0 };
        let folded = bits ^ (bits >> 33);
        folded ^ (folded >> 11) ^ (folded >> 22)
    })
}

pub(super) fn big_low64_fingerprint(integer: Value) -> Option<u64> {
    let mut word = 0;
    let sign = unsafe { sn_big_low64_word(integer, &mut word) };
    (sign != 3).then(|| {
        let bits = word ^ if sign < 0 { u64::MAX } else { 0 };
        let folded = bits ^ (bits >> 33);
        let folded = folded ^ (folded >> 11) ^ (folded >> 22);
        folded.wrapping_mul(0x9e3779b97f4a7c15)
    })
}

fn exact_integer_fingerprint(words: &[u64], sign: i32) -> u64 {
    let top = words.iter().rposition(|&word| word != 0).unwrap_or(0);
    if top == 0 && (words[0] < (1_u64 << 63) || (sign < 0 && words[0] == 1_u64 << 63)) {
        let bits = if sign < 0 {
            words[0].wrapping_neg()
        } else {
            words[0]
        };
        return mix(bits ^ TYPE_NUMBER as u64);
    }
    let exponent = top * 64 + 63 - words[top].leading_zeros() as usize;
    let shift = exponent - 52;
    let word = shift / 64;
    let bit = shift % 64;
    if words[..word].iter().any(|&word| word != 0)
        || (bit != 0 && words[word] & ((1_u64 << bit) - 1) != 0)
    {
        // Nonrepresentable integers cannot equal any Float. Keep their low
        // digits instead of putting nearby integers into one rounded bucket.
        return integer_bucket(&words[..=top], sign, exponent / 8 + 1);
    }
    let mut mantissa = words[word] >> bit;
    if bit != 0 && word + 1 < words.len() {
        mantissa |= words[word + 1] << (64 - bit);
    }
    // Exactly representable integers share bits with their equal Float.
    // Every collision still goes through full JSON equality.
    let bits = ((sign < 0) as u64) << 63
        | ((exponent + 1023) as u64) << 52
        | (mantissa & ((1_u64 << 52) - 1));
    mix(bits ^ TYPE_NUMBER as u64)
}

// Callers supply the prefix ending at the last nonzero word. It may be empty
// when all sampled low words of an oversized integer are zero.
fn integer_bucket(words: &[u64], sign: i32, bytes: usize) -> u64 {
    let mut hash = bytes as u64 ^ TYPE_NUMBER as u64 ^ ((sign < 0) as u64);
    // Independent lanes shorten the multiplication dependency chain while
    // retaining every sampled word. Full VALUE equality resolves collisions.
    let mut other = hash ^ 0x9e37_79b9_7f4a_7c15;
    let (pairs, remainder) = words.as_chunks::<2>();
    for pair in pairs {
        hash = (hash ^ pair[0]).wrapping_mul(0x0000_0100_0000_01b3);
        other = (other ^ pair[1]).wrapping_mul(0x0000_0100_0000_01b3);
    }
    if let [word] = remainder {
        hash = (hash ^ word).wrapping_mul(0x0000_0100_0000_01b3);
    }
    mix(hash ^ other.rotate_left(32))
}

#[derive(Debug, Clone, Copy)]
struct Fraction {
    numerator: i128,
    denominator: i128,
}
impl Fraction {
    fn compare(self, other: Self) -> Ordering {
        let signs = self.numerator.signum().cmp(&other.numerator.signum());
        if signs != Ordering::Equal {
            return signs;
        }
        let (mut a, mut b) = (self.numerator.unsigned_abs(), self.denominator as u128);
        let (mut c, mut d) = (other.numerator.unsigned_abs(), other.denominator as u128);
        let mut reverse = self.numerator < 0;
        loop {
            let order = (a / b).cmp(&(c / d));
            if order != Ordering::Equal {
                return if reverse { order.reverse() } else { order };
            }
            let (r, s) = (a % b, c % d);
            if r == 0 || s == 0 {
                let order = r.cmp(&s);
                return if reverse { order.reverse() } else { order };
            }
            (a, b, c, d) = (b, r, d, s);
            reverse = !reverse;
        }
    }

    fn multiple_of(self, divisor: Self) -> bool {
        // Both fractions are reduced: p must divide n and d must divide q.
        divisor.numerator > 0
            && self.numerator % divisor.numerator == 0
            && divisor.denominator % self.denominator == 0
    }
}

struct Decimal {
    coefficient: i128,
    power: i32,
}

fn decimal_parts(value: f64) -> Option<Decimal> {
    if !value.is_finite() {
        return None;
    }
    let mut buffer = ryu::Buffer::new();
    let mut bytes = buffer.format_finite(value).as_bytes();
    let negative = bytes.first() == Some(&b'-');
    if negative {
        bytes = &bytes[1..];
    }
    let exponent = if let Some(at) = bytes.iter().position(|&byte| byte == b'e') {
        let exponent = std::str::from_utf8(&bytes[at + 1..])
            .ok()?
            .parse::<i32>()
            .ok()?;
        bytes = &bytes[..at];
        exponent
    } else {
        0
    };
    let fractional = bytes
        .iter()
        .position(|&b| b == b'.')
        .map_or(0, |at| bytes.len() - at - 1);
    let mut end = bytes.len();
    let mut trailing = 0;
    while end > 0 && (bytes[end - 1] == b'0' || bytes[end - 1] == b'.') {
        if bytes[end - 1] == b'0' {
            trailing += 1;
        }
        end -= 1;
    }
    let mut numerator = 0_i128;
    for &byte in &bytes[..end] {
        if byte == b'.' {
            continue;
        }
        if !byte.is_ascii_digit() {
            return None;
        }
        numerator = numerator
            .checked_mul(10)?
            .checked_add(i128::from(byte.checked_sub(b'0')?))?;
    }
    if numerator == 0 {
        return Some(Decimal {
            coefficient: 0,
            power: 0,
        });
    }
    let power = exponent + trailing - fractional as i32;
    Some(Decimal {
        coefficient: if negative { -numerator } else { numerator },
        power,
    })
}

fn decimal_float(value: f64) -> Option<Fraction> {
    let Decimal { coefficient, power } = decimal_parts(value)?;
    let mut numerator = coefficient.abs();
    let mut denominator = 1;
    if power >= 0 {
        numerator = numerator.checked_mul(10_i128.checked_pow(power as u32)?)?;
    } else {
        denominator = 10_i128.checked_pow(power.unsigned_abs())?;
    }
    let (mut a, mut b) = (numerator, denominator);
    while b != 0 {
        (a, b) = (b, a % b);
    }
    Some(Fraction {
        numerator: if coefficient < 0 {
            -numerator / a
        } else {
            numerator / a
        },
        denominator: denominator / a,
    })
}
#[derive(Debug, Default)]
struct Limit {
    null: bool,
    exact: Option<Fraction>,
    arbitrary: Option<Box<BigRational>>,
    wide_integer: Option<Value>,
    wide_rounded_order: Option<Ordering>,
    rounded: f64,
    integer: bool,
    sum_words: bool,
}

impl Limit {
    fn violation(
        &self,
        caches: &runtime::Caches,
        value: Value,
        bit: i32,
        decimal: bool,
        native: impl FnOnce() -> bool,
    ) -> Result<bool, Verdict> {
        if self.null {
            match caches.null_number(value, bit, decimal) {
                Valid => Ok(false),
                Invalid => Ok(true),
                Unsupported => Err(Unsupported),
            }
        } else {
            Ok(native())
        }
    }
    fn float_order(&self, n: f64) -> Result<Option<Ordering>, Verdict> {
        if let Some(exact) = self.exact {
            return Ok(compare_float_integer(n, exact.numerator));
        }
        let Some(tie) = self.wide_rounded_order else {
            return Err(Unsupported);
        };
        // Adjacent Floats cannot lie inside the rounding interval of an
        // Integer. Only equality with its rounded Float needs an exact tie.
        Ok(n.partial_cmp(&self.rounded).map(
            |order| {
                if order == Ordering::Equal { tie } else { order }
            },
        ))
    }
    // Runtime callers have classified the instance as an ordinary Integer.
    // Wide schema bounds remain rooted Ruby handles, with no digit export.
    fn integer_order(&self, value: Value, integer: Option<i128>, sign: i32) -> Option<Ordering> {
        if let Some(exact) = self.exact {
            return Some(integer.map_or_else(
                || {
                    if sign > 0 {
                        Ordering::Greater
                    } else {
                        Ordering::Less
                    }
                },
                |n| compare_integer(n, exact),
            ));
        }
        self.wide_integer
            .map(|bound| unsafe { sn_wide_integer_compare(value, bound) }.cmp(&0))
    }
}
#[derive(Debug)]
pub(super) struct Rules {
    source: Value,
    limits: Vec<(i32, Limit)>,
    multiple: Option<Limit>,
    pub(super) fast_limits: Option<Vec<(i32, i64)>>,
    pub(super) fast_multiple: Option<FastMultiple>,
    fixnum_flag: FixnumTag,
    bounds_view: bool,
    bounded_signs: Option<[bool; 2]>,
    runtime_operands: bool,
}

#[derive(Debug)]
pub(super) struct FastMultiple {
    numerator: i64,
    limits: Vec<(i32, i64)>,
}

impl FastMultiple {
    fn failures(&self, n: i64) -> i32 {
        // An Integer has denominator 1. For a reduced divisor p/q, only
        // divisibility by p remains; q is always divisible by 1.
        let mut bits = if self.numerator > 0 && n % self.numerator == 0 {
            0
        } else {
            MULTIPLE_OF
        };
        for &(bit, limit) in &self.limits {
            if match bit {
                MAXIMUM => n > limit,
                MINIMUM => n < limit,
                EXCLUSIVE_MAXIMUM => n >= limit,
                _ => n <= limit,
            } {
                bits |= bit;
            }
        }
        bits
    }

    pub(super) fn eval(&self, n: i64) -> Verdict {
        verdict(self.failures(n) == 0)
    }
}

impl Engine {
    pub(super) fn compile_number(
        &mut self,
        vm: &mut Ruby,
        operand: Value,
    ) -> Result<Option<Rules>, Value> {
        let mask = self.field(vm, operand, FIELD_MASK)?;
        let mask = unsafe { sn_integer(mask) } as i32;
        let mut limits = vec![];
        for (bit, name) in [
            (MAXIMUM, FIELD_MAXIMUM),
            (MINIMUM, FIELD_MINIMUM),
            (EXCLUSIVE_MAXIMUM, FIELD_EXCLUSIVE_MAXIMUM),
            (EXCLUSIVE_MINIMUM, FIELD_EXCLUSIVE_MINIMUM),
        ] {
            if mask & bit != 0 {
                let value = self.field(vm, operand, name)?;
                let Some(limit) = self.numeric_limit(vm, value)? else {
                    return Ok(None);
                };
                limits.push((bit, limit));
            }
        }
        let multiple = if mask & MULTIPLE_OF == 0 {
            None
        } else {
            let value = self.field(vm, operand, FIELD_MULTIPLE_OF)?;
            let Some(limit) = self.numeric_limit(vm, value)? else {
                return Ok(None);
            };
            Some(limit)
        };
        let fast_limits = if multiple.is_some() {
            None
        } else {
            limits
                .iter()
                .map(|(bit, limit)| {
                    if !limit.integer {
                        return None;
                    }
                    Some((*bit, i64::try_from(limit.exact?.numerator).ok()?))
                })
                .collect()
        };
        let fast_multiple = multiple
            .as_ref()
            .and_then(|limit| limit.exact)
            .and_then(|fraction| i64::try_from(fraction.numerator).ok())
            .and_then(|numerator| {
                let limits = limits
                    .iter()
                    .map(|&(bit, ref limit)| {
                        let fraction = limit.exact?;
                        (fraction.denominator == 1)
                            .then(|| i64::try_from(fraction.numerator).ok())
                            .flatten()
                            .map(|n| (bit, n))
                    })
                    .collect::<Option<Vec<_>>>()?;
                Some(FastMultiple { numerator, limits })
            });
        let bounds_view = multiple.is_none() && limits.iter().all(|(_, limit)| limit.integer);
        let bounded_signs = (bounds_view && limits.iter().all(|(_, limit)| limit.exact.is_some()))
            .then(|| {
                [
                    !limits
                        .iter()
                        .any(|(bit, _)| matches!(*bit, MINIMUM | EXCLUSIVE_MINIMUM)),
                    !limits
                        .iter()
                        .any(|(bit, _)| matches!(*bit, MAXIMUM | EXCLUSIVE_MAXIMUM)),
                ]
            });
        let runtime_operands = limits.iter().any(|(_, limit)| limit.null)
            || multiple.as_ref().is_some_and(|limit| limit.null);
        Ok(Some(Rules {
            source: operand,
            runtime_operands,
            limits,
            multiple,
            fast_limits,
            fast_multiple,
            fixnum_flag: self.fixnum_flag,
            bounds_view,
            bounded_signs,
        }))
    }

    fn numeric_limit(&mut self, vm: &mut Ruby, value: Value) -> Result<Option<Limit>, Value> {
        if unsafe { sn_same(value, sn_nil()) } != 0 {
            return Ok(Some(Limit {
                null: true,
                ..Limit::default()
            }));
        }
        let integer = unsafe { sn_kind(value) } & TYPE_INTEGER != 0;
        if !integer && unsafe { sn_is_rational(value) } == 0 {
            return Ok(None);
        }
        let (numerator, denominator) = if integer {
            (value, None)
        } else {
            let numerator = self.field(vm, value, FIELD_NUMERATOR)?;
            let denominator = self.field(vm, value, FIELD_DENOMINATOR)?;
            (numerator, Some(denominator))
        };
        let exact = read_integer(numerator)
            .zip(denominator.map_or(Some(1), read_integer))
            .map(|(numerator, denominator)| Fraction {
                numerator,
                denominator,
            });
        let arbitrary = exact
            .is_none()
            .then(|| Box::new(arbitrary::fraction(numerator, denominator)));
        let rounded = self.field(vm, value, FIELD_TO_F)?;
        let rounded = unsafe { sn_float(rounded) };
        let wide_rounded_order = if integer && exact.is_none() {
            wide_float_tie(value, rounded)
        } else {
            None
        };
        let sum_words = exact.is_some_and(|fraction| {
            fraction.numerator > 1 && (1_u128 << 64) % fraction.numerator as u128 == 1
        });
        Ok(Some(Limit {
            null: false,
            exact,
            arbitrary,
            wide_integer: (integer && exact.is_none()).then(|| self.retain(value)),
            wide_rounded_order,
            rounded,
            integer,
            sum_words,
        }))
    }
}

fn read_integer(value: Value) -> Option<i128> {
    read_integer_status(value).ok()
}

// Err(sign) identifies a magnitude outside i128; Err(0) is not an Integer.
fn read_integer_status(value: Value) -> Result<i128, i32> {
    if unsafe { sn_fixnum(value) } != 0 {
        return Ok(unsafe { sn_integer(value) } as i128);
    }
    if unsafe { sn_kind(value) } & TYPE_INTEGER == 0 || unsafe { sn_is_float(value) } != 0 {
        return Err(0);
    }
    unpack_integer_status(value)
}

// Runtime numeric instructions have already rejected non-numeric instances.
// Their non-Float branch contains only ordinary Integers; compilation uses
// read_integer_status instead because schema metadata still needs checking.
fn read_known_integer_status(value: Value, fixnum_flag: FixnumTag) -> Result<i128, i32> {
    if value.has_fixnum_tag(fixnum_flag) {
        return Ok(immediate_integer(value) as i128);
    }
    let mut words = [0_u64; 2];
    let sign = unsafe { sn_integer_bounds128(value, words.as_mut_ptr()) };
    integer_words_status(&words, sign)
}

fn unpack_integer_status(value: Value) -> Result<i128, i32> {
    let mut words = [0_u64; 2];
    let sign = unsafe { sn_integer128(value, words.as_mut_ptr()) };
    integer_words_status(&words, sign)
}

fn integer_words_status(words: &[u64], sign: i32) -> Result<i128, i32> {
    if sign.abs() > 1 {
        return Err(sign);
    }
    if words[2..].iter().any(|&word| word != 0) {
        return Err(sign);
    }
    let magnitude = u128::from(words[0]) | (u128::from(words[1]) << 64);
    if sign < 0 {
        if magnitude == 1_u128 << 127 {
            Ok(i128::MIN)
        } else {
            i128::try_from(magnitude)
                .map_err(|_| sign)?
                .checked_neg()
                .ok_or(sign)
        }
    } else {
        i128::try_from(magnitude).map_err(|_| sign)
    }
}

fn wide_integer_multiple(value: Value, divisor: Fraction, sum_words: bool) -> Verdict {
    if divisor.numerator <= 0 {
        return Invalid;
    }
    if divisor.numerator == 1 {
        return Valid;
    }
    let mut words = [0_u64; 16];
    if unsafe { sn_integer1024(value, words.as_mut_ptr()) }.abs() > 1 {
        return unbounded_integer_multiple(value, divisor, sum_words);
    }
    wide_multiple_words(&words, divisor, sum_words)
}

fn unbounded_integer_multiple(value: Value, divisor: Fraction, sum_words: bool) -> Verdict {
    let (words, _) = unbounded_integer_words(value);
    wide_multiple_words(&words, divisor, sum_words)
}

fn unbounded_integer_words(value: Value) -> (Vec<u64>, i32) {
    let count = unsafe { sn_integer_word_count(value) };
    let mut words = vec![0_u64; count];
    let sign = unsafe { sn_integer_words(value, words.as_mut_ptr(), count) };
    (words, sign)
}

fn wide_multiple_words(words: &[u64], divisor: Fraction, sum_words: bool) -> Verdict {
    let len = words
        .iter()
        .rposition(|&word| word != 0)
        .map_or(0, |i| i + 1);
    let divisor = divisor.numerator as u128;
    let mut remainder = 0_u128;
    if sum_words {
        // If base 2^64 is 1 modulo the divisor, a magnitude has the same
        // remainder as the sum of its words. An addressable slice of u64 words
        // sums within u128, so one remainder replaces per-word division.
        remainder = words[..len]
            .iter()
            .map(|&word| u128::from(word))
            .sum::<u128>()
            % divisor;
    } else if divisor <= u64::MAX as u128 {
        // remainder < divisor <= u64::MAX, so shifting it by 64 fits u128.
        for &word in words[..len].iter().rev() {
            remainder = ((remainder << 64) | u128::from(word)) % divisor;
        }
    } else {
        // The positive divisor is at most i128::MAX. Doubling a remainder
        // below it cannot overflow u128; consume magnitude bits without
        // allocating or multiplying an arbitrary-precision integer.
        for &word in words[..len].iter().rev() {
            for bit in (0..64).rev() {
                remainder = (remainder << 1) | u128::from((word >> bit) & 1);
                if remainder >= divisor {
                    remainder -= divisor;
                }
            }
        }
    }
    // The instance denominator is one, which divides the reduced divisor's
    // denominator. Sign does not affect divisibility by its positive numerator.
    verdict(remainder == 0)
}

fn violates(bit: i32, order: Option<Ordering>) -> bool {
    match bit {
        MAXIMUM => order == Some(Ordering::Greater),
        MINIMUM => order == Some(Ordering::Less),
        EXCLUSIVE_MAXIMUM => matches!(order, Some(Ordering::Greater | Ordering::Equal)),
        _ => matches!(order, Some(Ordering::Less | Ordering::Equal)),
    }
}

fn fixnum_bounds(n: i64, limits: &[(i32, i64)]) -> Verdict {
    verdict(limits.iter().all(|&(bit, limit)| match bit {
        MAXIMUM => n <= limit,
        MINIMUM => n >= limit,
        EXCLUSIVE_MAXIMUM => n < limit,
        _ => n > limit,
    }))
}

fn compare_integer(n: i128, limit: Fraction) -> Ordering {
    let whole = limit.numerator / limit.denominator;
    n.cmp(&whole)
        .then_with(|| 0.cmp(&(limit.numerator % limit.denominator)))
}

fn compare_float_integer(n: f64, limit: i128) -> Option<Ordering> {
    if n.is_nan() {
        return None;
    }
    if n < i128::MIN as f64 {
        return Some(Ordering::Less);
    }
    if n >= i128::MAX as f64 {
        return Some(Ordering::Greater);
    }
    Some(
        (n as i128)
            .cmp(&limit)
            .then_with(|| n.fract().partial_cmp(&0.0).unwrap()),
    )
}

// Schema metadata only: record the comparison at the rounded Float once.
// Every finite binary64 magnitude fits 1,024 bits. No instance digit export
// or Ruby allocation is needed at runtime, and no word buffer is retained.
fn wide_float_tie(value: Value, rounded: f64) -> Option<Ordering> {
    if rounded.is_infinite() {
        return Some(if rounded.is_sign_negative() {
            Ordering::Less
        } else {
            Ordering::Greater
        });
    }
    let bits = rounded.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as usize;
    if !(1023 + 127..2047).contains(&exponent) {
        return None;
    }
    let mut words = [0_u64; 16];
    if unsafe { sn_integer1024(value, words.as_mut_ptr()) }.abs() > 1 {
        return None;
    }
    let shift = exponent - 1023 - 52;
    let magnitude = u128::from((bits & ((1_u64 << 52) - 1)) | (1_u64 << 52)) << (shift % 64);
    let mut float_words = [0_u64; 16];
    float_words[shift / 64] = magnitude as u64;
    if shift / 64 + 1 < float_words.len() {
        float_words[shift / 64 + 1] = (magnitude >> 64) as u64;
    }
    let order = float_words.iter().rev().cmp(words.iter().rev());
    Some(if rounded.is_sign_negative() {
        order.reverse()
    } else {
        order
    })
}

impl Rules {
    // Shared by validity scans and diagnostic prechecks. Numeric traversal
    // borrows only opaque VALUEs and uses the compiled primitive shortcuts.
    pub(super) fn runtime_valid(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
    ) -> Verdict {
        caches
            .number(self.source, value, required)
            .map_or(Unsupported, |frame| frame.step(0))
    }
    pub(super) fn runtime_failures(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        mut visit: impl FnMut(&'static str) -> Result<(), Verdict>,
    ) -> Result<(), Verdict> {
        let frame = caches.number(self.source, value, required)?;
        if !frame.predicate(1)? {
            if required != 0 {
                visit("type")?;
            }
            return Ok(());
        }
        if required == TYPE_INTEGER && !frame.predicate(2)? {
            visit("type")?;
        }
        if frame.step(3) != Valid {
            return Err(Unsupported);
        }
        for (bit, keyword, step) in [
            (MAXIMUM, "maximum", 4),
            (MINIMUM, "minimum", 5),
            (EXCLUSIVE_MAXIMUM, "exclusiveMaximum", 6),
            (EXCLUSIVE_MINIMUM, "exclusiveMinimum", 7),
            (MULTIPLE_OF, "multipleOf", 8),
        ] {
            if ((bit == MULTIPLE_OF && self.multiple.is_some())
                || self.limits.iter().any(|&(candidate, _)| candidate == bit))
                && !frame.predicate(step)?
            {
                visit(keyword)?;
            }
        }
        Ok(())
    }
    pub(super) fn runtime_operands(&self) -> bool {
        self.runtime_operands
    }
    pub(super) fn eval_guarded(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        let fixnum = value.has_fixnum_tag(self.fixnum_flag);
        if fixnum {
            if required != 0 && required & TYPE_INTEGRAL_NUMBER == 0 {
                return Invalid;
            }
            if let Some(multiple) = &self.fast_multiple {
                return multiple.eval(immediate_integer(value));
            }
            if let Some(limits) = &self.fast_limits {
                return fixnum_bounds(immediate_integer(value), limits);
            }
        }
        if self.bounds_view {
            return self.eval_bounds_guarded(required, value);
        }
        let kind = if fixnum {
            TYPE_INTEGRAL_NUMBER
        } else {
            unsafe { sn_kind(value) }
        };
        if kind == TYPE_UNSUPPORTED {
            Unsupported
        } else if required != 0 && kind & required == 0 {
            Invalid
        } else if kind & TYPE_NUMBER == 0 {
            Valid
        } else {
            self.eval(caches, value, budget)
        }
    }

    pub(super) fn eval_bounds_guarded(&self, required: i32, value: Value) -> Verdict {
        if let [(bit, limit)] = self.limits.as_slice()
            && let Some(bound) = limit.wide_integer
        {
            // Both original handles are checked by the nonallocating Big/Big
            // comparator. No magnitude export is needed for a single bound.
            // Other kinds retain the scalar/type checks and Float tie rules.
            let order = unsafe { sn_big_order(value, bound) };
            if order != 3 {
                return verdict(
                    (required == 0 || required & TYPE_INTEGRAL_NUMBER != 0)
                        && match *bit {
                            MAXIMUM => order <= 0,
                            MINIMUM => order >= 0,
                            EXCLUSIVE_MAXIMUM => order < 0,
                            _ => order > 0,
                        },
                );
            }
        }
        let mut words = std::mem::MaybeUninit::<[u64; 2]>::uninit();
        let mut kind = std::mem::MaybeUninit::<i32>::uninit();
        let mut floating = std::mem::MaybeUninit::<f64>::uninit();
        let sign = unsafe {
            sn_number_bounds_view(
                value,
                words.as_mut_ptr().cast(),
                kind.as_mut_ptr(),
                floating.as_mut_ptr(),
                required,
            )
        };
        // The adapter always initializes kind, but only initializes the
        // operand selected by its kind and sign. Never read unused outputs.
        let kind = unsafe { kind.assume_init() };
        if kind == TYPE_UNSUPPORTED {
            return Unsupported;
        }
        if required != 0 && kind & required == 0 {
            return Invalid;
        }
        if kind & TYPE_NUMBER == 0 {
            return Valid;
        }
        if sign == ADAPTER_UNSUPPORTED {
            let floating = unsafe { floating.assume_init() };
            for &(bit, ref limit) in &self.limits {
                let order = match limit.float_order(floating) {
                    Ok(order) => order,
                    Err(status) => return status,
                };
                if violates(bit, order) {
                    return Invalid;
                }
            }
            return Valid;
        }
        let integer = if sign.abs() > 1 {
            None
        } else {
            integer_words_status(&unsafe { words.assume_init() }, sign).ok()
        };
        if integer.is_none()
            && let Some(signs) = self.bounded_signs
        {
            // These Integer limits all fit i128. Every larger magnitude is
            // strictly outside them; compilation already combined their bits.
            return verdict(signs[(sign > 0) as usize]);
        }
        for &(bit, ref limit) in &self.limits {
            let Some(order) = limit.integer_order(value, integer, sign) else {
                return Unsupported;
            };
            if violates(bit, Some(order)) {
                return Invalid;
            }
        }
        Valid
    }

    pub(super) fn eval(
        &self,
        caches: &runtime::Caches,
        value: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        if self.runtime_operands {
            return self
                .arbitrary_check(caches, value, budget, |_| true)
                .map_or(Unsupported, |bits| verdict(bits == 0));
        }
        if let Some(multiple) = &self.fast_multiple
            && value.has_fixnum_tag(self.fixnum_flag)
        {
            return multiple.eval(immediate_integer(value));
        }
        if let Some(limits) = &self.fast_limits
            && value.has_fixnum_tag(self.fixnum_flag)
        {
            return fixnum_bounds(immediate_integer(value), limits);
        }
        let result = self.check(value, |_| true);
        if result == Unsupported {
            self.arbitrary_check(caches, value, budget, |_| true)
                .map_or(Unsupported, |bits| verdict(bits == 0))
        } else {
            result
        }
    }

    fn failures(
        &self,
        caches: &runtime::Caches,
        value: Value,
        budget: &budget::Budget,
    ) -> Result<i32, Verdict> {
        if let Some(multiple) = &self.fast_multiple
            && value.has_fixnum_tag(self.fixnum_flag)
        {
            return Ok(multiple.failures(immediate_integer(value)));
        }
        if let Some(limits) = &self.fast_limits
            && value.has_fixnum_tag(self.fixnum_flag)
        {
            let n = immediate_integer(value);
            return Ok(limits.iter().fold(0, |bits, &(bit, limit)| {
                bits | if match bit {
                    MAXIMUM => n > limit,
                    MINIMUM => n < limit,
                    EXCLUSIVE_MAXIMUM => n >= limit,
                    _ => n <= limit,
                } {
                    bit
                } else {
                    0
                }
            }));
        }
        let mut bits = 0;
        let status = self.check(value, |bit| {
            bits |= bit;
            false
        });
        if status == Unsupported {
            self.arbitrary_check(caches, value, budget, |_| false)
        } else {
            Ok(bits)
        }
    }

    pub(super) fn visit_failures(
        &self,
        caches: &runtime::Caches,
        value: Value,
        budget: &budget::Budget,
        mut visit: impl FnMut(&'static str) -> Result<(), Verdict>,
    ) -> Result<(), Verdict> {
        const KEYWORDS: [(i32, &str); 5] = [
            (MAXIMUM, "maximum"),
            (MINIMUM, "minimum"),
            (EXCLUSIVE_MAXIMUM, "exclusiveMaximum"),
            (EXCLUSIVE_MINIMUM, "exclusiveMinimum"),
            (MULTIPLE_OF, "multipleOf"),
        ];
        if self.runtime_operands {
            let mut failure = None;
            let result = self.arbitrary_check(caches, value, budget, |bit| {
                let keyword = KEYWORDS
                    .iter()
                    .find(|&&(candidate, _)| candidate == bit)
                    .expect("compiled numeric assertion")
                    .1;
                if let Err(status) = visit(keyword) {
                    failure = Some(status);
                    true
                } else {
                    false
                }
            });
            if let Some(status) = failure {
                Err(status)
            } else {
                result.map(|_| ())
            }
        } else {
            let bits = self.failures(caches, value, budget)?;
            for (bit, keyword) in KEYWORDS {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                if bits & bit != 0 {
                    visit(keyword)?;
                }
            }
            Ok(())
        }
    }

    pub(super) fn memory_usage(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.limits.capacity() * std::mem::size_of::<(i32, Limit)>()
            + self
                .limits
                .iter()
                .map(|(_, limit)| limit.arbitrary_memory_usage())
                .sum::<usize>()
            + self
                .multiple
                .as_ref()
                .map_or(0, Limit::arbitrary_memory_usage)
            + self.fast_limits.as_ref().map_or(0, |limits| {
                limits.capacity() * std::mem::size_of::<(i32, i64)>()
            })
            + self.fast_multiple.as_ref().map_or(0, |multiple| {
                multiple.limits.capacity() * std::mem::size_of::<(i32, i64)>()
            })
    }

    fn check_wide_multiple(
        &self,
        value: Value,
        divisor: Fraction,
        sum_words: bool,
        mut failure: impl FnMut(i32) -> bool,
    ) -> Verdict {
        let mut words = [0_u64; 16];
        let sign = unsafe { sn_integer1024(value, words.as_mut_ptr()) };
        let integer = integer_words_status(&words, sign).ok();
        let mut invalid = false;
        for &(bit, ref limit) in &self.limits {
            let Some(order) = limit.integer_order(value, integer, sign) else {
                return Unsupported;
            };
            if violates(bit, Some(order)) {
                invalid = true;
                if failure(bit) {
                    return Invalid;
                }
            }
        }
        let result = if let Some(n) = integer {
            verdict(
                Fraction {
                    numerator: n,
                    denominator: 1,
                }
                .multiple_of(divisor),
            )
        } else if sign.abs() > 1 {
            unbounded_integer_multiple(value, divisor, sum_words)
        } else {
            wide_multiple_words(&words, divisor, sum_words)
        };
        match result {
            Unsupported => return Unsupported,
            Invalid => {
                invalid = true;
                failure(MULTIPLE_OF);
            }
            Valid => {}
        }
        verdict(!invalid)
    }

    fn check(&self, value: Value, mut failure: impl FnMut(i32) -> bool) -> Verdict {
        let mut invalid = false;
        let float = unsafe { sn_is_float(value) } != 0;
        if !float
            && !value.has_fixnum_tag(self.fixnum_flag)
            && let Some(limit) = &self.multiple
            && let Some(exact) = limit.exact
            && exact.numerator > 1
        {
            return self.check_wide_multiple(value, exact, limit.sum_words, failure);
        }
        let (integer, large_sign) = if float {
            (None, 0)
        } else {
            match read_known_integer_status(value, self.fixnum_flag) {
                Ok(integer) => (Some(integer), 0),
                Err(sign) => (None, sign),
            }
        };
        if !float && integer.is_none() {
            // An ordinary Integer outside i128 is beyond every representable
            // exact limit (whose denominator is positive). Bounds alone need
            // only its sign. Multiples read the full magnitude below.
            if large_sign == 0 {
                return Unsupported;
            }
            for (bit, limit) in &self.limits {
                let Some(order) = limit.integer_order(value, None, large_sign) else {
                    return Unsupported;
                };
                let violates = violates(*bit, Some(order));
                if violates {
                    invalid = true;
                    if failure(*bit) {
                        return Invalid;
                    }
                }
            }
            if let Some(limit) = &self.multiple {
                let Some(exact) = limit.exact else {
                    return Unsupported;
                };
                match wide_integer_multiple(value, exact, limit.sum_words) {
                    Unsupported => return Unsupported,
                    Invalid => {
                        invalid = true;
                        failure(MULTIPLE_OF);
                    }
                    Valid => {}
                }
            }
            return verdict(!invalid);
        }
        let decimal = if self.multiple.is_some() {
            if let Some(integer) = integer {
                Some(Fraction {
                    numerator: integer,
                    denominator: 1,
                })
            } else {
                let Some(decimal) = decimal_float(unsafe { sn_float(value) }) else {
                    return Unsupported;
                };
                Some(decimal)
            }
        } else {
            None
        };
        for (bit, limit) in &self.limits {
            let order = if integer.is_some() {
                let Some(order) = limit.integer_order(value, integer, 0) else {
                    return Unsupported;
                };
                Some(order)
            } else if let Some(decimal) = decimal {
                if let Some(exact) = limit.exact {
                    Some(decimal.compare(exact))
                } else if limit.wide_integer.is_some() {
                    // The reduced decimal numerator fits i128 and its
                    // denominator is positive. A bound outside i128 is
                    // strictly beyond it; no Float/Big comparison is needed.
                    Some(if limit.rounded.is_sign_negative() {
                        Ordering::Greater
                    } else {
                        Ordering::Less
                    })
                } else {
                    return Unsupported;
                }
            } else {
                let n = unsafe { sn_float(value) };
                if limit.integer {
                    match limit.float_order(n) {
                        Ok(order) => order,
                        Err(status) => return status,
                    }
                } else {
                    n.partial_cmp(&limit.rounded)
                }
            };
            let violates = violates(*bit, order);
            if violates {
                invalid = true;
                if failure(*bit) {
                    return Invalid;
                }
            }
        }
        if let Some(limit) = &self.multiple {
            let Some(exact) = limit.exact else {
                return Unsupported;
            };
            if !decimal.unwrap().multiple_of(exact) {
                invalid = true;
                failure(MULTIPLE_OF);
            }
        }
        verdict(!invalid)
    }
}
