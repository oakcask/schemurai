//! Byte parsers matching the built-in Ruby formats. They borrow original string
//! storage and allocate neither Ruby objects nor Rust instance representations.
use super::*;

#[derive(Debug)]
pub(super) enum Format {
    Date,
    Time,
    DateTime,
    Duration,
    Ipv4,
    Ipv6,
    Uuid,
    Pointer,
    RelativePointer,
    Unsupported,
}
impl Format {
    pub(super) fn compile(name: Value) -> Self {
        if unsafe { sn_kind(name) } != TYPE_STRING {
            return Self::Unsupported;
        }
        let bytes = unsafe { string_bytes(name) };
        match bytes {
            b"date" => Self::Date,
            b"time" => Self::Time,
            b"date-time" => Self::DateTime,
            b"duration" => Self::Duration,
            b"ipv4" => Self::Ipv4,
            b"ipv6" => Self::Ipv6,
            b"uuid" => Self::Uuid,
            b"json-pointer" => Self::Pointer,
            b"relative-json-pointer" => Self::RelativePointer,
            _ => Self::Unsupported,
        }
    }
    pub(super) fn eval(&self, value: Value) -> Verdict {
        self.eval_bytes(unsafe { string_bytes(value) })
    }
    pub(super) fn eval_bytes(&self, bytes: &[u8]) -> Verdict {
        verdict(match self {
            Self::Date => date_exact(bytes),
            Self::Time => time(bytes),
            Self::DateTime => date_time(bytes),
            Self::Duration => duration(bytes),
            Self::Ipv4 => ipv4(bytes),
            Self::Ipv6 => ipv6(bytes),
            Self::Uuid => uuid(bytes),
            Self::Pointer => pointer(bytes),
            Self::RelativePointer => relative_pointer(bytes),
            Self::Unsupported => return Unsupported,
        })
    }
    pub(super) fn eval_items(&self, required: i32, values: &[Value]) -> Verdict {
        self.visit_invalid_items(required, values, |_, _| Invalid)
    }
    pub(super) fn visit_invalid_items(
        &self,
        required: i32,
        values: &[Value],
        invalid: impl FnMut(usize, Value) -> Verdict,
    ) -> Verdict {
        // Each arm monomorphizes the scan with its parser selected once.
        macro_rules! scan {
            ($parser:ident) => {
                scan_items(required, values, invalid, |bytes| verdict($parser(bytes)))
            };
        }
        match self {
            Self::Date => scan!(date_exact),
            Self::Time => scan!(time),
            Self::DateTime => scan!(date_time),
            Self::Duration => scan!(duration),
            Self::Ipv4 => scan!(ipv4),
            Self::Ipv6 => scan!(ipv6),
            Self::Uuid => scan!(uuid),
            Self::Pointer => scan!(pointer),
            Self::RelativePointer => scan!(relative_pointer),
            Self::Unsupported => scan_items(required, values, invalid, |_| Unsupported),
        }
    }
}

fn scan_items(
    required: i32,
    values: &[Value],
    mut invalid: impl FnMut(usize, Value) -> Verdict,
    mut matches: impl FnMut(&[u8]) -> Verdict,
) -> Verdict {
    for (index, &value) in values.iter().enumerate() {
        let mut data = std::ptr::null();
        let mut len = 0;
        let kind = unsafe { sn_format_item_view(value, &mut data, &mut len) };
        let result = if kind == -TYPE_UNSUPPORTED {
            Unsupported
        } else if kind < 0 {
            verdict(required == 0)
        } else {
            matches(unsafe { byte_view(data, len) })
        };
        match result {
            Unsupported => return Unsupported,
            Invalid => {
                let status = invalid(index, value);
                if status != Valid {
                    return status;
                }
            }
            Valid => {}
        }
    }
    Valid
}

