//! Runner-owned search caches and observations requested outside Rust frames.
use super::*;
use regex_automata::{
    Input,
    meta::{Cache, Regex},
};

// Each validator owns its search caches. Compiled regex/DFA data stays shared.
#[derive(Default)]
pub struct Caches {
    searches: std::cell::RefCell<Vec<Option<Box<Cache>>>>,
    matches: std::cell::Cell<*const c_void>,
    pending: std::cell::Cell<Option<(Value, Value, i32)>>,
    deadline: std::cell::Cell<Option<std::time::Instant>>,
    runtime_order: std::cell::Cell<bool>,
    pointers: std::cell::RefCell<Pointers>,
    pending_pointer: std::cell::Cell<Option<usize>>,
}
#[derive(Default)]
struct Pointers {
    indices: HashMap<std::sync::Arc<pointer::Path>, usize>,
    requests: Vec<PointerRequest>,
}
struct PointerRequest {
    path: std::sync::Arc<pointer::Path>,
    result: Option<Value>,
}
unsafe extern "C" {
    fn sn_cached_runtime(
        matches: *const c_void,
        operation: i32,
        source: Value,
        value: Value,
    ) -> i32;
}
impl Caches {
    pub(super) fn runtime_order(&self) -> bool {
        self.runtime_order.get()
    }
    pub(super) fn budget(&self, limits: budget::Limits) -> budget::Budget {
        budget::Budget::resume(limits, &self.deadline)
    }
    pub(super) fn is_match(&self, index: usize, regex: &Regex, bytes: &[u8]) -> bool {
        // Each runner is tied to one engine, whose regex indices are fixed at
        // compilation. Allocate only the caches this validator actually uses.
        let mut caches = self.searches.borrow_mut();
        if caches.len() <= index {
            caches.resize_with(index + 1, || None);
        }
        let cache = caches[index].get_or_insert_with(|| Box::new(regex.create_cache()));
        regex
            .search_half_with(cache, &Input::new(bytes).earliest(true))
            .is_some()
    }

    pub(super) fn ruby_match(&self, source: Value, value: Value, assertion: bool) -> Verdict {
        self.observe(
            source,
            value,
            if assertion {
                RUNTIME_REGEXP_ASSERTION
            } else {
                RUNTIME_REGEXP_STRICT
            },
        )
    }
    pub(super) fn json(&self, value: Value) -> Verdict {
        // Qundef cannot be a Ruby pattern operand, including malformed schemas.
        self.observe(unsafe { sn_undefined() }, value, RUNTIME_JSON)
    }
    pub(super) fn required_missing(&self, name: Value, value: Value) -> Verdict {
        self.observe(name, value, RUNTIME_REQUIRED_MISSING)
    }
    pub(super) fn pointer(&self, path: &pointer::Path) -> Result<Value, Verdict> {
        let mut pointers = self.pointers.borrow_mut();
        let index = if let Some(&index) = pointers.indices.get(path) {
            index
        } else {
            let path = std::sync::Arc::new(path.clone());
            let index = pointers.requests.len();
            pointers.indices.insert(path.clone(), index);
            pointers
                .requests
                .push(PointerRequest { path, result: None });
            index
        };
        if let Some(value) = pointers.requests[index].result {
            return Ok(value);
        }
        self.pending_pointer.set(Some(index));
        self.pending.set(Some((
            unsafe { sn_undefined() },
            unsafe { sn_nil() },
            RUNTIME_POINTER,
        )));
        Err(Unsupported)
    }
    pub(super) fn null_number(&self, value: Value, bit: i32, decimal: bool) -> Verdict {
        self.observe(
            unsafe { sn_nil() },
            value,
            RUNTIME_NULL_NUMBER + bit * 2 + i32::from(decimal),
        )
    }
    pub(super) fn invalid_regexp(&self, source: Value, value: Value) -> bool {
        let matches = self.matches.get();
        !matches.is_null()
            && unsafe { sn_cached_runtime(matches, RUNTIME_REGEXP_ASSERTION, source, value) }
                == REGEXP_INVALID
    }
    fn observe(&self, source: Value, value: Value, operation: i32) -> Verdict {
        let matches = self.matches.get();
        if !matches.is_null() {
            let cached = unsafe { sn_cached_runtime(matches, operation, source, value) };
            if operation == RUNTIME_REGEXP_ASSERTION && cached == REGEXP_INVALID {
                return Invalid;
            }
            let result = decode(cached);
            if result != Unsupported {
                return result;
            }
        }
        self.pending.set(Some((source, value, operation)));
        Unsupported
    }
}
/// # Safety
/// Caches must be null or the currently active runner's caches, and klass one
/// of the exact identity scalar classes. No Ruby allocation is performed here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_identity_kind(caches: *const Caches, klass: Value) -> i32 {
    let Some(caches) = (unsafe { caches.as_ref() }) else {
        return TYPE_UNSUPPORTED;
    };
    match caches.observe(klass, unsafe { sn_nil() }, RUNTIME_IDENTITY_METHODS) {
        Valid => TYPE_IDENTITY_SCALAR,
        Invalid | Unsupported => TYPE_UNSUPPORTED,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn sn_caches_new() -> *mut Caches {
    Box::into_raw(Box::new(Caches::default()))
}
/// # Safety
/// Caches must be owned, returned by sn_caches_new, and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_free(caches: *mut Caches) {
    drop(unsafe { Box::from_raw(caches) });
}
/// # Safety
/// Caches must be live; call under the GVL or while all Ractors are stopped.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_size(caches_ptr: *const Caches) -> usize {
    // GC may inspect a stopped runner while its search has borrowed a cache.
    let Ok(caches) = (unsafe { &*caches_ptr }).searches.try_borrow() else {
        return std::mem::size_of::<Caches>();
    };
    let pointers = unsafe { &*caches_ptr }
        .pointers
        .try_borrow()
        .map_or(0, |pointers| {
            pointers.indices.capacity()
                * std::mem::size_of::<(std::sync::Arc<pointer::Path>, usize)>()
                + pointers.requests.capacity() * std::mem::size_of::<PointerRequest>()
                + pointers
                    .requests
                    .iter()
                    .map(|r| std::mem::size_of::<pointer::Path>() + r.path.memory_usage())
                    .sum::<usize>()
        });
    std::mem::size_of::<Caches>()
        + pointers
        + caches.capacity() * std::mem::size_of::<Option<Box<Cache>>>()
        + caches
            .iter()
            .flatten()
            .map(|cache| std::mem::size_of::<Cache>() + cache.memory_usage())
            .sum::<usize>()
}

