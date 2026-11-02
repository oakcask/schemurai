//! Content validation borrows Ruby string storage. Base64 decoding uses bounded
//! scratch; native JSON scanning never constructs a tree. Other source
//! encodings request Ruby parsing after Rust evaluation returns.
use super::*;
use std::mem::MaybeUninit;

const STACK_BYTES: usize = 256;
// Full refills must end on a three-byte Base64 group boundary.
const STREAM_BYTES: usize = 8190;
const DIRECT_BYTES: usize = 8192;

// Runner-local derived content storage. The decoder overwrites the requested
// prefix before parsing; previous decoded bytes are never used as input.
#[derive(Default)]
pub(super) struct Scratch(std::cell::RefCell<Vec<u8>>);
impl Scratch {
    fn decode(&self, bytes: &[u8], length: usize) -> Verdict {
        let mut scratch = self.0.borrow_mut();
        if scratch.is_empty() {
            scratch.resize(DIRECT_BYTES + 2, 0);
        }
        if length <= DIRECT_BYTES {
            decode_json_turbo(bytes, length, &mut scratch)
        } else {
            let mut input = BufferedBase64 {
                bytes,
                decoded: &mut scratch,
                at: 0,
                len: 0,
                remaining: length,
                valid: true,
            };
            input.fill();
            json(input)
        }
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.0.try_borrow().map_or(0, |scratch| scratch.capacity())
    }
}

#[cfg(test)]
mod scratch_tests {
    use super::*;

    #[test]
    fn reused_decoding_ignores_old_bytes_and_reports_bounded_memory() {
        let caches = runtime::Caches::default();
        let before = unsafe { runtime::sn_caches_size(&caches) };
        assert_eq!(caches.content.memory_usage(), 0);
        for length in [8192, 385, 32768, 4096, 386, 8191, 387] {
            let json = format!("\"{}\"", "x".repeat(length - 2));
            let encoded = base64_simd::STANDARD.encode_to_string(&json);
            assert_eq!(caches.content.decode(encoded.as_bytes(), length), Valid);
            let mut malformed = encoded.into_bytes();
            malformed[0] = b'!';
            assert_eq!(caches.content.decode(&malformed, length), Invalid);
            let bad_json = base64_simd::STANDARD.encode_to_string("x".repeat(length));
            assert_eq!(caches.content.decode(bad_json.as_bytes(), length), Invalid);
            assert_eq!(caches.content.memory_usage(), DIRECT_BYTES + 2);
        }
        assert_eq!(
            unsafe { runtime::sn_caches_size(&caches) } - before,
            DIRECT_BYTES + 2
        );
    }
}

