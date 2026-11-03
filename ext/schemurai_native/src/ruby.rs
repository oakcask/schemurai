//! CRuby boundary. Handles are neither roots nor permission to call Ruby.
use crate::protocol::*;
use std::ffi::c_void;
use std::marker::PhantomData;
use std::rc::Rc;

/// An opaque CRuby VALUE, usable only while its C owner keeps it alive.
///
/// The transparent layout preserves the C ABI and borrowed VALUE arrays.
/// Native entrypoints run in the calling Ractor and never spawn threads.
/// The marker prevents safe Rust from moving or sharing handles across threads;
/// C remains responsible for rooting, GVL ownership and Ruby publication.
/// This type does not enforce GC reachability or borrowed-view lifetimes.
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[cfg_attr(not(test), derive(Debug))]
#[repr(transparent)]
pub struct Value {
    bits: usize,
    // Zero-sized !Send/!Sync marker; no Rc allocation or reference counting.
    // PhantomData<*const ()> would impose the same thread restriction.
    affinity: PhantomData<Rc<()>>,
}
impl Value {
    pub(crate) const fn has_fixnum_tag(self, flag: FixnumTag) -> bool {
        self.bits & flag.bits != 0
    }
    pub(crate) const fn bits(self) -> usize {
        self.bits
    }
}

/// Header-verified immediate-integer encoding, distinct from depths and sizes.
#[derive(Clone, Copy, Debug, Default)]
#[repr(transparent)]
pub(crate) struct FixnumTag {
    bits: usize,
}
impl FixnumTag {
    pub(crate) const fn is_low_bit(self) -> bool {
        self.bits == 1
    }
}

#[cfg(test)]
pub(crate) const fn test_fixnum_tag(bits: usize) -> FixnumTag {
    FixnumTag { bits }
}

// A stable prefix makes synthetic identities recognizable in crash dumps.
// Reserve the high 16 bits on both 32- and 64-bit hosts; the remaining bits
// encode the caller's sequence number without changing parity or ordering.
#[cfg(test)]
const TEST_VALUE_MASK: usize = 0xffff << (usize::BITS - 16);
#[cfg(test)]
const TEST_VALUE_MAGIC: usize = 0xdead << (usize::BITS - 16);

/// Deterministic synthetic identity; never pass it to CRuby or dereference it.
/// Equal sequence numbers produce equal handles regardless of test ordering.
#[cfg(test)]
pub(crate) fn test_value(sequence: usize) -> Value {
    assert!(sequence <= !TEST_VALUE_MASK, "test VALUE sequence overflow");
    Value {
        bits: TEST_VALUE_MAGIC | sequence,
        affinity: PhantomData,
    }
}

/// Actual immediate encoding for tests that inspect Fixnum representation.
#[cfg(test)]
pub(crate) fn test_fixnum(integer: i64) -> Value {
    let limit = 1_i64 << (usize::BITS - 2);
    assert!((-limit..limit).contains(&integer));
    Value {
        bits: ((integer as usize) << 1) | 1,
        affinity: PhantomData,
    }
}

#[cfg(test)]
impl std::fmt::Debug for Value {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "Value({:#x})", self.bits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_identities_preserve_the_magic_prefix_and_sequence() {
        for sequence in 0..=4096 * 3 {
            let value = test_value(sequence);
            assert_eq!(value.bits() & TEST_VALUE_MASK, TEST_VALUE_MAGIC);
            assert_eq!(value.bits() & !TEST_VALUE_MASK, sequence);
            assert_eq!(value, test_value(sequence));
            if sequence != 0 {
                assert!(test_value(sequence - 1) < value);
            }
        }
        assert_eq!(
            test_value(!TEST_VALUE_MASK).bits(),
            TEST_VALUE_MAGIC | !TEST_VALUE_MASK
        );
        assert!(format!("{:?}", test_value(42)).starts_with("Value(0xdead"));
    }

    #[test]
    #[should_panic(expected = "test VALUE sequence overflow")]
    fn synthetic_identity_rejects_sequence_overflow() {
        test_value(!TEST_VALUE_MASK + 1);
    }

