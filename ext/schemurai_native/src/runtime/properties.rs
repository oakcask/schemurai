//! Immutable property-set results for annotation merges that require Ruby hashing.
use super::*;
use crate::tracking::{PropertyLocations, Tracked};
use std::cell::RefCell;

#[derive(Default)]
pub(super) struct Properties {
    pending: RefCell<Option<(Value, [PropertyLocations; 2])>>,
    completed: RefCell<HashMap<Value, (Value, usize)>>,
}
impl Properties {
    pub(super) fn reset(&self) {
        self.pending.borrow_mut().take();
    }
    pub(super) fn clear(&self) {
        self.reset();
        *self.completed.borrow_mut() = HashMap::new();
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.pending.try_borrow().map_or(0, |pending| {
            pending.as_ref().map_or(0, |(_, parts)| {
                parts.iter().map(|part| part.memory_usage()).sum::<usize>()
            })
        }) + self.completed.try_borrow().map_or(0, |results| {
            results.capacity() * std::mem::size_of::<(Value, (Value, usize))>()
        })
    }
    pub(super) fn mark(&self) {
        if let Ok(pending) = self.pending.try_borrow()
            && let Some((_, parts)) = &*pending
        {
            for part in parts {
                part.mark();
            }
        }
        if let Ok(completed) = self.completed.try_borrow() {
            for &(set, _) in completed.values() {
                unsafe {
                    sn_pin(set);
                }
            }
        }
    }
}
impl Caches {
    pub(crate) fn merge_properties(
        &self,
        engine: &Engine,
        left: &Tracked,
        right: &Tracked,
    ) -> Result<(Value, usize), Verdict> {
        let ordinal = self.next_call()?;
        if self.observe(ordinal, unsafe { sn_nil() }, RUNTIME_PROPERTY_MERGE) == Unsupported {
            *self.properties.pending.borrow_mut() = Some((
                ordinal,
                [
                    PropertyLocations::new(engine, left),
                    PropertyLocations::new(engine, right),
                ],
            ));
            return Err(Unsupported);
        }
        self.properties
            .completed
            .borrow()
            .get(&ordinal)
            .copied()
            .ok_or(Unsupported)
    }
}
/// # Safety
/// Caches must be idle with a pending merge; side is 0 or 1 and outputs writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_part(
    caches: *const Caches,
    side: usize,
    set: *mut Value,
    count: *mut usize,
) {
    let pending = unsafe { &*caches }.properties.pending.borrow();
    let part = &pending.as_ref().expect("property merge").1[side];
    unsafe {
        *set = part.set.unwrap_or_else(|| sn_nil());
        *count = part.keys.len();
    }
}
/// # Safety
/// Same pending merge requirements as sn_properties_part; index is in bounds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_key(
    caches: *const Caches,
    side: usize,
    index: usize,
) -> Value {
    unsafe { &*caches }
        .properties
        .pending
        .borrow()
        .as_ref()
        .expect("property merge")
        .1[side]
        .keys[index]
}
/// # Safety
/// Caches are idle; set is rooted in C's completed roots and count is its size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_result(caches: *const Caches, set: Value, count: usize) {
    let properties = &unsafe { &*caches }.properties;
    let ordinal = properties
        .pending
        .borrow()
        .as_ref()
        .expect("property merge")
        .0;
    properties
        .completed
        .borrow_mut()
        .insert(ordinal, (set, count));
}
