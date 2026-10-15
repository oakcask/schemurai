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
    pub(super) fn request(&self, key: Key) {
        if self.enabled() {
            self.pending.borrow_mut().clone_from(&self.stack.borrow());
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
        vectors
            + self.effects.try_borrow().map_or(0, |effects| {
                effects.capacity() * std::mem::size_of::<(Key, Vec<Value>)>()
                    + effects
                        .values()
                        .map(|v| v.capacity() * std::mem::size_of::<Value>())
                        .sum::<usize>()
            })
    }
    pub(super) fn mark(&self) {
        // A stopped native pass may hold a scope-vector borrow. Resources also
        // belong to the compiled registry; C roots completed request keys.
        for values in [&self.initial, &self.stack, &self.pending] {
            if let Ok(values) = values.try_borrow() {
                for &value in values.iter() {
                    unsafe { sn_pin(value) };
                }
            }
        }
        if let Ok(effects) = self.effects.try_borrow() {
            for (key, values) in effects.iter() {
                match *key {
                    Key::Value(source, value, _) => unsafe {
                        sn_pin(source);
                        sn_pin(value);
                    },
                    Key::Message(m) => unsafe {
                        sn_pin(m.operand);
                        sn_pin(m.instance);
                        sn_pin(m.frame);
                    },
                    Key::Rescue((frame, _, _)) => unsafe {
                        sn_pin(frame);
                    },
                    Key::Pointer(_) => {}
                }
                for &value in values {
                    unsafe { sn_pin(value) };
                }
            }
        }
    }
}
fn values(array: Value) -> Vec<Value> {
    (0..unsafe { sn_len(array) })
        .map(|i| unsafe { sn_entry(array, i) })
        .collect()
}
/// # Safety
/// Caches must be idle and array must be a live Array rooted by the runner.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scopes_inherit(caches: *const Caches, array: Value, enabled: i32) {
    unsafe { &*caches }.scopes.inherit(
        if enabled != 0 { values(array) } else { vec![] },
        enabled != 0,
    );
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

    #[test]
    fn pending_scopes_survive_native_unwind_and_replay_ruby_clears() {
        let scopes = Scopes::default();
        let key = Key::Value(2, 3, RUNTIME_TYPE);
        scopes.inherit(vec![10], true);
        {
            let _outer = scopes.enter(20, true);
            let _same = scopes.enter(20, true);
            scopes.request(key);
            assert_eq!(scopes.unwind(), 1);
            assert_eq!(scopes.len(), 2);
        }
        assert_eq!(scopes.at(0), Some(10));
        assert_eq!(scopes.value(1), 20);
        scopes.accept(vec![]);
        scopes.reset();
        {
            let _outer = scopes.enter(20, true);
            scopes.apply(key);
            assert_eq!(scopes.at(0), None);
        }
        assert_eq!(scopes.at(0), None);
    }

    #[test]
    fn unchanged_requests_do_not_restore_a_later_mutated_scope() {
        let scopes = Scopes::default();
        let key = Key::Value(2, 3, RUNTIME_TYPE);
        scopes.inherit(vec![10], true);
        scopes.request(key);
        scopes.accept(vec![10]);
        let _inner = scopes.enter(20, true);
        scopes.apply(key);
        assert_eq!(scopes.at(1), Some(20));
    }
}
