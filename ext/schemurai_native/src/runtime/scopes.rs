//! Invocation scope snapshots and scope effects of completed Ruby requests.
use super::*;
use std::cell::{Cell, RefCell};

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum Key {
    Value(Value, Value, i32),
    Message(Message),
    Pointer(usize),
    Rescue(StringError),
}
#[derive(Default)]
pub(super) struct Scopes {
    enabled: Cell<bool>,
    initial_references: RefCell<Vec<(Value, Value)>>,
    vm_references: RefCell<Vec<(Value, Value)>>,
    pending_references: RefCell<Vec<(Value, Value)>>,
    reference: Cell<*const Reference>,
    initial: RefCell<Vec<Value>>,
    stack: RefCell<Vec<Value>>,
    pending: RefCell<Vec<Value>>,
    key: Cell<Option<Key>>,
    effects: RefCell<HashMap<Key, Vec<Value>>>,
    entered: Cell<usize>,
    unwind: Cell<usize>,
}
pub(crate) struct Guard<'a> {
    scopes: &'a Scopes,
    entered: bool,
}
// Stack records are read only while their guards are live. No pointer survives
// native unwinding: requests copy the pairs before returning to C/Ruby.
pub(crate) struct Reference {
    pair: (Value, Value),
    parent: *const Reference,
}
pub(crate) struct ReferenceGuard<'a> {
    scopes: &'a Scopes,
    frame: &'a Reference,
}
impl Drop for ReferenceGuard<'_> {
    fn drop(&mut self) {
        self.scopes.reference.set(self.frame.parent);
    }
}
impl Drop for Guard<'_> {
    fn drop(&mut self) {
        if self.entered {
            self.scopes.stack.borrow_mut().pop();
            self.scopes.entered.set(self.scopes.entered.get() - 1);
        }
    }
}
impl Scopes {
    pub(super) fn enabled(&self) -> bool {
        self.enabled.get()
    }
    pub(super) fn clear(&self) {
        self.enabled.set(false);
        self.initial_references.borrow_mut().clear();
        self.vm_references.borrow_mut().clear();
        self.pending_references.borrow_mut().clear();
        self.reference.set(std::ptr::null());
        self.initial.borrow_mut().clear();
        self.stack.borrow_mut().clear();
        self.pending.borrow_mut().clear();
        *self.effects.borrow_mut() = HashMap::new();
        self.key.set(None);
        self.entered.set(0);
        self.unwind.set(0);
    }
    pub(super) fn inherit(&self, values: Vec<Value>, enabled: bool) {
        self.enabled.set(enabled);
        *self.initial.borrow_mut() = values;
        self.reset();
    }
    pub(super) fn reset(&self) {
        if self.enabled() {
            self.stack.borrow_mut().clone_from(&self.initial.borrow());
        }
        self.reference.set(std::ptr::null());
        self.pending_references.borrow_mut().clear();
        self.key.set(None);
        self.unwind.set(0);
        self.entered.set(0);
    }
    pub(super) fn enter(&self, resource: Value, enters: bool) -> Guard<'_> {
        let entered = self.enabled() && enters && self.stack.borrow().last() != Some(&resource);
        if entered {
            self.stack.borrow_mut().push(resource);
            self.entered.set(self.entered.get() + 1);
        }
        Guard {
            scopes: self,
            entered,
        }
    }
    pub(super) fn at(&self, index: usize) -> Option<Value> {
        self.stack.borrow().get(index).copied()
    }
    pub(super) fn reference_frame(&self, program: Value, instance: Value) -> Reference {
        Reference {
            pair: (program, instance),
            parent: self.reference.get(),
        }
    }
    pub(super) fn reference_guard<'a>(&'a self, frame: &'a Reference) -> ReferenceGuard<'a> {
        if self.enabled() {
            self.reference.set(frame);
        }
        ReferenceGuard {
            scopes: self,
            frame,
        }
    }
    pub(super) fn reference_active(&self, program: Value, instance: Value) -> bool {
        self.enabled()
            && (self
                .initial_references
                .borrow()
                .contains(&(program, instance))
                || self.vm_references.borrow().contains(&(program, instance)))
    }
    fn references(&self, initial: bool) -> std::cell::Ref<'_, Vec<(Value, Value)>> {
        if !initial && self.key.get().is_some() {
            self.pending_references.borrow()
        } else {
            self.initial_references.borrow()
        }
    }
    pub(super) fn request(&self, key: Key) {
        if self.enabled() {
            self.pending.borrow_mut().clone_from(&self.stack.borrow());
            let mut pairs = self.pending_references.borrow_mut();
            pairs.clone_from(&self.initial_references.borrow());
            let mut reference = self.reference.get();
            while !reference.is_null() {
                // Each pointer belongs to a stack record borrowed by a live guard.
                let frame = unsafe { &*reference };
                pairs.push(frame.pair);
                reference = frame.parent;
            }
            self.key.set(Some(key));
            self.unwind.set(self.entered.get());
        }
    }
    pub(super) fn apply(&self, key: Key) {
        if self.enabled()
            && let Some(values) = self.effects.borrow().get(&key)
        {
            self.stack.borrow_mut().clone_from(values);
        }
    }
    pub(super) fn accept(&self, values: Vec<Value>) {
        if let Some(key) = self.key.get() {
            if *self.pending.borrow() == values {
                self.effects.borrow_mut().remove(&key);
            } else {
                self.effects.borrow_mut().insert(key, values);
            }
        }
    }
    pub(super) fn rescue(&self, error: StringError) {
        if let Some(key) = self.key.get() {
            let values = self.effects.borrow().get(&key).cloned();
            if let Some(values) = values {
                self.effects.borrow_mut().insert(Key::Rescue(error), values);
            }
        }
    }
    pub(super) fn len(&self) -> usize {
        if self.key.get().is_some() {
            self.pending.borrow().len()
        } else {
            self.stack.borrow().len()
        }
    }
    pub(super) fn value(&self, index: usize) -> Value {
        if self.key.get().is_some() {
            self.pending.borrow()[index]
        } else {
            self.stack.borrow()[index]
        }
    }
    pub(super) fn unwind(&self) -> usize {
        self.unwind.replace(0)
    }
    pub(super) fn size(&self) -> usize {
        let vectors = [&self.initial, &self.stack, &self.pending]
            .iter()
            .map(|v| {
                v.try_borrow()
                    .map_or(0, |v| v.capacity() * std::mem::size_of::<Value>())
            })
            .sum::<usize>();
        let references = [
            &self.initial_references,
            &self.vm_references,
            &self.pending_references,
        ]
        .iter()
        .map(|v| {
            v.try_borrow()
                .map_or(0, |v| v.capacity() * std::mem::size_of::<(Value, Value)>())
        })
        .sum::<usize>();
        vectors
            + references
            + self.effects.try_borrow().map_or(0, |effects| {
                effects.capacity() * std::mem::size_of::<(Key, Vec<Value>)>()
                    + effects
                        .values()
                        .map(|v| v.capacity() * std::mem::size_of::<Value>())
                        .sum::<usize>()
            })
    }
}
fn values(array: Value) -> Vec<Value> {
    (0..unsafe { sn_len(array) })
        .map(|i| unsafe { sn_entry(array, i) })
        .collect()
}
/// # Safety
/// Caches must be idle. Arrays must be live and runner-rooted; active must be
/// nil or the library-owned program/instance identity Hashes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_inherit(
    caches: *const Caches,
    array: Value,
    references: Value,
    active: Value,
    enabled: i32,
) {
    unsafe { &*caches }.scopes.inherit(
        if enabled != 0 { values(array) } else { vec![] },
        enabled != 0,
    );
    if enabled != 0 {
        let scopes = &unsafe { &*caches }.scopes;
        *scopes.initial_references.borrow_mut() = (0..unsafe { sn_len(references) } / 2)
            .map(|i| unsafe { (sn_entry(references, i * 2), sn_entry(references, i * 2 + 1)) })
            .collect();
        let mut pairs = scopes.vm_references.borrow_mut();
        unsafe {
            sn_references_read(active, (&mut *pairs as *mut Vec<(Value, Value)>).cast());
        }
    }
}

