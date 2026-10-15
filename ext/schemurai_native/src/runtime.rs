//! Runner-owned search caches and observations requested outside Rust frames.
use super::*;
use regex_automata::{
    Input,
    meta::{Cache, Regex},
};
use std::collections::HashSet;

// Each validator owns its search caches. Compiled regex/DFA data stays shared.
#[derive(Default)]
pub struct Caches {
    searches: std::cell::RefCell<Vec<Option<Box<Cache>>>>,
    matches: std::cell::Cell<*const c_void>,
    pending: std::cell::Cell<Option<(Value, Value, i32)>>,
    deadline: std::cell::Cell<Option<std::time::Instant>>,
    runtime_order: std::cell::Cell<bool>,
    dynamic_calls: std::cell::Cell<bool>,
    reorder: std::cell::Cell<bool>,
    pending_rescue: std::cell::Cell<Option<StringError>>,
    rescued_strings: std::cell::RefCell<HashSet<StringError>>,
    call_cursor: std::cell::Cell<usize>,
    pointers: std::cell::RefCell<Pointers>,
    pending_pointer: std::cell::Cell<Option<usize>>,
    messages: std::cell::RefCell<HashMap<Message, Option<Value>>>,
    pending_message: std::cell::Cell<Option<Message>>,
    pending_scalar: std::cell::Cell<Option<ScalarArguments>>,
    frame_error: std::cell::Cell<bool>,
    scalar_callback: std::cell::Cell<bool>,
    callbacks_allowed: std::cell::Cell<bool>,
    pending_contains: std::cell::Cell<Option<ContainsArguments>>,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ContainsArguments {
    rules: Value,
    instance: Value,
    child: usize,
    depth: usize,
    required: i32,
    scalar_kind: i32,
    scalar_flags: i32,
}
type StringError = (Value, usize, &'static str);
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScalarArguments {
    ordinal: Value,
    rules: Value,
    instance: Value,
}
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct Message {
    ordinal: usize,
    keyword: &'static str,
    opcode: i32,
    operand: Value,
    instance: Value,
    detail: usize,
    frame: Value,
}
#[repr(C)]
pub struct MessageArguments {
    keyword: *const u8,
    keyword_len: usize,
    opcode: i32,
    operand: Value,
    instance: Value,
    detail: usize,
    frame: Value,
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
    fn sn_runtime_ordinal(ordinal: usize) -> Value;
    fn sn_cached_runtime(
        matches: *const c_void,
        operation: i32,
        source: Value,
        value: Value,
    ) -> i32;
}
impl Caches {
    fn reset_pass(&self) {
        self.pending.set(None);
        self.call_cursor.set(0);
        self.pending_pointer.set(None);
        self.pending_message.set(None);
        self.pending_scalar.set(None);
        self.pending_contains.set(None);
        self.frame_error.set(false);
        self.pending_rescue.set(None);
    }

    pub(super) fn frame_error(&self, active: bool) {
        self.frame_error.set(active);
    }
    pub(super) fn scalar_callback(&self) -> bool {
        self.scalar_callback.get()
    }
    pub(super) fn callbacks_allowed(&self) -> bool {
        self.callbacks_allowed.get()
    }
    pub(super) fn allow_callbacks(&self, allowed: bool) {
        self.callbacks_allowed.set(allowed);
    }
    pub(super) fn contains(
        &self,
        rules: Value,
        instance: Value,
        child: usize,
        depth: usize,
        required: i32,
        scalar: (i32, i32),
    ) -> Verdict {
        let Ok(ordinal) = self.next_call() else {
            return Unsupported;
        };
        let result = self.observe(ordinal, instance, RUNTIME_SCALAR_CONTAINS);
        if result == Unsupported {
            self.pending_contains.set(Some(ContainsArguments {
                rules,
                instance,
                child,
                depth,
                required,
                scalar_kind: scalar.0,
                scalar_flags: scalar.1,
            }));
        }
        result
    }
    pub(super) fn runtime_order(&self) -> bool {
        self.runtime_order.get()
    }
    pub(super) fn budget(&self, limits: budget::Limits) -> budget::Budget {
        if self.scalar_callback() {
            // These children execute shared Ruby scalar primitives. Their VM
            // checkpoints own the method boundaries; an entry/exit native
            // deadline check could preempt an exception caught by the caller's
            // Ruby block. The parent retains its native invocation deadline.
            return budget::Budget::new(budget::Limits {
                enabled: limits.enabled & !2,
                ..limits
            });
        }
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
    pub(super) fn dynamic_calls(&self) -> bool {
        self.dynamic_calls.get()
    }
    fn next_call(&self) -> Result<Value, Verdict> {
        if !self.dynamic_calls.replace(true) {
            self.reorder.set(true);
        }
        let ordinal = self.call_cursor.get();
        if ordinal > (isize::MAX >> 1) as usize {
            return Err(Unsupported);
        }
        self.call_cursor.set(ordinal + 1);
        Ok(unsafe { sn_runtime_ordinal(ordinal) })
    }
    pub(super) fn callback_checkpoint(&self, value: Value) -> Verdict {
        if !self.scalar_callback() {
            return Valid;
        }
        let Ok(ordinal) = self.next_call() else {
            return Unsupported;
        };
        self.observe(ordinal, value, RUNTIME_CALLBACK_CHECKPOINT)
    }
    pub(super) fn type_predicate(&self, value: Value, mask: i32, union: bool) -> Verdict {
        let Ok(ordinal) = self.next_call() else {
            return Unsupported;
        };
        self.observe(ordinal, value, RUNTIME_TYPE + mask * 2 + i32::from(union))
    }
    pub(super) fn number(
        &self,
        rules: Value,
        instance: Value,
        required: i32,
    ) -> Result<ScalarFrame<'_>, Verdict> {
        self.scalar(rules, instance, required, RUNTIME_NUMBER, 64)
    }
    pub(super) fn string(
        &self,
        rules: Value,
        instance: Value,
        flags: i32,
    ) -> Result<ScalarFrame<'_>, Verdict> {
        self.scalar(rules, instance, flags, RUNTIME_STRING, 256)
    }
    fn scalar(
        &self,
        rules: Value,
        instance: Value,
        required: i32,
        base: i32,
        stride: i32,
    ) -> Result<ScalarFrame<'_>, Verdict> {
        Ok(ScalarFrame {
            caches: self,
            arguments: ScalarArguments {
                ordinal: self.next_call()?,
                rules,
                instance,
            },
            required,
            base,
            stride,
        })
    }
    pub(super) fn container(
        &self,
        rules: Value,
        instance: Value,
        required: i32,
        object: bool,
    ) -> Result<ScalarFrame<'_>, Verdict> {
        self.scalar(
            rules,
            instance,
            required,
            if object {
                RUNTIME_OBJECT_HEADER
            } else {
                RUNTIME_ARRAY_HEADER
            },
            64,
        )
    }
    pub(super) fn equality(&self, operand: Value, instance: Value, operation: i32) -> Verdict {
        let Ok(ordinal) = self.next_call() else {
            return Unsupported;
        };
        let result = self.observe(ordinal, instance, operation);
        if result == Unsupported {
            self.pending_scalar.set(Some(ScalarArguments {
                ordinal,
                rules: operand,
                instance,
            }));
        }
        result
    }
    pub(super) fn required_missing(&self, name: Value, value: Value) -> Verdict {
        self.observe(name, value, RUNTIME_REQUIRED_MISSING)
    }
    pub(super) fn error_message(
        &self,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        detail: usize,
        ordinal: usize,
    ) -> Result<Value, Verdict> {
        let message = Message {
            ordinal,
            keyword,
            opcode: source.0,
            operand: source.1,
            instance,
            detail,
            frame: unsafe { sn_undefined() },
        };
        self.message(message)
    }
    pub(super) fn frame_message(
        &self,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        frame: Value,
        ordinal: usize,
        rescued: bool,
    ) -> Result<Value, Verdict> {
        self.message(Message {
            ordinal,
            keyword,
            opcode: source.0,
            operand: source.1,
            instance,
            detail: usize::from(rescued),
            frame,
        })
    }
    pub(super) fn begin_string_error(
        &self,
        frame: Value,
        ordinal: usize,
        keyword: &'static str,
    ) -> bool {
        let key = (frame, ordinal, keyword);
        if self.rescued_strings.borrow().contains(&key) {
            return false;
        }
        self.pending_rescue.set(Some(key));
        true
    }
    pub(super) fn end_string_error(&self) {
        self.pending_rescue.set(None);
    }
    fn message(&self, message: Message) -> Result<Value, Verdict> {
        if let Some(value) = self.messages.borrow_mut().entry(message).or_insert(None) {
            return Ok(*value);
        }
        self.pending_message.set(Some(message));
        self.pending.set(Some((
            unsafe { sn_undefined() },
            unsafe { sn_nil() },
            RUNTIME_DIAGNOSTIC_MESSAGE,
        )));
        Err(Unsupported)
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
pub(super) struct ScalarFrame<'a> {
    caches: &'a Caches,
    arguments: ScalarArguments,
    required: i32,
    base: i32,
    stride: i32,
}
impl ScalarFrame<'_> {
    pub(super) fn ordinal(&self) -> Value {
        self.arguments.ordinal
    }
    pub(super) fn step(&self, step: i32) -> Verdict {
        let Some(operation) = step
            .checked_mul(self.stride)
            .and_then(|step| self.base.checked_add(step))
            .and_then(|operation| operation.checked_add(self.required))
        else {
            return Unsupported;
        };
        let result =
            self.caches
                .observe(self.arguments.ordinal, self.arguments.instance, operation);
        if result == Unsupported {
            self.caches.pending_scalar.set(Some(self.arguments));
        }
        result
    }
    pub(super) fn predicate(&self, step: i32) -> Result<bool, Verdict> {
        match self.step(step) {
            Valid => Ok(true),
            Invalid => Ok(false),
            Unsupported => Err(Unsupported),
        }
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
    let messages = unsafe { &*caches_ptr }
        .messages
        .try_borrow()
        .map_or(0, |messages| {
            messages.capacity() * std::mem::size_of::<(Message, Option<Value>)>()
        });
    let rescued = unsafe { &*caches_ptr }
        .rescued_strings
        .try_borrow()
        .map_or(0, |set| set.capacity() * std::mem::size_of::<StringError>());
    std::mem::size_of::<Caches>()
        + rescued
        + messages
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
    caches.reset_pass();
}
/// # Safety
/// Caches must be live and idle under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_frame_error(caches: *const Caches) -> i32 {
    i32::from(unsafe { &*caches }.frame_error.get())
}
/// # Safety
/// Caches must be idle under the GVL. Capture only a RegexpError raised while
/// constructing a reached string error; its rescue handler must not catch again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_rescue_regexp(caches: *const Caches) -> i32 {
    let caches = unsafe { &*caches };
    if let Some(key) = caches.pending_rescue.take() {
        caches.rescued_strings.borrow_mut().insert(key);
        1
    } else {
        0
    }
}
/// # Safety
/// Caches must be live and idle under the GVL. Consume a transition to ordered
/// scalar calls before C services a request with newly assigned ordinals.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_take_reorder(caches: *const Caches) -> i32 {
    i32::from(unsafe { &*caches }.reorder.replace(false))
}
/// # Safety
/// Caches must be live and called only between complete validation calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_begin(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.reset_pass();
    caches.deadline.set(None);
    caches.runtime_order.set(false);
    caches.dynamic_calls.set(false);
    caches.scalar_callback.set(false);
    caches.callbacks_allowed.set(false);
    caches.reorder.set(false);
    caches.rescued_strings.borrow_mut().clear();
    *caches.pointers.borrow_mut() = Pointers::default();
    *caches.messages.borrow_mut() = HashMap::new();
}
/// # Safety
/// Caches must be live and no Rust evaluation may be active.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_observe(caches: *const Caches) {
    let caches = unsafe { &*caches };
    caches.reset_pass();
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
/// Both caches must be live and idle under the GVL. The parent has unwound.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_scalar_callback(caches: *const Caches, parent: *const Caches) {
    let caches = unsafe { &*caches };
    caches.deadline.set(unsafe { &*parent }.deadline.get());
    caches.scalar_callback.set(true);
    caches.dynamic_calls.set(true);
    caches.runtime_order.set(true);
}
/// # Safety
/// Caches must be live and idle under the GVL, after a Ruby scalar has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_deadline_expired(caches: *const Caches) -> i32 {
    i32::from(
        unsafe { &*caches }
            .deadline
            .get()
            .is_some_and(|deadline| std::time::Instant::now() >= deadline),
    )
}
/// # Safety
/// Caches must hold a pending contains request and output must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_contains_arguments(
    caches: *const Caches,
    output: *mut ContainsArguments,
) {
    unsafe {
        *output = (&*caches)
            .pending_contains
            .get()
            .expect("pending contains callback")
    };
}
/// # Safety
/// Call from the owning runner's GC mark callback while caches are live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_mark(caches: *const Caches) {
    if let Some(arguments) = unsafe { &*caches }.pending_contains.get() {
        unsafe {
            sn_pin(arguments.rules);
            sn_pin(arguments.instance);
        }
    }
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

    if let Ok(messages) = unsafe { &*caches }.messages.try_borrow() {
        for (message, result) in messages.iter() {
            unsafe {
                sn_pin(message.operand);
                sn_pin(message.instance);
                if let Some(value) = result {
                    sn_pin(*value);
                }
            }
        }
    }
    if let Some(scalar) = unsafe { &*caches }.pending_scalar.get() {
        unsafe {
            sn_pin(scalar.rules);
            sn_pin(scalar.instance);
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

/// # Safety
/// Caches must have a pending message and the output pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_message_arguments(
    caches: *const Caches,
    output: *mut MessageArguments,
) {
    let message = unsafe { &*caches }.pending_message.get().unwrap();
    unsafe {
        *output = MessageArguments {
            keyword: message.keyword.as_ptr(),
            keyword_len: message.keyword.len(),
            opcode: message.opcode,
            operand: message.operand,
            instance: message.instance,
            detail: message.detail,
            frame: message.frame,
        };
    }
}
/// # Safety
/// Caches must have a pending message with no active Rust evaluation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_message_result(caches: *const Caches, result: Value) {
    let caches = unsafe { &*caches };
    caches
        .messages
        .borrow_mut()
        .insert(caches.pending_message.get().unwrap(), Some(result));
}

/// # Safety
/// Caches must have a pending scalar request and output must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_scalar_arguments(caches: *const Caches, output: *mut ScalarArguments) {
    unsafe {
        *output = (&*caches).pending_scalar.get().unwrap();
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
