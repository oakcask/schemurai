//! CRuby boundary. Handles are neither roots nor permission to call Ruby.
use std::ffi::c_void;
use std::marker::PhantomData;
use std::rc::Rc;

/// An opaque CRuby VALUE, usable only while its C owner keeps it alive.
///
/// The transparent layout preserves the C ABI and borrowed VALUE arrays.
/// Thread affinity is deliberate: C alone may publish a frozen engine after
/// making every hidden Ruby root shareable. Runtime state stays Ractor-local.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct Value {
    bits: usize,
    affinity: PhantomData<Rc<()>>,
}
impl Value {
    /// Only for CRuby's zero sentinel and synthetic immediate test values.
    /// # Safety
    /// Bits must be a valid VALUE, or an unset output never passed to Ruby.
    #[cfg(test)]
    pub(crate) const unsafe fn from_raw(bits: usize) -> Self {
        Self {
            bits,
            affinity: PhantomData,
        }
    }
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
crate::ruby_trace::native_fields!(FixnumTag { bits });

#[cfg(test)]
pub(crate) const fn test_fixnum_tag(bits: usize) -> FixnumTag {
    FixnumTag { bits }
}

/// Access to one active CRuby invocation. No cloning, global storage or Send/Sync.
/// Shared borrowing authorizes views; Ruby callbacks require exclusive access.
pub(crate) struct Ruby {
    affinity: PhantomData<Rc<()>>,
}
impl Ruby {
    /// # Safety
    /// Enter only at a C/Rust boundary under the owning Ractor's GVL. C must
    /// keep all accessed owners rooted, and no older Ruby view may be live on
    /// this thread. Do not create another token to bypass an existing loan.
    pub(crate) unsafe fn enter() -> Self {
        Self {
            affinity: PhantomData,
        }
    }

    /// # Safety
    /// Data must point to len readable bytes, rooted and unchanged for this
    /// invocation. A null pointer is permitted only for an empty view.
    pub(crate) unsafe fn bytes(&self, data: *const u8, len: usize) -> &[u8] {
        if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        }
    }
    /// # Safety
    /// Same requirements as bytes, for CRuby VALUE array storage.
    pub(crate) unsafe fn values(&self, data: *const Value, len: usize) -> &[Value] {
        if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        }
    }
    /// # Safety
    /// Value must be a classified, rooted String, unchanged during this loan.
    pub(crate) unsafe fn string(&self, value: Value) -> &[u8] {
        let mut data = std::ptr::null();
        let mut len = 0;
        unsafe {
            sn_string_raw_view(value, &mut data, &mut len);
            self.bytes(data, len)
        }
    }
    /// # Safety
    /// Value must be a classified, rooted Array, unchanged during this loan.
    pub(crate) unsafe fn array(&self, value: Value) -> &[Value] {
        unsafe { self.values(sn_array_data(value), sn_len(value)) }
    }
    /// # Safety
    /// Error and output must be live/rooted. Constant lookup can run Ruby.
    pub(crate) unsafe fn sn_resolution_error(&mut self, error: Value, result: *mut Value) -> i32 {
        unsafe { sn_resolution_error(error, result) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_field(&mut self, object: Value, name: i32, output: *mut Value) -> i32 {
        unsafe { sn_field(object, name, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_pairs(&mut self, hash: Value, output: *mut Value) -> i32 {
        unsafe { sn_pairs(hash, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_key_copy(&mut self, key: Value, output: *mut Value) -> i32 {
        unsafe { sn_key_copy(key, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_resolve(
        &mut self,
        compiler: Value,
        program: Value,
        reference: Value,
        output: *mut Value,
    ) -> i32 {
        unsafe { sn_resolve(compiler, program, reference, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_resource_program(
        &mut self,
        compiler: Value,
        resource: Value,
        output: *mut Value,
    ) -> i32 {
        unsafe { sn_resource_program(compiler, resource, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_anchor_names(
        &mut self,
        compiler: Value,
        resource: Value,
        output: *mut Value,
    ) -> i32 {
        unsafe { sn_anchor_names(compiler, resource, output) }
    }
    /// # Safety
    /// Arguments/outputs must satisfy the protected C adapter's contract.
    pub(crate) unsafe fn sn_anchor_program(
        &mut self,
        compiler: Value,
        resource: Value,
        name: Value,
        output: *mut Value,
    ) -> i32 {
        unsafe { sn_anchor_program(compiler, resource, name, output) }
    }
}

/// Loan initialized prefix storage without extending the Rust buffer's lifetime.
/// # Safety
/// C must have initialized exactly this prefix, with len <= N.
pub(crate) unsafe fn initialized_values<const N: usize>(
    buffer: &std::mem::MaybeUninit<[Value; N]>,
    len: usize,
) -> &[Value] {
    debug_assert!(len <= N);
    if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(buffer.as_ptr().cast::<Value>(), len) }
    }
}

unsafe extern "C" {
    pub(super) fn sn_pin(value: Value);
    pub(super) fn sn_nil() -> Value;
    pub(super) fn sn_undefined() -> Value;
    pub(super) fn sn_kind(value: Value) -> i32;
    pub(super) fn sn_shallow_kind(value: Value) -> i32;
    pub(super) fn sn_fingerprint_view(
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
    pub(super) fn sn_record_key_view(value: Value, data: *mut *const u8, length: *mut usize)
    -> i32;
    fn sn_string_raw_view(value: Value, data: *mut *const u8, length: *mut usize);
    pub(super) fn sn_string_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    pub(super) fn sn_pattern_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    pub(super) fn sn_pattern_item_view(
        value: Value,
        data: *mut *const u8,
        length: *mut usize,
    ) -> i32;
    pub(super) fn sn_format_item_view(
        value: Value,
        data: *mut *const u8,
        length: *mut usize,
    ) -> i32;
    pub(super) fn sn_json_encoding(value: Value) -> i32;
    pub(super) fn sn_json_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_resolve(compiler: Value, program: Value, reference: Value, result: *mut Value) -> i32;
    fn sn_resolution_error(error: Value, result: *mut Value) -> i32;
    fn sn_resource_program(compiler: Value, resource: Value, result: *mut Value) -> i32;
    pub(super) fn sn_anchor_count(resource: Value) -> usize;
    fn sn_anchor_names(compiler: Value, resource: Value, result: *mut Value) -> i32;
    fn sn_anchor_program(compiler: Value, resource: Value, name: Value, result: *mut Value) -> i32;
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
    fn sn_field(object: Value, name: i32, value: *mut Value) -> i32;
    fn sn_pairs(hash: Value, value: *mut Value) -> i32;
    fn sn_key_copy(key: Value, value: *mut Value) -> i32;
    pub(super) fn sn_opcode(symbol: Value) -> i32;
    pub(super) fn sn_object_each(value: Value, context: *mut c_void) -> i32;
}

#[cfg(test)]
pub(crate) fn test_value(bits: usize) -> Value {
    // Synthetic identity only; tests must never dereference it through CRuby.
    unsafe { Value::from_raw(bits) }
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn value_keeps_the_c_word_layout() {
        assert_eq!(std::mem::size_of::<Value>(), std::mem::size_of::<usize>());
        assert_eq!(std::mem::align_of::<Value>(), std::mem::align_of::<usize>());
    }
}