fn date_exact(bytes: &[u8]) -> bool {
    bytes.len() == 10 && date(bytes)
}
fn date_time(bytes: &[u8]) -> bool {
    bytes.len() >= 20 && date(bytes) && matches!(bytes[10], b'T' | b't') && time(&bytes[11..])
}
// Keep the SIMD body out of the shared format dispatchers. Local x64 benchmarks
// and disassembly showed that inlining it shifted the unchanged JSON Pointer
// loop into a slower instruction layout; outlining retains the UUID SIMD gain.
#[inline(never)]
fn uuid(bytes: &[u8]) -> bool {
    if bytes.len() != 36 || [8, 13, 18, 23].iter().any(|&at| bytes[at] != b'-') {
        return false;
    }
    #[cfg(any(
        all(target_arch = "x86_64", target_feature = "sse2"),
        all(
            target_arch = "aarch64",
            target_feature = "neon",
            target_endian = "little"
        )
    ))]
    {
        // The first two vectors contain all four separators. Their exact
        // positions were checked above; only those lanes may bypass hex checks.
        hex_block(&bytes[..16], (1 << 8) | (1 << 13))
            && hex_block(&bytes[16..32], (1 << 2) | (1 << 7))
            && bytes[32..].iter().all(u8::is_ascii_hexdigit)
    }
    #[cfg(not(any(
        all(target_arch = "x86_64", target_feature = "sse2"),
        all(
            target_arch = "aarch64",
            target_feature = "neon",
            target_endian = "little"
        )
    )))]
    bytes
        .iter()
        .enumerate()
        .all(|(index, byte)| matches!(index, 8 | 13 | 18 | 23) || byte.is_ascii_hexdigit())
}

#[cfg(all(target_arch = "x86_64", target_feature = "sse2"))]
fn hex_block(bytes: &[u8], separators: u16) -> bool {
    use core::arch::x86_64::{
        _mm_cmpeq_epi8, _mm_loadu_si128, _mm_movemask_epi8, _mm_or_si128, _mm_set1_epi8,
        _mm_setzero_si128, _mm_sub_epi8, _mm_subs_epu8,
    };
    // The caller supplies sixteen readable bytes. SSE2 is a target baseline;
    // unsigned wrapping subtraction rejects bytes below the ASCII ranges too.
    let valid = unsafe {
        let word = _mm_loadu_si128(bytes.as_ptr().cast());
        let digits = _mm_sub_epi8(word, _mm_set1_epi8(b'0' as i8));
        let letters = _mm_sub_epi8(
            _mm_or_si128(word, _mm_set1_epi8(32)),
            _mm_set1_epi8(b'a' as i8),
        );
        let digits = _mm_cmpeq_epi8(_mm_subs_epu8(digits, _mm_set1_epi8(9)), _mm_setzero_si128());
        let letters = _mm_cmpeq_epi8(
            _mm_subs_epu8(letters, _mm_set1_epi8(5)),
            _mm_setzero_si128(),
        );
        _mm_movemask_epi8(_mm_or_si128(digits, letters)) as u16
    };
    valid | separators == u16::MAX
}

#[cfg(all(
    target_arch = "aarch64",
    target_feature = "neon",
    target_endian = "little"
))]
fn hex_block(bytes: &[u8], separators: u16) -> bool {
    use core::arch::aarch64::{
        vcleq_u8, vdupq_n_u8, vget_lane_u64, vld1q_u8, vorrq_u8, vreinterpret_u64_u8,
        vreinterpretq_u16_u8, vshrn_n_u16, vsubq_u8,
    };
    // Each load remains within the sixteen-byte block. Narrowing packs two
    // four-bit flags per byte in little-endian lane order.
    let valid = unsafe {
        let word = vld1q_u8(bytes.as_ptr());
        let digits = vcleq_u8(vsubq_u8(word, vdupq_n_u8(b'0')), vdupq_n_u8(9));
        let letters = vcleq_u8(
            vsubq_u8(vorrq_u8(word, vdupq_n_u8(32)), vdupq_n_u8(b'a')),
            vdupq_n_u8(5),
        );
        let flags = vorrq_u8(digits, letters);
        let packed = vshrn_n_u16::<4>(vreinterpretq_u16_u8(flags));
        vget_lane_u64::<0>(vreinterpret_u64_u8(packed))
    };
    let mut ignored = 0_u64;
    for lane in 0..16 {
        if separators & (1 << lane) != 0 {
            ignored |= 0xf << (lane * 4);
        }
    }
    valid | ignored == u64::MAX
}