    #[test]
    fn classified_views_read_outputs_only_for_strings() {
        unsafe extern "C" fn non_string(_: Value, _: *mut *const u8, _: *mut usize) -> i32 {
            // The C classifier deliberately leaves these outputs uninitialized.
            -7
        }
        unsafe extern "C" fn string(_: Value, data: *mut *const u8, len: *mut usize) -> i32 {
            unsafe {
                *data = b"view".as_ptr();
                *len = 4;
            }
            2
        }
        unsafe extern "C" fn empty(_: Value, data: *mut *const u8, len: *mut usize) -> i32 {
            unsafe {
                *data = std::ptr::null();
                *len = 0;
            }
            0
        }
        unsafe {
            assert_eq!(
                Ruby::classified_bytes(test_value(0), non_string),
                (&[][..], -7)
            );
            assert_eq!(
                Ruby::classified_bytes(test_value(0), string),
                (&b"view"[..], 2)
            );
            assert_eq!(Ruby::classified_bytes(test_value(0), empty), (&[][..], 0));
        }
    }

    #[test]
    fn value_keeps_the_c_word_layout() {
        assert_eq!(std::mem::size_of::<Value>(), std::mem::size_of::<usize>());
        assert_eq!(std::mem::align_of::<Value>(), std::mem::align_of::<usize>());
        assert_eq!(
            std::mem::size_of::<FixnumTag>(),
            std::mem::size_of::<usize>()
        );
        assert_eq!(
            std::mem::align_of::<FixnumTag>(),
            std::mem::align_of::<usize>()
        );
    }
}

