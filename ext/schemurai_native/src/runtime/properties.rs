//! Opaque evaluation buffers for annotation merges that require Ruby semantics.
use super::*;
use crate::tracking::{RuntimeLocations, Tracked};
use std::cell::RefCell;

struct Part {
    runtime: Option<RuntimeLocations>,
    keys: Vec<Value>,
    items: Vec<usize>,
}
impl Part {
    fn new(engine: &Engine, tracked: &Tracked) -> Self {
        Self {
            runtime: tracked.runtime_locations(),
            keys: tracked.native_properties(engine),
            items: tracked.native_items(),
        }
    }

    fn memory_usage(&self) -> usize {
        self.keys.capacity() * std::mem::size_of::<Value>()
            + self.items.capacity() * std::mem::size_of::<usize>()
    }
}
#[derive(Default)]
pub(super) struct Properties {
    pending: RefCell<Option<(Value, [Part; 2])>>,
    completed: RefCell<HashMap<Value, RuntimeLocations>>,
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
                parts.iter().map(Part::memory_usage).sum::<usize>()
            })
        }) + self.completed.try_borrow().map_or(0, |results| {
            results.capacity() * std::mem::size_of::<(Value, RuntimeLocations)>()
        })
    }
}
impl Caches {
    pub(crate) fn merge_properties(
        &self,
        engine: &Engine,
        left: &Tracked,
        right: &Tracked,
    ) -> Result<RuntimeLocations, Verdict> {
        let ordinal = self.next_call()?;
        if self.observe(ordinal, unsafe { sn_nil() }, RUNTIME_PROPERTY_MERGE) == Unsupported {
            *self.properties.pending.borrow_mut() =
                Some((ordinal, [Part::new(engine, left), Part::new(engine, right)]));
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
/// Caches are idle with a pending merge. Side is 0/1 and outputs are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_part(
    caches: *const Caches,
    side: usize,
    properties: *mut usize,
    items: *mut usize,
) -> Value {
    let pending = unsafe { &*caches }.properties.pending.borrow();
    let part = &pending.as_ref().expect("property merge").1[side];
    unsafe {
        *properties = part.keys.len();
        *items = part.items.len();
    }
    part.runtime
        .map_or_else(|| unsafe { sn_nil() }, |runtime| runtime.buffer)
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
/// Same pending merge requirements as sn_properties_part; index is in bounds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_item(
    caches: *const Caches,
    side: usize,
    index: usize,
) -> usize {
    unsafe { &*caches }
        .properties
        .pending
        .borrow()
        .as_ref()
        .expect("property merge")
        .1[side]
        .items[index]
}
/// # Safety
/// Caches are idle; locations is readable and all handles are rooted by C first.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_properties_result(
    caches: *const Caches,
    locations: *const RuntimeLocations,
) {
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
        .insert(ordinal, unsafe { *locations });
}

trace_fields!(Part { runtime, keys ; items });
ruby_trace::trace_runner_fields!(Properties { ; pending, completed ; ; });