fn relative_pointer(bytes: &[u8]) -> bool {
    let Some(end) = digits_end(bytes, 0) else {
        return false;
    };
    if bytes[0] == b'0' && end > 1 {
        return false;
    }
    end == bytes.len() || (bytes[end] == b'#' && end + 1 == bytes.len()) || pointer(&bytes[end..])
}

fn two(bytes: &[u8], index: usize) -> Option<u32> {
    let tens = bytes.get(index)?.checked_sub(b'0')?;
    let ones = bytes.get(index + 1)?.checked_sub(b'0')?;
    (tens <= 9 && ones <= 9).then_some(u32::from(tens) * 10 + u32::from(ones))
}
fn date(bytes: &[u8]) -> bool {
    if bytes.get(4) != Some(&b'-') || bytes.get(7) != Some(&b'-') {
        return false;
    }
    let (Some(century), Some(year), Some(month), Some(day)) =
        (two(bytes, 0), two(bytes, 2), two(bytes, 5), two(bytes, 8))
    else {
        return false;
    };
    let year = century * 100 + year;
    let last = match month {
        2 => {
            if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    (1..=last).contains(&day)
}
fn time(bytes: &[u8]) -> bool {
    if bytes.len() < 9 || bytes[2] != b':' || bytes[5] != b':' {
        return false;
    }
    let (Some(hour), Some(minute), Some(second)) = (two(bytes, 0), two(bytes, 3), two(bytes, 6))
    else {
        return false;
    };
    if hour > 23 || minute > 59 || second > 60 {
        return false;
    }
    let mut at = 8;
    if bytes[at] == b'.' {
        let Some(end) = digits_end(bytes, at + 1) else {
            return false;
        };
        at = end;
    }
    let offset = match bytes.get(at) {
        Some(b'Z' | b'z') if at + 1 == bytes.len() => 0,
        Some(b'+' | b'-') if at + 6 == bytes.len() && bytes[at + 3] == b':' => {
            let (Some(hour), Some(minute)) = (two(bytes, at + 1), two(bytes, at + 4)) else {
                return false;
            };
            if hour > 23 || minute > 59 {
                return false;
            }
            let offset = (hour * 60 + minute) as i32;
            if bytes[at] == b'-' { -offset } else { offset }
        }
        _ => return false,
    };
    second != 60 || ((hour * 60 + minute) as i32 - offset).rem_euclid(1440) == 1439
}

fn digits_end(bytes: &[u8], start: usize) -> Option<usize> {
    let mut at = start;
    while bytes.get(at).is_some_and(u8::is_ascii_digit) {
        at += 1;
    }
    (at > start).then_some(at)
}
fn units(bytes: &[u8], start: usize, units: &[u8]) -> Option<usize> {
    let end = digits_end(bytes, start)?;
    let first = units.iter().position(|unit| Some(unit) == bytes.get(end))?;
    let mut at = end + 1;
    for unit in &units[first + 1..] {
        let Some(end) = digits_end(bytes, at) else {
            break;
        };
        if bytes.get(end) != Some(unit) {
            return None;
        }
        at = end + 1;
    }
    Some(at)
}
fn duration(bytes: &[u8]) -> bool {
    if bytes.first() != Some(&b'P') || bytes.len() <= 1 {
        return false;
    }
    if bytes[1] == b'T' {
        return units(bytes, 2, b"HMS") == Some(bytes.len());
    }
    let Some(end) = digits_end(bytes, 1) else {
        return false;
    };
    if bytes.get(end) == Some(&b'W') {
        return end + 1 == bytes.len();
    }
    let Some(at) = units(bytes, 1, b"YMD") else {
        return false;
    };
    at == bytes.len()
        || (bytes.get(at) == Some(&b'T') && units(bytes, at + 1, b"HMS") == Some(bytes.len()))
}
fn pointer(bytes: &[u8]) -> bool {
    if bytes.is_empty() {
        return true;
    }
    if bytes[0] != b'/' {
        return false;
    }
    // The scalar scan avoids search dispatch overhead on short pointers.
    if bytes.len() <= 32 {
        let mut at = 1;
        while at < bytes.len() {
            if bytes[at] == b'~' {
                at += 1;
                if !matches!(bytes.get(at), Some(b'0' | b'1')) {
                    return false;
                }
            }
            at += 1;
        }
        return true;
    }
    // Only tilde escapes need inspection. Search the original byte slice;
    // neither tokens nor decoded pointer strings are materialized.
    memchr::memchr_iter(b'~', &bytes[1..]).all(|at| matches!(bytes.get(at + 2), Some(b'0' | b'1')))
}
fn ipv4(bytes: &[u8]) -> bool {
    if bytes.len() > 15 {
        return false;
    }
    let mut at = 0;
    for octet in 0..4 {
        let Some(end) = digits_end(bytes, at) else {
            return false;
        };
        let count = end - at;
        if count > 3 || (count > 1 && bytes[at] == b'0') {
            return false;
        }
        let number = bytes[at..end]
            .iter()
            .fold(0_u32, |n, b| n * 10 + u32::from(b - b'0'));
        if number > 255 {
            return false;
        }
        if octet == 3 {
            return end == bytes.len();
        }
        if bytes.get(end) != Some(&b'.') {
            return false;
        }
        at = end + 1;
    }
    unreachable!()
}
fn ipv6(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > 45 {
        return false;
    }
    let mut at = 0;
    let mut groups = 0;
    let mut compressed = false;
    if bytes[0] == b':' {
        if bytes.get(1) != Some(&b':') {
            return false;
        }
        at = 2;
        compressed = true;
        if at == bytes.len() {
            return true;
        }
    }
    while at < bytes.len() {
        let start = at;
        while bytes.get(at).is_some_and(u8::is_ascii_hexdigit) {
            at += 1;
        }
        if at == start || at - start > 4 {
            return false;
        }
        if bytes.get(at) == Some(&b'.') {
            if groups > 6 || !ipv4(&bytes[start..]) {
                return false;
            }
            groups += 2;
            break;
        }
        groups += 1;
        if groups > 8 {
            return false;
        }
        if at == bytes.len() {
            break;
        }
        if bytes[at] != b':' {
            return false;
        }
        at += 1;
        if bytes.get(at) == Some(&b':') {
            if compressed {
                return false;
            }
            compressed = true;
            at += 1;
            if at == bytes.len() {
                break;
            }
        } else if at == bytes.len() {
            return false;
        }
    }
    if compressed { groups < 8 } else { groups == 8 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_checks_every_byte_and_separator_without_accepting_non_ascii() {
        let original = *b"123e4567-e89b-12d3-a456-426614174000";
        for at in 0..36 {
            for byte in 0..=255 {
                let mut input = original;
                input[at] = byte;
                let expected = if matches!(at, 8 | 13 | 18 | 23) {
                    byte == b'-'
                } else {
                    byte.is_ascii_hexdigit()
                };
                assert_eq!(uuid(&input), expected, "position {at}, byte {byte}");
            }
        }
        assert!(!uuid(&original[..35]));
        let mut longer = original.to_vec();
        longer.push(b'0');
        assert!(!uuid(&longer));
    }
}