/// The initialized output selected by the fingerprint adapter's classification.
#[derive(Clone, Copy)]
pub(crate) enum FingerprintView<'a> {
    Number(f64),
    Boolean(bool),
    String(&'a [u8]),
    Array(&'a [Value]),
    Object(usize),
    Scalar(i32),
}

/// Borrowed CRuby views for synchronous native execution in the calling Ractor.
///
/// This namespace carries no VM token. Every operation is unsafe: C owns the
/// roots and GVL, and callers must end views before Ruby allocation or callbacks.
/// The caller chooses the lifetime; these helpers do not prove reachability or
/// prevent invalidation. Revisit this contract before adding native threads or
/// allowing Ruby execution while a view remains in use.
pub(crate) struct Ruby;
impl Ruby {
    /// # Safety
    /// Data must be aligned and readable for len bytes for the entire chosen
    /// lifetime. Keep its owner rooted and unchanged under the calling Ractor's
    /// GVL; do not allocate in Ruby or run Ruby callbacks during the loan.
    /// A null pointer is permitted only when len is zero.
    pub(crate) unsafe fn bytes<'a>(data: *const u8, len: usize) -> &'a [u8] {
        if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        }
    }

    /// # Safety
    /// Same requirements as bytes, for len initialized CRuby VALUEs. Data must
    /// be aligned for Value and remain within a single allocation.
    pub(crate) unsafe fn values<'a>(data: *const Value, len: usize) -> &'a [Value] {
        if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        }
    }

    /// # Safety
    /// Value must be a classified String, rooted and unchanged under the GVL
    /// for the entire chosen lifetime, with no Ruby allocation or callbacks.
    pub(crate) unsafe fn string<'a>(value: Value) -> &'a [u8] {
        let mut data = std::ptr::null();
        let mut len = 0;
        unsafe {
            sn_string_raw_view(value, &mut data, &mut len);
            Self::bytes(data, len)
        }
    }

    /// String bytes and UTF-8/ASCII encoding metadata.
    /// # Safety
    /// Value must already be a classified, rooted String.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    pub(crate) unsafe fn string_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_string_view) }
    }

    /// String bytes and encoding metadata, including the cached seven-bit hint.
    /// # Safety
    /// Value must already be a classified, rooted String.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    pub(crate) unsafe fn pattern_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_pattern_view) }
    }

    /// Exact String key bytes and its CRuby encoding index.
    /// # Safety
    /// Value must already be a classified, rooted String.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    pub(crate) unsafe fn record_key_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_record_key_view) }
    }

    /// Classified pattern operand bytes and encoding, or a negative kind.
    /// # Safety
    /// Value must be live and rooted in the calling Ractor.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    /// Negative classifications return an empty slice without reading outputs.
    pub(crate) unsafe fn pattern_item_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_pattern_item_view) }
    }

    /// Classified format operand bytes, or a negative kind.
    /// # Safety
    /// Value must be live and rooted in the calling Ractor.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    /// Negative classifications return an empty slice without reading outputs.
    pub(crate) unsafe fn format_item_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_format_item_view) }
    }

    /// Classified JSON operand bytes and encoding, or a negative kind.
    /// # Safety
    /// Value must be live and rooted in the calling Ractor.
    /// Keep the owner unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while the bytes remain in use.
    /// Negative classifications return an empty slice without reading outputs.
    pub(crate) unsafe fn json_item_view<'a>(value: Value) -> (&'a [u8], i32) {
        unsafe { Self::classified_bytes(value, sn_json_item_view) }
    }

    // Only nonnegative adapter results initialize the pointer and length.
    // Keep this rule here so callers never interpret uninitialized C outputs.
    unsafe fn classified_bytes<'a>(
        value: Value,
        adapter: unsafe extern "C" fn(Value, *mut *const u8, *mut usize) -> i32,
    ) -> (&'a [u8], i32) {
        let mut data = std::mem::MaybeUninit::uninit();
        let mut len = std::mem::MaybeUninit::uninit();
        let kind = unsafe { adapter(value, data.as_mut_ptr(), len.as_mut_ptr()) };
        let bytes = if kind < 0 {
            &[]
        } else {
            unsafe { Self::bytes(data.assume_init(), len.assume_init()) }
        };
        (bytes, kind)
    }

    /// Classify a fingerprint operand and borrow only its initialized output.
    /// # Safety
    /// Value must be live and rooted in the calling Ractor. Keep its owner and
    /// descendants unchanged under the GVL for the entire chosen lifetime,
    /// with no Ruby allocation or callbacks while a returned view is in use.
    pub(crate) unsafe fn fingerprint_view<'a>(value: Value) -> FingerprintView<'a> {
        use std::mem::MaybeUninit;
        let mut data = MaybeUninit::<*const c_void>::uninit();
        let mut len = MaybeUninit::uninit();
        let mut number = MaybeUninit::uninit();
        let kind = unsafe {
            sn_fingerprint_view(
                value,
                data.as_mut_ptr(),
                len.as_mut_ptr(),
                number.as_mut_ptr(),
            )
        };
        // The C adapter initializes only the outputs selected by its kind.
        match kind {
            TYPE_NUMBER => FingerprintView::Number(unsafe { number.assume_init() }),
            TYPE_BOOLEAN => FingerprintView::Boolean(unsafe { len.assume_init() } != 0),
            TYPE_STRING => FingerprintView::String(unsafe {
                Self::bytes(data.assume_init().cast(), len.assume_init())
            }),
            TYPE_ARRAY => FingerprintView::Array(unsafe {
                Self::values(data.assume_init().cast(), len.assume_init())
            }),
            TYPE_OBJECT => FingerprintView::Object(unsafe { len.assume_init() }),
            _ => FingerprintView::Scalar(kind),
        }
    }

    /// # Safety
    /// Value must be a classified Array, rooted and unchanged under the GVL
    /// for the entire chosen lifetime, with no Ruby allocation or callbacks.
    pub(crate) unsafe fn array<'a>(value: Value) -> &'a [Value] {
        unsafe { Self::values(sn_array_data(value), sn_len(value)) }
    }
}

/// Borrow an initialized prefix without extending the Rust buffer's lifetime.
/// # Safety
/// C must have initialized every element in the prefix, with len <= N.
pub(crate) unsafe fn initialized_values<const N: usize>(
    buffer: &std::mem::MaybeUninit<[Value; N]>,
    len: usize,
) -> &[Value] {
    assert!(len <= N);
    unsafe { Ruby::values(buffer.as_ptr().cast::<Value>(), len) }
}