/// # Safety
/// All pointers must be live. The C table belongs to the owning runner.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_runtime(caches: *const Caches, matches: *const c_void) {
    let caches = unsafe { &*caches };
    caches.matches.set(matches);
    caches.pending.set(None);
    caches.pending_pointer.set(None);
}
/// # Safety
/// Caches must be live and called only between complete validation calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_begin(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.pending.set(None);
    caches.pending_pointer.set(None);
    caches.deadline.set(None);
    caches.runtime_order.set(false);
    *caches.pointers.borrow_mut() = Pointers::default();
}
/// # Safety
/// Caches must be live and no Rust evaluation may be active.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_observe(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.pending.set(None);
    caches.pending_pointer.set(None);
    caches.runtime_order.set(true);
}
/// # Safety
/// Caches and output pointers must be live under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_pending(
    caches: *const Caches,
    source: *mut Value,
    value: *mut Value,
    operation: *mut i32,
) -> i32 {
    if let Some((operand, instance, kind)) = unsafe { &*caches }.pending.get() {
        unsafe {
            *source = operand;
            *value = instance;
            *operation = kind;
        }
        1
    } else {
        0
    }
}
/// # Safety
/// Call from the owning runner's GC mark callback while caches are live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_mark(caches: *const Caches) {
    // All keys also belong to the live original instance/schema. C roots every
    // completed result before recording it, including during stopped-Ractor GC.
    if let Ok(pointers) = unsafe { &*caches }.pointers.try_borrow() {
        for request in &pointers.requests {
            for &(_, key) in &request.path.names {
                unsafe { sn_pin(key) };
            }
            if let Some(value) = request.result {
                unsafe { sn_pin(value) };
            }
        }
    }

    if let Some((source, value, _)) = unsafe { &*caches }.pending.get() {
        unsafe {
            sn_pin(source);
            sn_pin(value);
        }
    }
}

/// # Safety
/// Caches must have a pending pointer request and be idle under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_pointer_parts(caches: *const Caches) -> usize {
    let caches = unsafe { &*caches };
    caches.pointers.borrow().requests[caches.pending_pointer.get().unwrap()]
        .path
        .names
        .len()
        + 1
}
/// # Safety
/// Caches must have a pending pointer request; index must be in bounds and
/// output pointers writable. Text remains owned by the request until cleanup.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_pointer_part(
    caches: *const Caches,
    index: usize,
    data: *mut *const u8,
    len: *mut usize,
    key: *mut Value,
) {
    let caches = unsafe { &*caches };
    let pointers = caches.pointers.borrow();
    let path = &pointers.requests[caches.pending_pointer.get().unwrap()].path;
    let start = if index == 0 {
        0
    } else {
        path.names[index - 1].0
    };
    let (end, name) = path
        .names
        .get(index)
        .copied()
        .unwrap_or((path.text.len(), unsafe { sn_undefined() }));
    unsafe {
        *data = path.text.as_ptr().add(start);
        *len = end - start;
        *key = name;
    }
}
/// # Safety
/// Caches must have a pending pointer request. Value must be rooted by the
/// owning C runner until cleanup, with no active Rust evaluation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_pointer_result(caches: *const Caches, value: Value) {
    let caches = unsafe { &*caches };
    caches.pointers.borrow_mut().requests[caches.pending_pointer.get().unwrap()].result =
        Some(value);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reports_memory_when_a_search_cache_is_borrowed() {
        let caches = Caches::default();
        let regex = Regex::new("value[0-9]+").unwrap();
        assert!(caches.is_match(0, &regex, b"value1"));
        assert!(unsafe { sn_caches_size(&caches) } > std::mem::size_of::<Caches>());
        let _search = caches.searches.borrow_mut();
        assert_eq!(
            unsafe { sn_caches_size(&caches) },
            std::mem::size_of::<Caches>()
        );
    }
}
