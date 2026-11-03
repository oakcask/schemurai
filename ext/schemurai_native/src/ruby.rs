//! CRuby boundary. Handles are neither roots nor permission to call Ruby.
use std::marker::PhantomData;
use std::rc::Rc;

/// An opaque CRuby VALUE, usable only while its C owner keeps it alive.
///
/// The transparent layout preserves the C ABI and borrowed VALUE arrays.
/// Native entrypoints run in the calling Ractor and never spawn threads.
/// The marker prevents safe Rust from moving or sharing handles across threads;
/// C remains responsible for rooting, GVL ownership and Ruby publication.
/// This type does not enforce GC reachability or borrowed-view lifetimes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct Value {
    bits: usize,
    // Zero-sized !Send/!Sync marker; no Rc allocation or reference counting.
    // PhantomData<*const ()> would impose the same thread restriction.
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

#[cfg(test)]
pub(crate) const fn test_fixnum_tag(bits: usize) -> FixnumTag {
    FixnumTag { bits }
}

#[cfg(test)]
pub(crate) fn test_value(bits: usize) -> Value {
    // Synthetic identity only; tests must never dereference it through CRuby.
    unsafe { Value::from_raw(bits) }
}

#[cfg(test)]
mod tests {
    use super::*;
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