unsafe extern "C" {
    pub(super) fn sn_pin(value: Value);
    pub(super) fn sn_nil() -> Value;
    pub(super) fn sn_undefined() -> Value;
    pub(super) fn sn_kind(value: Value) -> i32;
    pub(super) fn sn_shallow_kind(value: Value) -> i32;
    fn sn_fingerprint_view(
        value: Value,
        data: *mut *const c_void,
        length: *mut usize,
        number: *mut f64,
    ) -> i32;
    pub(super) fn sn_small_hash(value: Value, entries: *mut Value) -> i32;
    pub(super) fn sn_true(value: Value) -> i32;
    pub(super) fn sn_truthy(value: Value) -> i32;
    pub(super) fn sn_fixnum(value: Value) -> i32;
    pub(super) fn sn_fixnum_flag() -> FixnumTag;
    fn sn_array_data(value: Value) -> *const Value;
    pub(super) fn sn_integer(value: Value) -> i64;
    pub(super) fn sn_integer128(value: Value, words: *mut u64) -> i32;
    pub(super) fn sn_integer_bounds128(value: Value, words: *mut u64) -> i32;
    pub(super) fn sn_number_bounds_view(
        value: Value,
        words: *mut u64,
        kind: *mut i32,
        floating: *mut f64,
        required: i32,
    ) -> i32;
    pub(super) fn sn_integer1024(value: Value, words: *mut u64) -> i32;
    pub(super) fn sn_integer_word_count(value: Value) -> usize;
    pub(super) fn sn_integer_words(value: Value, words: *mut u64, count: usize) -> i32;
    pub(super) fn sn_is_bignum(value: Value) -> i32;
    pub(super) fn sn_big256(value: Value, words: *mut u64) -> i32;
    pub(super) fn sn_big_hash(value: Value, hash: *mut u64) -> i32;
    pub(super) fn sn_big_low_word(value: Value) -> u64;
    pub(super) fn sn_big_low64_word(value: Value, word: *mut u64) -> i32;
    pub(super) fn sn_big_equal(big: Value, other: Value) -> i32;
    pub(super) fn sn_big_order(left: Value, right: Value) -> i32;
    pub(super) fn sn_wide_integer_compare(value: Value, bound: Value) -> i32;
    pub(super) fn sn_float(value: Value) -> f64;
    pub(super) fn sn_is_float(value: Value) -> i32;
    pub(super) fn sn_is_rational(value: Value) -> i32;
    pub(super) fn sn_len(value: Value) -> usize;
    pub(super) fn sn_entry(value: Value, index: usize) -> Value;
    pub(super) fn sn_lookup(hash: Value, key: Value) -> Value;
    pub(super) fn sn_missing(value: Value) -> i32;
    pub(super) fn sn_same(a: Value, b: Value) -> i32;
    pub(super) fn sn_same_class(a: Value, b: Value) -> i32;
    pub(super) fn sn_string_bytes(value: Value) -> usize;
    pub(super) fn sn_string_equal(a: Value, b: Value) -> i32;
    pub(super) fn sn_string_length_guarded(value: Value, length: *mut usize) -> i32;
    fn sn_record_key_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_string_raw_view(value: Value, data: *mut *const u8, length: *mut usize);
    fn sn_string_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_pattern_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_pattern_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_format_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    pub(super) fn sn_json_encoding(value: Value) -> i32;
    fn sn_json_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    pub(super) fn sn_resolve(
        compiler: Value,
        program: Value,
        reference: Value,
        result: *mut Value,
    ) -> i32;
    pub(super) fn sn_resolution_error(error: Value) -> i32;
    pub(super) fn sn_resource_program(compiler: Value, resource: Value, result: *mut Value) -> i32;
    pub(super) fn sn_anchor_count(resource: Value) -> usize;
    pub(super) fn sn_anchor_names(compiler: Value, resource: Value, result: *mut Value) -> i32;
    pub(super) fn sn_anchor_program(
        compiler: Value,
        resource: Value,
        name: Value,
        result: *mut Value,
    ) -> i32;
    pub(super) fn sn_hash_each(
        value: Value,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void, Value, Value) -> i32,
    ) -> i32;
    pub(super) fn sn_hash_each_key_view(
        value: Value,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void, *const u8, usize, Value) -> i32,
    ) -> i32;
    pub(super) fn sn_field(object: Value, name: i32, value: *mut Value) -> i32;
    pub(super) fn sn_pairs(hash: Value, value: *mut Value) -> i32;
    pub(super) fn sn_key_copy(key: Value, value: *mut Value) -> i32;
    pub(super) fn sn_opcode(symbol: Value) -> i32;
    pub(super) fn sn_object_each(value: Value, context: *mut c_void) -> i32;
}

unsafe extern "C" {
    pub(super) fn sn_runtime_ordinal(ordinal: usize) -> Value;
    pub(super) fn sn_cached_runtime(
        matches: *const c_void,
        operation: i32,
        source: Value,
        value: Value,
    ) -> i32;
}

unsafe extern "C" {
    pub(super) fn sn_references_read(active: Value, pairs: *mut c_void);
}
