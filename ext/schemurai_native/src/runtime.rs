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
}
unsafe extern "C" {
    fn sn_cached_runtime(matches: *const c_void, source: Value, value: Value) -> i32;
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
    pub(super) fn invalid_regexp(&self, source: Value, value: Value) -> bool {
        let matches = self.matches.get();
        !matches.is_null() && unsafe { sn_cached_runtime(matches, source, value) } == REGEXP_INVALID
    }
    fn observe(&self, source: Value, value: Value, operation: i32) -> Verdict {
        let matches = self.matches.get();
        if !matches.is_null() {
            let cached = unsafe { sn_cached_runtime(matches, source, value) };
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
pub unsafe extern "C" fn sn_caches_size(caches: *const Caches) -> usize {
    // GC may inspect a stopped runner while its search has borrowed a cache.
    let Ok(caches) = (unsafe { &*caches }).searches.try_borrow() else {
        return std::mem::size_of::<Caches>();
    };
    std::mem::size_of::<Caches>()
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
}
/// # Safety
/// Caches must be live and called only between complete validation calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_begin(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.pending.set(None);
    caches.deadline.set(None);
    caches.runtime_order.set(false);
}
/// # Safety
/// Caches must be live and no Rust evaluation may be active.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_observe(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.pending.set(None);
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
    if let Some((source, value, _)) = unsafe { &*caches }.pending.get() {
        unsafe {
            sn_pin(source);
            sn_pin(value);
        }
    }
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
