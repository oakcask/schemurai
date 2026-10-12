//! Validate complete blocks of borrowed, header-verified immediate integers.
//! Stop before any uncertain block so the ordinary evaluator retains ordering.
use super::Value;

pub(super) fn valid_prefix(values: &[Value], min: i64, max: i64, fixnum_flag: Value) -> usize {
    if fixnum_flag != 1 || values.len() < 16 {
        return 0;
    }
    // Comparing tagged values preserves signed integer order. Clamp the
    // interval before tagging, since some schema limits exceed Fixnum range.
    let min = min.max(-(1_i64 << 62));
    let max = max.min((1_i64 << 62) - 1);
    if min > max {
        return 0;
    }
    let min = (min << 1) | 1;
    let max = (max << 1) | 1;
    #[cfg(target_arch = "x86_64")]
    if std::is_x86_feature_detected!("avx2") {
        // Detection includes OS support. The kernel only loads full blocks.
        return unsafe { avx2_prefix(values, min, max) };
    }
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    return neon_prefix(values, min, max);
    #[allow(unreachable_code)]
    {
        let _ = (min, max);
        0
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn avx2_prefix(values: &[Value], min: i64, max: i64) -> usize {
    use core::arch::x86_64::{
        _mm256_and_si256, _mm256_andnot_si256, _mm256_cmpeq_epi64, _mm256_cmpgt_epi64,
        _mm256_loadu_si256, _mm256_movemask_epi8, _mm256_or_si256, _mm256_set1_epi64x,
    };
    let lower = _mm256_set1_epi64x(min);
    let upper = _mm256_set1_epi64x(max);
    let tag = _mm256_set1_epi64x(1);
    let mut consumed = 0;
    for block in values.as_chunks::<4>().0 {
        // Four VALUE words provide all 32 readable bytes. No Ruby object is
        // dereferenced; the header-validated low bit identifies each Fixnum.
        let valid = unsafe {
            let word = _mm256_loadu_si256(block.as_ptr().cast());
            let tagged = _mm256_cmpeq_epi64(_mm256_and_si256(word, tag), tag);
            let outside = _mm256_or_si256(
                _mm256_cmpgt_epi64(lower, word),
                _mm256_cmpgt_epi64(word, upper),
            );
            _mm256_movemask_epi8(_mm256_andnot_si256(outside, tagged)) == -1
        };
        if !valid {
            break;
        }
        consumed += 4;
    }
    consumed
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
fn neon_prefix(values: &[Value], min: i64, max: i64) -> usize {
    use core::arch::aarch64::{
        vandq_u64, vceqq_u64, vcgeq_s64, vcleq_s64, vdupq_n_s64, vdupq_n_u64, vgetq_lane_u64,
        vld1q_u64, vreinterpretq_s64_u64,
    };
    let lower = vdupq_n_s64(min);
    let upper = vdupq_n_s64(max);
    let tag = vdupq_n_u64(1);
    let mut consumed = 0;
    for block in values.as_chunks::<2>().0 {
        // Baseline NEON; the unaligned load stays within two borrowed VALUEs.
        let valid = unsafe {
            let word = vld1q_u64(block.as_ptr().cast());
            let tagged = vceqq_u64(vandq_u64(word, tag), tag);
            let signed = vreinterpretq_s64_u64(word);
            let bounds = vandq_u64(vcgeq_s64(signed, lower), vcleq_s64(signed, upper));
            let valid = vandq_u64(tagged, bounds);
            vgetq_lane_u64::<0>(valid) & vgetq_lane_u64::<1>(valid) == u64::MAX
        };
        if !valid {
            break;
        }
        consumed += 2;
    }
    consumed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(value: i64) -> Value {
        ((value << 1) | 1) as Value
    }

    #[test]
    fn skips_only_valid_fixnums_before_the_first_uncertain_block() {
        for len in 0..65 {
            let original: Vec<_> = (0..len).map(|at| tag((at % 33) as i64 - 16)).collect();
            for at in 0..len {
                for value in [0, 2, tag(-17), tag(17), tag(-(1 << 62)), tag((1 << 62) - 1)] {
                    let mut values = original.clone();
                    values[at] = value;
                    let prefix = valid_prefix(&values, -16, 16, 1);
                    assert!(prefix <= at, "length {len}, position {at}, prefix {prefix}");
                    assert_eq!(&values[..prefix], &original[..prefix]);
                }
            }
        }
    }

    #[test]
    fn clamps_schema_limits_without_overflow_and_obeys_disabled_hints() {
        let values = [tag(-(1 << 62)), tag((1 << 62) - 1)].repeat(32);
        let prefix = valid_prefix(&values, i64::MIN, i64::MAX, 1);
        #[cfg(target_arch = "x86_64")]
        if std::is_x86_feature_detected!("avx2") {
            assert_eq!(prefix, values.len());
        }
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        assert_eq!(prefix, values.len());
        assert!(prefix <= values.len());
        assert_eq!(valid_prefix(&values, i64::MIN, i64::MAX, 0), 0);
        assert_eq!(valid_prefix(&values, 1 << 62, i64::MAX, 1), 0);
        assert_eq!(valid_prefix(&values, i64::MIN, -(1 << 62) - 1, 1), 0);
        assert_eq!(valid_prefix(&values, 1, 0, 1), 0);
        assert_eq!(valid_prefix(&values, -(1 << 62) + 1, i64::MAX, 1), 0);
        assert_eq!(valid_prefix(&values, i64::MIN, (1 << 62) - 2, 1), 0);
    }
}
