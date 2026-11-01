//! Field-complete traversal of owned Ruby handles. No Ruby allocation occurs.
use super::ruby::{Value, sn_pin};

/// Enumerates handles held in an immutable, readable snapshot.
/// This does not root a value or authorize accessing a running Ractor's state.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum TraceMode {
    /// GC may encounter a stopped Ractor with an active interior borrow.
    Available,
    /// Outside native execution every owned field must be readable.
    Complete,
}

pub(crate) trait Trace {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode);

    fn trace(&self, visit: &mut impl FnMut(Value)) {
        self.trace_with(visit, TraceMode::Available);
    }

    /// Build only between native passes, before invoking allocating Ruby code.
    /// Borrow conflicts are invariant violations, never silently omitted roots.
    fn snapshot(&self) -> RootSnapshot {
        let mut values = Vec::new();
        self.trace_with(&mut |value| values.push(value), TraceMode::Complete);
        values.sort_unstable();
        values.dedup();
        RootSnapshot {
            values: values.into_boxed_slice(),
        }
    }

    /// # Safety
    /// Call only from the owning TypedData mark callback during CRuby GC.
    /// The snapshot must be readable without aliasing a mutable Rust borrow.
    unsafe fn mark(&self) {
        self.trace(&mut |value| unsafe { sn_pin(value) });
    }
}
/// An immutable copy of all handles held by one owner between native passes.
/// C owns the box and marks it independently of the mutable source state.
pub struct RootSnapshot {
    values: Box<[Value]>,
}

impl<T: Trace> Trace for [T] {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: TraceMode) {
        for item in self {
            item.trace_with(visit, mode);
        }
    }
}
impl<T: Trace + ?Sized> Trace for Box<T> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: TraceMode) {
        (**self).trace_with(visit, mode);
    }
}

/// # Safety
/// Snapshot must be live and immutable; call only from its C owner's GC mark.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_snapshot_mark(snapshot: *const RootSnapshot) {
    unsafe { (&*snapshot).mark() };
}
/// # Safety
/// Snapshot must be live and immutable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_snapshot_size(snapshot: *const RootSnapshot) -> usize {
    std::mem::size_of::<RootSnapshot>()
        + unsafe { &*snapshot }.values.len() * std::mem::size_of::<Value>()
}
/// # Safety
/// A non-null snapshot must be an owned box, freed exactly once by C.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_snapshot_free(snapshot: *mut RootSnapshot) {
    if !snapshot.is_null() {
        drop(unsafe { Box::from_raw(snapshot) });
    }
}

impl Trace for Value {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        let _ = mode;
        visit(*self);
    }
}
impl<T: Trace> Trace for Vec<T> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        for item in self {
            item.trace_with(visit, mode);
        }
    }
}
impl<T: Trace> Trace for Option<T> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        if let Some(item) = self {
            item.trace_with(visit, mode);
        }
    }
}
impl<A: Trace, B: Trace> Trace for (A, B) {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        self.0.trace_with(visit, mode);
        self.1.trace_with(visit, mode);
    }
}
impl<T: Trace, S> Trace for std::collections::HashSet<T, S> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        for item in self {
            item.trace_with(visit, mode);
        }
    }
}

// Destructure without `..`: adding or renaming ANY field fails compilation.
// Native fields are explicitly checked as Ruby-free. Changing one to Value,
// including inside a container, cannot silently remove it from the traversal.
macro_rules! trace_fields {
    ($ty:ty { $($trace:ident),* ; $($native:ident),* $(,)? }) => {
        impl $crate::ruby_trace::Trace for $ty {
            fn trace_with(&self, visit: &mut impl FnMut($crate::ruby::Value), mode: $crate::ruby_trace::TraceMode) {
                let Self { $($trace,)* $($native,)* } = self;
                $($crate::ruby_trace::Trace::trace_with($trace, visit, mode);)*
                $($crate::ruby_trace::require_native($native);)*
            }
        }
    };
}
pub(crate) use trace_fields;
trace_fields!(RootSnapshot { values ; });

/// Types that contain no Ruby handles. There is deliberately no impl for Value.
pub(crate) trait NativeOnly {}
pub(crate) fn require_native<T: NativeOnly + ?Sized>(_: &T) {}
macro_rules! native_scalars {
    ($($ty:ty),*) => { $(impl NativeOnly for $ty {})* };
}
native_scalars!(bool, u8, u32, u64, usize, i32, f64, String, str);
impl<T: NativeOnly + ?Sized> NativeOnly for &T {}
impl<T: NativeOnly> NativeOnly for Vec<T> {}
impl<T: NativeOnly> NativeOnly for Option<T> {}
impl<A: NativeOnly, B: NativeOnly> NativeOnly for (A, B) {}
impl<K: NativeOnly, V: NativeOnly, S> NativeOnly for std::collections::HashMap<K, V, S> {}

macro_rules! native_fields {
    ($ty:ident { $($field:ident),* $(,)? }) => {
        impl $crate::ruby_trace::NativeOnly for $ty {}
        const _: fn(&$ty) = |value| {
            let $ty { $($field,)* } = value;
            $($crate::ruby_trace::require_native($field);)*
        };
    };
}
pub(crate) use native_fields;