/// # Safety
/// Pairs must be an exclusively borrowed reference vector; called by C's
/// allocation-free walk of library-owned identity Hashes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_reference_pair(pairs: *mut c_void, program: Value, instance: Value) {
    unsafe { &mut *pairs.cast::<Vec<(Value, Value)>>() }.push((program, instance));
}
/// # Safety
/// Caches must be idle and live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_references_len(caches: *const Caches, initial: i32) -> usize {
    unsafe { &*caches }.scopes.references(initial != 0).len() * 2
}
/// # Safety
/// Caches must be idle and index in range of sn_references_len.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_references_at(
    caches: *const Caches,
    index: usize,
    initial: i32,
) -> Value {
    let pairs = unsafe { &*caches }.scopes.references(initial != 0);
    let pair = pairs[index / 2];
    if index.is_multiple_of(2) {
        pair.0
    } else {
        pair.1
    }
}
/// # Safety
/// Caches must be idle and live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_enabled(caches: *const Caches) -> i32 {
    i32::from(unsafe { &*caches }.scopes.enabled())
}
/// # Safety
/// Caches must be idle and live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_len(caches: *const Caches) -> usize {
    unsafe { &*caches }.scopes.len()
}
/// # Safety
/// Caches must be idle and index in range of sn_scopes_len.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_at(caches: *const Caches, index: usize) -> Value {
    unsafe { &*caches }.scopes.value(index)
}
/// # Safety
/// Caches must be idle and array must retain the current Ruby scope contents.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_accept(caches: *const Caches, array: Value) {
    if unsafe { &*caches }.scopes.enabled() {
        unsafe { &*caches }.scopes.accept(values(array));
    }
}
/// # Safety
/// Caches must be idle and live. Consume only during the runner ensure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_unwind(caches: *const Caches) -> usize {
    unsafe { &*caches }.scopes.unwind()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ruby::test_value as v;

    #[test]
    fn pending_scopes_survive_native_unwind_and_replay_ruby_clears() {
        let scopes = Scopes::default();
        let key = Key::Value(v(2), v(3), RUNTIME_TYPE);
        scopes.inherit(vec![v(10)], true);
        {
            let _outer = scopes.enter(v(20), true);
            let _same = scopes.enter(v(20), true);
            scopes.request(key);
            assert_eq!(scopes.unwind(), 1);
            assert_eq!(scopes.len(), 2);
        }
        assert_eq!(scopes.at(0), Some(v(10)));
        assert_eq!(scopes.value(1), v(20));
        scopes.accept(vec![]);
        scopes.reset();
        {
            let _outer = scopes.enter(v(20), true);
            scopes.apply(key);
            assert_eq!(scopes.at(0), None);
        }
        assert_eq!(scopes.at(0), None);
    }

    #[test]
    fn reference_requests_copy_live_guards_and_keep_vm_ancestors_separate() {
        let scopes = Scopes::default();
        scopes.inherit(vec![], true);
        scopes.initial_references.borrow_mut().push((v(10), v(11)));
        scopes.vm_references.borrow_mut().push((v(20), v(21)));
        assert!(scopes.reference_active(v(10), v(11)));
        assert!(scopes.reference_active(v(20), v(21)));
        assert!(!scopes.reference_active(v(10), v(21)));
        {
            let outer = scopes.reference_frame(v(30), v(31));
            let _outer = scopes.reference_guard(&outer);
            {
                let inner = scopes.reference_frame(v(40), v(41));
                let _inner = scopes.reference_guard(&inner);
                scopes.request(Key::Value(v(2), v(3), RUNTIME_TYPE));
            }
            assert_eq!(
                *scopes.references(false),
                vec![(v(10), v(11)), (v(40), v(41)), (v(30), v(31))]
            );
        }
        assert!(scopes.reference.get().is_null());
        assert_eq!(*scopes.references(true), vec![(v(10), v(11))]);
        scopes.reset();
        assert_eq!(*scopes.references(false), vec![(v(10), v(11))]);
        scopes.clear();
        assert!(!scopes.reference_active(v(20), v(21)));
    }

    #[test]
    fn unchanged_requests_do_not_restore_a_later_mutated_scope() {
        let scopes = Scopes::default();
        let key = Key::Value(v(2), v(3), RUNTIME_TYPE);
        scopes.inherit(vec![v(10)], true);
        scopes.request(key);
        scopes.accept(vec![v(10)]);
        let _inner = scopes.enter(v(20), true);
        scopes.apply(key);
        assert_eq!(scopes.at(1), Some(v(20)));
    }
}

impl Trace for Key {
    fn trace_with(&self, visit: &mut impl FnMut(Value), mode: crate::ruby_trace::TraceMode) {
        match self {
            Self::Value(source, value, operation) => {
                source.trace_with(visit, mode);
                value.trace_with(visit, mode);
                ruby_trace::require_native(operation);
            }
            Self::Message(message) => message.trace_with(visit, mode),
            Self::Pointer(index) => ruby_trace::require_native(index),
            Self::Rescue(error) => error.trace_with(visit, mode),
        }
    }
}
// The live Reference chain points into native stack frames. Its program and
// instance handles also belong to C's rooted registry/input; never follow the
// chain from a stopped-Ractor mark callback.
ruby_trace::trace_runner_fields!(Scopes {
    key ; initial_references, vm_references, pending_references, initial, stack,
    pending, effects ; enabled, entered, unwind ; reference
});