#[derive(Debug)]
pub(super) struct Content {
    pub(super) base64: bool,
    pub(super) json: bool,
}
impl Content {
    pub(super) fn visit_invalid_items(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
        required: i32,
        values: &[Value],
        invalid: impl FnMut(usize, Value) -> Verdict,
    ) -> Verdict {
        match (self.base64, self.json) {
            (true, true) => {
                Self::visit_items_impl::<true, true>(vm, caches, required, values, invalid)
            }
            (true, false) => {
                Self::visit_items_impl::<true, false>(vm, caches, required, values, invalid)
            }
            (false, true) => {
                Self::visit_items_impl::<false, true>(vm, caches, required, values, invalid)
            }
            (false, false) => {
                Self::visit_items_impl::<false, false>(vm, caches, required, values, invalid)
            }
        }
    }
    fn visit_items_impl<const BASE64: bool, const JSON: bool>(
        vm: &Ruby,
        caches: &runtime::Caches,
        required: i32,
        values: &[Value],
        mut invalid: impl FnMut(usize, Value) -> Verdict,
    ) -> Verdict {
        for (index, &value) in values.iter().enumerate() {
            let mut data = MaybeUninit::uninit();
            let mut len = MaybeUninit::uninit();
            // Plain JSON combines its String guard, byte loan and encoding
            // check. Base64 remains independent of the source encoding.
            let kind = if JSON && !BASE64 {
                unsafe { sn_json_item_view(value, data.as_mut_ptr(), len.as_mut_ptr()) }
            } else {
                unsafe { sn_format_item_view(value, data.as_mut_ptr(), len.as_mut_ptr()) }
            };
            if kind == -TYPE_UNSUPPORTED {
                let status = invalid(index, value);
                if status != Valid {
                    return status;
                }
                continue;
            }
            let result = if JSON && !BASE64 && kind == ENCODING_OTHER {
                caches.json(value)
            } else if kind < 0 {
                verdict(required == 0)
            } else {
                // Only the successful String view initializes these outputs.
                let bytes = unsafe { vm.bytes(data.assume_init(), len.assume_init()) };
                if JSON && !BASE64 {
                    if kind == ENCODING_ASCII && !bytes.is_ascii() {
                        caches.json(value)
                    } else {
                        json(bytes)
                    }
                } else {
                    Self::eval_impl::<true, BASE64, JSON>(vm, caches, value, bytes, 0)
                }
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
    pub(super) fn eval(&self, vm: &Ruby, caches: &runtime::Caches, value: Value) -> Verdict {
        self.eval_selected::<false>(vm, caches, value, &[], 0)
    }
    pub(super) fn eval_borrowed(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
        value: Value,
        bytes: &[u8],
        encoding: i32,
    ) -> Verdict {
        self.eval_selected::<true>(vm, caches, value, bytes, encoding)
    }
    fn eval_selected<const BORROWED: bool>(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
        value: Value,
        bytes: &[u8],
        encoding: i32,
    ) -> Verdict {
        match (self.base64, self.json) {
            (true, true) => {
                Self::eval_impl::<BORROWED, true, true>(vm, caches, value, bytes, encoding)
            }
            (true, false) => {
                Self::eval_impl::<BORROWED, true, false>(vm, caches, value, bytes, encoding)
            }
            (false, true) => {
                Self::eval_impl::<BORROWED, false, true>(vm, caches, value, bytes, encoding)
            }
            (false, false) => {
                Self::eval_impl::<BORROWED, false, false>(vm, caches, value, bytes, encoding)
            }
        }
    }
    fn eval_impl<const BORROWED: bool, const BASE64: bool, const JSON: bool>(
        vm: &Ruby,
        caches: &runtime::Caches,
        value: Value,
        bytes: &[u8],
        encoding: i32,
    ) -> Verdict {
        let bytes = if BORROWED {
            bytes
        } else {
            unsafe { vm.string(value) }
        };
        if BASE64 {
            if !JSON {
                return verdict(base64_simd::STANDARD.check(bytes).is_ok());
            }
            let Ok(length) = base64_simd::STANDARD.decoded_length(bytes) else {
                return Invalid;
            };
            // This scratch is a derived content operand, not a conversion of
            // Ruby values. Short content avoids interleaving decoding with
            // every parser advance; longer content keeps bounded streaming.
            if length < 128 {
                let mut scratch = [MaybeUninit::<u8>::uninit(); STACK_BYTES];
                // Only the crate's successful, initialized output slice is
                // passed to the parser. Failed/short output is never read.
                match base64_simd::STANDARD.decode(
                    bytes,
                    base64_simd::Out::from_uninit_slice(&mut scratch[..length]),
                ) {
                    Ok(decoded) if decoded.len() == length => return json(&*decoded),
                    _ => return Invalid,
                }
            }
            if length <= STACK_BYTES {
                return decode_json_medium(bytes, length);
            }
            caches.content.decode(bytes, length)
        } else {
            if JSON {
                let encoding = match (BORROWED, encoding) {
                    (true, ENCODING_UTF8 | ENCODING_SEVEN_BIT) => ENCODING_UTF8,
                    (true, ENCODING_ASCII) => ENCODING_ASCII,
                    _ => unsafe { sn_json_encoding(value) },
                };
                if encoding == ENCODING_OTHER || (encoding == ENCODING_ASCII && !bytes.is_ascii()) {
                    return caches.json(value);
                }
            }
            if !JSON {
                return Valid;
            }
            json(bytes)
        }
    }
}

// Keep the larger frame out of the short-content path. This bounded decoded
// operand avoids repeated decoder setup without exporting an instance tree.
#[inline(never)]
fn decode_json_medium(bytes: &[u8], length: usize) -> Verdict {
    let mut scratch = [0; STACK_BYTES + 2];
    decode_json_turbo(bytes, length, &mut scratch)
}

#[cfg(target_arch = "aarch64")]
fn decode_json_turbo(bytes: &[u8], length: usize, scratch: &mut [u8]) -> Verdict {
    let capacity = base64_turbo::STANDARD.decoded_len_estimate(bytes.len());
    if decode_groups(bytes, &mut scratch[..capacity], length) {
        json(&scratch[..length])
    } else {
        Invalid
    }
}

#[cfg(not(target_arch = "aarch64"))]
fn decode_json_turbo(bytes: &[u8], length: usize, scratch: &mut [u8]) -> Verdict {
    // The slice API requires an initialized upper-bound buffer, including
    // up to two padding bytes beyond the exact decoded length. Only the
    // successful written prefix is parsed. This is a derived content operand.
    let capacity = base64_turbo::STANDARD.decoded_len_estimate(bytes.len());
    match base64_turbo::STANDARD.decode_slice(bytes, &mut scratch[..capacity]) {
        Ok(decoded) if decoded == length => json(&scratch[..decoded]),
        _ => Invalid,
    }
}

// Decode borrowed bytes into the caller's bounded scratch. The STANDARD
// variant also checks each chunk's alphabet, padding and unused trailing bits.
#[cfg(target_arch = "aarch64")]
fn decode_groups(bytes: &[u8], output: &mut [u8], expected: usize) -> bool {
    use base64_simd::AsOut;
    matches!(base64_simd::STANDARD.decode(bytes, output.as_out()), Ok(decoded) if decoded.len() == expected)
}

#[cfg(not(target_arch = "aarch64"))]
fn decode_groups(bytes: &[u8], output: &mut [u8], expected: usize) -> bool {
    matches!(
        base64_turbo::STANDARD.decode_slice(bytes, output),
        Ok(decoded) if decoded == expected
    )
}
trait Input {
    fn byte(&self, at: usize) -> Option<u8>;
    fn advance(&mut self) {}
    fn string_run(&mut self, at: usize) -> usize;
    fn valid(&self) -> bool {
        true
    }
}
impl Input for &[u8] {
    // Retain byte/take/whitespace specialization together: removing their
    // hints changed parser register/state handling and slowed numeric/literal
    // and nested JSON controls. See benchmark/README.md's inline audit.
    #[inline(always)]
    fn byte(&self, at: usize) -> Option<u8> {
        self.get(at).copied()
    }
    fn string_run(&mut self, at: usize) -> usize {
        let mut consumed = 0;
        let remaining = &self[at..];
        #[cfg(any(
            all(target_arch = "x86_64", target_feature = "sse2"),
            all(
                target_arch = "aarch64",
                target_feature = "neon",
                target_endian = "little"
            )
        ))]
        if remaining.len() >= 24 {
            // Most object keys end within the first word. Preserve that
            // inexpensive path before preparing the vector scanner.
            let special = string_special_word(remaining[..8].try_into().unwrap());
            if special != 0 {
                return special.trailing_zeros() as usize / 8;
            }
            consumed = 8;
            #[cfg(all(
                target_arch = "aarch64",
                target_feature = "neon",
                target_endian = "little"
            ))]
            for bytes in remaining[consumed..].as_chunks::<16>().0 {
                use core::arch::aarch64::{
                    vceqq_u8, vcltq_u8, vdupq_n_u8, vget_lane_u64, vld1q_u8, vorrq_u8,
                    vreinterpret_u64_u8, vreinterpretq_u16_u8, vshrn_n_u16,
                };
                // NEON is enabled for this target. Each unaligned load stays
                // within a complete chunk. Comparisons produce 0xff per special
                // byte; narrowing packs each pair into two four-bit flags.
                // Little-endian lane order puts the first byte in the low bits.
                let special = unsafe {
                    let word = vld1q_u8(bytes.as_ptr());
                    let control = vcltq_u8(word, vdupq_n_u8(32));
                    let quote = vceqq_u8(word, vdupq_n_u8(b'"'));
                    let escape = vceqq_u8(word, vdupq_n_u8(b'\\'));
                    let flags = vorrq_u8(control, vorrq_u8(quote, escape));
                    let packed = vshrn_n_u16::<4>(vreinterpretq_u16_u8(flags));
                    vget_lane_u64::<0>(vreinterpret_u64_u8(packed))
                };
                if special != 0 {
                    return consumed + special.trailing_zeros() as usize / 4;
                }
                consumed += 16;
            }
            #[cfg(all(target_arch = "x86_64", target_feature = "sse2"))]
            if remaining.len() >= 40 && std::is_x86_feature_detected!("avx2") {
                // Runtime detection includes OS support for the vector state.
                let (length, stopped) = unsafe { string_run_avx2(&remaining[8..]) };
                consumed += length;
                if stopped {
                    return consumed;
                }
            }
            #[cfg(all(target_arch = "x86_64", target_feature = "sse2"))]
            for bytes in remaining[consumed..].as_chunks::<16>().0 {
                use core::arch::x86_64::{
                    _mm_and_si128, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_movemask_epi8,
                    _mm_or_si128, _mm_set1_epi8, _mm_setzero_si128,
                };
                // The target guarantees SSE2. Each complete chunk provides all
                // sixteen readable bytes, with no alignment requirement. Masking
                // the high three bits detects exactly the unsigned range 0..32.
                let special = unsafe {
                    let word = _mm_loadu_si128(bytes.as_ptr().cast());
                    let control = _mm_cmpeq_epi8(
                        _mm_and_si128(word, _mm_set1_epi8(-32)),
                        _mm_setzero_si128(),
                    );
                    let quote = _mm_cmpeq_epi8(word, _mm_set1_epi8(b'"' as i8));
                    let escape = _mm_cmpeq_epi8(word, _mm_set1_epi8(b'\\' as i8));
                    _mm_movemask_epi8(_mm_or_si128(control, _mm_or_si128(quote, escape))) as u32
                };
                if special != 0 {
                    return consumed + special.trailing_zeros() as usize;
                }
                consumed += 16;
            }
        }
        for bytes in remaining[consumed..].as_chunks::<8>().0 {
            let special = string_special_word(*bytes);
            if special != 0 {
                return consumed + special.trailing_zeros() as usize / 8;
            }
            consumed += 8;
        }
        consumed
            + self[at + consumed..]
                .iter()
                .take_while(|&&byte| byte >= 32 && byte != b'"' && byte != b'\\')
                .count()
    }
}
fn string_special_word(bytes: [u8; 8]) -> u64 {
    let word = u64::from_le_bytes(bytes);
    let quote = word ^ 0x2222_2222_2222_2222;
    let escape = word ^ 0x5c5c_5c5c_5c5c_5c5c;
    // Borrow may flag later bytes too, but the first flagged byte is the
    // first control, quote or escape in little-endian order.
    ((word.wrapping_sub(0x2020_2020_2020_2020) & !word)
        | (quote.wrapping_sub(0x0101_0101_0101_0101) & !quote)
        | (escape.wrapping_sub(0x0101_0101_0101_0101) & !escape))
        & 0x8080_8080_8080_8080
}
#[cfg(all(target_arch = "x86_64", target_feature = "sse2"))]
#[target_feature(enable = "avx2")]
unsafe fn string_run_avx2(bytes: &[u8]) -> (usize, bool) {
    use core::arch::x86_64::{
        _mm256_and_si256, _mm256_cmpeq_epi8, _mm256_loadu_si256, _mm256_movemask_epi8,
        _mm256_or_si256, _mm256_set1_epi8, _mm256_setzero_si256,
    };
    let mut consumed = 0;
    for bytes in bytes.as_chunks::<32>().0 {
        // The caller detected AVX2; every load stays within this complete,
        // initialized chunk. Vector lanes identify unsigned control bytes.
        let special = unsafe {
            let word = _mm256_loadu_si256(bytes.as_ptr().cast());
            let control = _mm256_cmpeq_epi8(
                _mm256_and_si256(word, _mm256_set1_epi8(-32)),
                _mm256_setzero_si256(),
            );
            let quote = _mm256_cmpeq_epi8(word, _mm256_set1_epi8(b'"' as i8));
            let escape = _mm256_cmpeq_epi8(word, _mm256_set1_epi8(b'\\' as i8));
            _mm256_movemask_epi8(_mm256_or_si256(control, _mm256_or_si256(quote, escape))) as u32
        };
        if special != 0 {
            return (consumed + special.trailing_zeros() as usize, true);
        }
        consumed += 32;
    }
    (consumed, false)
}
struct BufferedBase64<'a> {
    bytes: &'a [u8],
    decoded: &'a mut [u8],
    at: usize,
    len: usize,
    remaining: usize,
    valid: bool,
}
impl BufferedBase64<'_> {
    fn fill(&mut self) {
        self.at = 0;
        self.len = self.remaining.min(STREAM_BYTES);
        if self.len == 0 || !self.valid {
            self.len = 0;
            return;
        }
        let encoded = self.len.div_ceil(3) * 4;
        let capacity = base64_turbo::STANDARD.decoded_len_estimate(encoded);
        self.valid = decode_groups(
            &self.bytes[..encoded],
            &mut self.decoded[..capacity],
            self.len,
        );
        self.bytes = &self.bytes[encoded..];
        self.remaining -= self.len;
        if !self.valid {
            self.len = 0;
        }
    }
}
impl Input for BufferedBase64<'_> {
    fn byte(&self, _at: usize) -> Option<u8> {
        self.decoded[..self.len].get(self.at).copied()
    }
    fn advance(&mut self) {
        self.at += 1;
        if self.at == self.len {
            self.fill();
        }
    }
    fn string_run(&mut self, _at: usize) -> usize {
        let consumed = (&self.decoded[..self.len]).string_run(self.at);
        self.at += consumed;
        if self.at == self.len {
            self.fill();
        }
        consumed
    }
    fn valid(&self) -> bool {
        self.valid
    }
}
fn json<I: Input>(input: I) -> Verdict {
    let mut parser = Parser { input, at: 0 };
    let valid = parser.value(0);
    parser.whitespace();
    verdict(valid && parser.peek().is_none() && parser.input.valid())
}
struct Parser<I> {
    input: I,
    at: usize,
}
impl<I: Input> Parser<I> {
    fn peek(&self) -> Option<u8> {
        self.input.byte(self.at)
    }
    fn advance(&mut self) {
        self.at += 1;
        self.input.advance();
    }
    // Part of the measured byte/take/whitespace specialization above.
    #[inline(always)]
    fn take(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.advance();
            true
        } else {
            false
        }
    }
    // Keep whitespace state visible to value/container dispatch (inline audit).
    #[inline(always)]
    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.advance();
        }
    }
    // Paired JSON controls improved 5–6% with dispatch in the callers; see
    // benchmark/README.md, "Full audit after JSON value dispatch inlining".
    #[inline(always)]
    fn value(&mut self, depth: usize) -> bool {
        self.whitespace();
        match self.peek() {
            Some(b'[') => self.container::<false>(depth),
            Some(b'{') => self.container::<true>(depth),
            Some(b'"') => self.string(),
            Some(b't') => self.literal(b"true"),
            Some(b'f') => self.literal(b"false"),
            Some(b'n') => self.literal(b"null"),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => false,
        }
    }
    fn literal(&mut self, bytes: &[u8]) -> bool {
        bytes.iter().all(|&byte| self.take(byte))
    }
    fn container<const OBJECT: bool>(&mut self, depth: usize) -> bool {
        if depth >= 100 {
            return false;
        }
        self.advance();
        let close = if OBJECT { b'}' } else { b']' };
        self.whitespace();
        if self.take(close) {
            return true;
        }
        loop {
            if OBJECT {
                if !self.string() {
                    return false;
                }
                self.whitespace();
                if !self.take(b':') {
                    return false;
                }
            }
            if !self.value(depth + 1) {
                return false;
            }
            self.whitespace();
            if self.take(close) {
                return true;
            }
            if !self.take(b',') {
                return false;
            }
            self.whitespace();
        }
    }
    fn string(&mut self) -> bool {
        if !self.take(b'"') {
            return false;
        }
        loop {
            self.at += self.input.string_run(self.at);
            match self.peek() {
                None | Some(0..=31) => return false,
                Some(b'"') => {
                    self.advance();
                    return true;
                }
                Some(b'\\') => {
                    self.advance();
                    match self.peek() {
                        Some(b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't') => {
                            self.advance()
                        }
                        Some(b'u') => {
                            self.advance();
                            let Some(code) = self.hex4() else {
                                return false;
                            };
                            if (0xD800..=0xDBFF).contains(&code) {
                                if !self.literal(b"\\u") {
                                    return false;
                                }
                                let Some(low) = self.hex4() else {
                                    return false;
                                };
                                if !(0xDC00..=0xDFFF).contains(&low) {
                                    return false;
                                }
                            }
                        }
                        _ => return false,
                    }
                }
                Some(_) => self.advance(),
            }
        }
    }
    fn hex4(&mut self) -> Option<u32> {
        let mut value = 0;
        for _ in 0..4 {
            let digit = match self.peek()? {
                b'0'..=b'9' => self.peek()? - b'0',
                b'a'..=b'f' => self.peek()? - b'a' + 10,
                b'A'..=b'F' => self.peek()? - b'A' + 10,
                _ => return None,
            };
            value = value * 16 + u32::from(digit);
            self.advance();
        }
        Some(value)
    }
    fn digits(&mut self) -> bool {
        if !self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            return false;
        }
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.advance();
        }
        true
    }
    fn number(&mut self) -> bool {
        self.take(b'-');
        if !self.take(b'0') && !self.digits() {
            return false;
        }
        if self.take(b'.') && !self.digits() {
            return false;
        }
        if self.take(b'e') || self.take(b'E') {
            if !self.take(b'+') {
                self.take(b'-');
            }
            if !self.digits() {
                return false;
            }
        }
        true
    }
}

impl crate::ruby_trace::NativeOnly for Scratch {}
const _: fn(&Scratch) = |scratch| {
    let Scratch(buffer) = scratch;
    crate::ruby_trace::require_native(buffer);
};