impl Trace for i32 {
    fn trace_with(&self, _: &mut impl FnMut(Value), _: crate::ruby_trace::TraceMode) {}
}

impl Trace for usize {
    fn trace_with(&self, _: &mut impl FnMut(Value), _: crate::ruby_trace::TraceMode) {}
}

impl<A: Trace, B: Trace, C: Trace> Trace for (A, B, C) {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        self.0.trace_with(visit, mode);
        self.1.trace_with(visit, mode);
        self.2.trace_with(visit, mode);
    }
}
impl Trace for &str {
    fn trace_with(&self, _: &mut impl FnMut(Value), _: crate::ruby_trace::TraceMode) {}
}
impl<T: Trace, const N: usize> Trace for [T; N] {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        for item in self {
            item.trace_with(visit, mode);
        }
    }
}
impl<K: Trace, V: Trace, S> Trace for std::collections::HashMap<K, V, S> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        for (key, value) in self {
            key.trace_with(visit, mode);
            value.trace_with(visit, mode);
        }
    }
}
impl<T: Trace> Trace for std::rc::Rc<T> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        (**self).trace_with(visit, mode);
    }
}
impl<T: Copy + Trace> Trace for std::cell::Cell<T> {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        self.get().trace_with(visit, mode);
    }
}
impl<T: NativeOnly> NativeOnly for std::cell::Cell<T> {}
impl<T: NativeOnly> NativeOnly for std::cell::RefCell<T> {}
impl<T: NativeOnly> NativeOnly for Box<T> {}
impl NativeOnly for std::time::Instant {}

pub(crate) fn require_borrowed<T>(_: *const T) {}

// Runner-owned state is snapshotted completely before entering Ruby. GC may
// skip an active mutable borrow only because that immutable snapshot and C's
// newly published results retain the unavailable handles independently.
// Complete traversal is mandatory when creating the next snapshot.
macro_rules! trace_runner_fields {
    ($ty:ty {
        $($strong:ident),* ; $($guarded:ident),* ;
        $($native:ident),* ; $($borrowed:ident),* $(,)?
    }) => {
        impl $crate::ruby_trace::Trace for $ty {
            fn trace_with(&self, visit: &mut impl FnMut($crate::ruby::Value), mode: $crate::ruby_trace::TraceMode) {
                let Self { $($strong,)* $($guarded,)* $($native,)* $($borrowed,)* } = self;
                $($crate::ruby_trace::Trace::trace_with($strong, visit, mode);)*
                $(match $guarded.try_borrow() {
                    Ok(snapshot) => $crate::ruby_trace::Trace::trace_with(&*snapshot, visit, mode),
                    Err(_) if mode == $crate::ruby_trace::TraceMode::Complete => {
                        panic!("runner snapshot contains an active mutable borrow: {}", stringify!($guarded));
                    }
                    Err(_) => {}
                })*
                $($crate::ruby_trace::require_native($native);)*
                $($crate::ruby_trace::require_borrowed($borrowed.get());)*
            }
        }
    };
}
pub(crate) use trace_runner_fields;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ruby::test_value as v;

    struct Guarded {
        direct: Value,
        values: std::cell::RefCell<std::collections::HashMap<Value, Vec<Value>>>,
    }
    trace_runner_fields!(Guarded { direct ; values ; ; });

    #[test]
    fn immutable_snapshot_retains_removed_handles_while_source_is_borrowed() {
        let source = Guarded {
            direct: v(1),
            values: std::cell::RefCell::new(std::collections::HashMap::from([(
                v(3),
                vec![v(5), v(3)],
            )])),
        };
        let snapshot = source.snapshot();
        let mut source_values = source.values.borrow_mut();
        source_values.clear();
        let mut available = vec![];
        source.trace(&mut |value| available.push(value));
        assert_eq!(available, [v(1)]);
        let mut protected = vec![];
        snapshot.trace(&mut |value| protected.push(value));
        assert_eq!(protected, [v(1), v(3), v(5)]);
    }

    #[test]
    fn complete_mode_reaches_nested_cells_and_rejects_partial_snapshots() {
        let sources = vec![Some(Guarded {
            direct: v(1),
            values: std::cell::RefCell::new(std::collections::HashMap::from([(v(3), vec![v(5)])])),
        })];
        let borrow = sources[0].as_ref().unwrap().values.borrow_mut();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| sources.snapshot())).is_err()
        );
        drop(borrow);
        let snapshot = sources.snapshot();
        drop(sources);
        let mut values = vec![];
        snapshot.trace(&mut |value| values.push(value));
        assert_eq!(values, [v(1), v(3), v(5)]);
    }

    #[test]
    fn follows_nested_handles_and_keeps_duplicates() {
        let snapshot = vec![Some((v(1), v(3))), None, Some((v(1), v(5)))];
        let mut handles = vec![];
        snapshot.trace(&mut |value| handles.push(value));
        assert_eq!(handles, [v(1), v(3), v(1), v(5)]);
    }
}
