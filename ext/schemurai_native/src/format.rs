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
fn uuid(bytes: &[u8]) -> bool {
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
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
