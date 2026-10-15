//! A VM over borrowed CRuby VALUE handles. No instance decoding or serialization.
//! Ruby runs with the GVL held. Evaluation calls only non-allocating C adapters;
//! Ruby callbacks during compilation are protected on the C side.
use std::collections::HashMap;
use std::ffi::{c_char, c_void};
use std::hash::{BuildHasherDefault, Hasher};
use std::panic::{AssertUnwindSafe, catch_unwind};
mod budget;
mod content;
mod diagnostics;
mod enumeration;
mod evaluation;
mod format;
mod graph;
mod instance_graph;
mod integer_scan;
mod memo;
mod memo_scope;
mod number;
mod pattern;
// Some shared constants are consumed only by C or Ruby.
#[allow(dead_code)]
mod protocol {
    include!(concat!(env!("OUT_DIR"), "/protocol.rs"));
}
use protocol::*;
mod scope;
mod structural;
mod tracking;
type Value = usize;
unsafe extern "C" {
    fn sn_pin(value: Value);
    fn sn_nil() -> Value;
    fn sn_undefined() -> Value;
    fn sn_kind(value: Value) -> i32;
    fn sn_shallow_kind(value: Value) -> i32;
    fn sn_fingerprint_view(
        value: Value,
        data: *mut *const c_void,
        length: *mut usize,
        number: *mut f64,
    ) -> i32;
    fn sn_small_hash(value: Value, entries: *mut Value) -> i32;
    fn sn_true(value: Value) -> i32;
    fn sn_fixnum(value: Value) -> i32;
    fn sn_fixnum_flag() -> Value;
    fn sn_array_data(value: Value) -> *const Value;
    fn sn_integer(value: Value) -> i64;
    fn sn_integer128(value: Value, words: *mut u64) -> i32;
    fn sn_integer_bounds128(value: Value, words: *mut u64) -> i32;
    fn sn_number_bounds_view(
        value: Value,
        words: *mut u64,
        kind: *mut i32,
        floating: *mut f64,
        required: i32,
    ) -> i32;
    fn sn_integer1024(value: Value, words: *mut u64) -> i32;
    fn sn_integer_word_count(value: Value) -> usize;
    fn sn_integer_words(value: Value, words: *mut u64, count: usize);
    fn sn_is_bignum(value: Value) -> i32;
    fn sn_big256(value: Value, words: *mut u64) -> i32;
    fn sn_big_hash(value: Value, hash: *mut u64) -> i32;
    fn sn_big_low_word(value: Value) -> u64;
    fn sn_big_low64_word(value: Value, word: *mut u64) -> i32;
    fn sn_big_equal(big: Value, other: Value) -> i32;
    fn sn_big_order(left: Value, right: Value) -> i32;
    fn sn_wide_integer_compare(value: Value, bound: Value) -> i32;
    fn sn_float(value: Value) -> f64;
    fn sn_is_float(value: Value) -> i32;
    fn sn_is_rational(value: Value) -> i32;
    fn sn_len(value: Value) -> usize;
    fn sn_entry(value: Value, index: usize) -> Value;
    fn sn_lookup(hash: Value, key: Value) -> Value;
    fn sn_missing(value: Value) -> i32;
    fn sn_same(a: Value, b: Value) -> i32;
    fn sn_same_class(a: Value, b: Value) -> i32;
    fn sn_string_data(value: Value) -> *const u8;
    fn sn_string_bytes(value: Value) -> usize;
    fn sn_string_equal(a: Value, b: Value) -> i32;
    fn sn_string_length_guarded(value: Value, length: *mut usize) -> i32;
    fn sn_record_key_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_string_raw_view(value: Value, data: *mut *const u8, length: *mut usize);
    fn sn_string_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_pattern_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_pattern_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_format_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_json_encoding(value: Value) -> i32;
    fn sn_json_item_view(value: Value, data: *mut *const u8, length: *mut usize) -> i32;
    fn sn_resolve(compiler: Value, program: Value, reference: Value, result: *mut Value) -> i32;
    fn sn_resolution_error(error: Value) -> i32;
    fn sn_resource_program(compiler: Value, resource: Value, result: *mut Value) -> i32;
    fn sn_anchor_count(resource: Value) -> usize;
    fn sn_anchor_names(compiler: Value, resource: Value, result: *mut Value) -> i32;
    fn sn_anchor_program(compiler: Value, resource: Value, name: Value, result: *mut Value) -> i32;
    fn sn_hash_each(
        value: Value,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void, Value, Value) -> i32,
    ) -> i32;
    fn sn_hash_each_key_view(
        value: Value,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void, *const u8, usize, Value) -> i32,
    ) -> i32;
    fn sn_field(object: Value, name: *const c_char, value: *mut Value) -> i32;
    fn sn_pairs(hash: Value, value: *mut Value) -> i32;
    fn sn_key_copy(key: Value, value: *mut Value) -> i32;
    fn sn_opcode(symbol: Value) -> i32;
    fn sn_object_each(value: Value, context: *mut c_void) -> i32;
}
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(i32)]
enum Verdict {
    Invalid = VERDICT_INVALID,
    Valid = VERDICT_VALID,
    Unsupported = VERDICT_UNSUPPORTED,
}
use Verdict::*;
const MAX_EVALUATION_DEPTH: usize = 256;
const MAX_UNIQUE_INDEX_BYTES: usize = 64 * 1024 * 1024;
#[derive(Debug)]
enum Op {
    Unsupported,
    Boolean(bool),
    Ref(scope::Reference),
    Type(i32),
    Const(Value),
    Enum(Box<enumeration::Enumeration>),
    All(Vec<usize>),
    Any(Vec<(usize, usize)>),
    One(Vec<(usize, usize)>),
    Not(usize),
    Conditional(usize, Option<usize>, Option<usize>),
    Number(i32, Box<number::Rules>),
    String(i32, Box<StringRules>),
    Array(i32, Box<Array>),
    Object(i32, Box<Object>),
}
#[derive(Debug)]
struct Array {
    min: Option<usize>,
    max: Option<usize>,
    unique: bool,
    prefix: Vec<usize>,
    items: Vec<usize>,
    list: bool,
    additional: Option<usize>,
    contains: Option<usize>,
    min_contains: usize,
    max_contains: Option<usize>,
    unevaluated: Option<usize>,
}
#[derive(Debug)]
struct StringRules {
    min: Option<usize>,
    max: Option<usize>,
    pattern: Option<pattern::Pattern>,
    format: Option<format::Format>,
    content: Option<content::Content>,
}
impl StringRules {
    fn content_only(&self) -> Option<&content::Content> {
        if self.min.is_none()
            && self.max.is_none()
            && self.pattern.is_none()
            && self.format.is_none()
        {
            self.content.as_ref()
        } else {
            None
        }
    }
    fn format_only(&self) -> Option<&format::Format> {
        if self.min.is_none()
            && self.max.is_none()
            && self.pattern.is_none()
            && self.content.is_none()
        {
            self.format.as_ref()
        } else {
            None
        }
    }
    fn pattern_only(&self) -> Option<&pattern::Pattern> {
        if self.min.is_none()
            && self.max.is_none()
            && self.format.is_none()
            && self.content.is_none()
        {
            self.pattern.as_ref()
        } else {
            None
        }
    }
    fn length_only(&self) -> bool {
        (self.min.is_some() || self.max.is_some())
            && self.pattern.is_none()
            && self.format.is_none()
            && self.content.is_none()
    }
    fn eval_length_guarded(&self, required: i32, value: Value) -> Verdict {
        length_guarded(value, required, self.min, self.max)
    }
    fn eval_guarded(&self, caches: &pattern::Caches, required: i32, value: Value) -> Verdict {
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_pattern_item_view(value, &mut data, &mut len) };
        if encoding == -TYPE_UNSUPPORTED {
            Unsupported
        } else if encoding < 0 {
            verdict(required == 0)
        } else {
            let bytes = unsafe { byte_view(data, len) };
            self.eval_with_view::<true>(caches, value, Some((bytes, encoding)))
        }
    }
    fn eval(&self, caches: &pattern::Caches, value: Value) -> Verdict {
        self.eval_with_view::<false>(caches, value, None)
    }
    fn eval_with_view<const BORROWED: bool>(
        &self,
        caches: &pattern::Caches,
        value: Value,
        view: Option<(&[u8], i32)>,
    ) -> Verdict {
        // Specialize the standalone path so diagnostics and ordinary string
        // checks do not dispatch through borrowed-view branches at runtime.
        let view = if BORROWED { view } else { None };
        if (self.min.is_some() || self.max.is_some())
            && bounds(unsafe { sn_len(value) }, self.min, self.max) == Invalid
        {
            return Invalid;
        }
        if let Some(pattern) = &self.pattern {
            let result = match view {
                Some((bytes, encoding)) => pattern.eval_bytes(caches, bytes, encoding),
                None => pattern.eval(caches, value),
            };
            if result != Valid {
                return result;
            }
        }
        if let Some(format) = &self.format {
            let result = match view {
                Some((bytes, _)) => format.eval_bytes(bytes),
                None => format.eval(value),
            };
            if result != Valid {
                return result;
            }
        }
        self.content.as_ref().map_or(Valid, |content| match view {
            Some((bytes, encoding)) => content.eval_borrowed(value, bytes, encoding),
            None => content.eval(value),
        })
    }
}
#[derive(Debug)]
enum DiagnosticDependency {
    Required(Value, Vec<Value>, &'static str),
    Schema(Value, usize, &'static str),
}
#[derive(Clone, Copy, Debug)]
struct PropertyTarget {
    name: Value,
    child: usize,
    index: usize,
}
#[derive(Debug)]
struct Object {
    record: Option<RecordObject>,
    min: Option<usize>,
    max: Option<usize>,
    required: Vec<Value>,
    required_order: Vec<Value>,
    properties: Vec<(Value, usize)>,
    property_targets: HashMap<tracking::JsonKey, PropertyTarget, BuildHasherDefault<BucketHasher>>,
    patterns: Vec<(pattern::Pattern, usize)>,
    pattern_names: Vec<Value>,
    pattern_group: Option<pattern::PatternGroup>,
    required_properties: Vec<bool>,
    required_property_indices: Vec<usize>,
    property_keys: tracking::KeySet,
    property_indices: Vec<usize>,
    additional: Option<usize>,
    names: Option<usize>,
    dependent_required: Vec<(Value, Vec<Value>)>,
    dependent_schemas: Vec<(Value, usize)>,
    diagnostic_dependencies: Vec<DiagnosticDependency>,
    unevaluated: Option<usize>,
}
#[derive(Clone, Copy, Debug)]
struct RecordField {
    key: Value,
    name: Value,
    short_key: ShortRecordKey,
    child: Option<usize>,
    bit: u64,
    check: Option<RecordCheck>,
}
#[derive(Clone, Copy, Debug)]
enum RecordCheck {
    IntegerBounds(i64, i64),
    StringLength(i32, Option<usize>, Option<usize>),
}
#[derive(Debug)]
struct RecordObject {
    fields: Vec<RecordField>,
    short_index: Option<RecordShortIndex>,
    // Immutable schema handle, used only to choose a lookup strategy.
    identity_hint: Value,
    required: u64,
}
#[derive(Debug)]
struct RecordShortIndex {
    slots: [u8; 16],
    shift: u8,
}
impl RecordShortIndex {
    fn compile(fields: &[RecordField]) -> Option<Self> {
        if !(4..=8).contains(&fields.len()) || fields.iter().any(|field| field.short_key.tag == 0) {
            return None;
        }
        for shift in 0..=60 {
            // Use a four-bit window only if every compiled key owns a distinct
            // slot. Unknown input keys still undergo full equality checks.
            let mut index = Self {
                slots: [0; 16],
                shift,
            };
            let mut unique = true;
            for (at, field) in fields.iter().enumerate() {
                let slot = index.slot(field.short_key);
                if index.slots[slot] != 0 {
                    unique = false;
                    break;
                }
                index.slots[slot] = at as u8 + 1;
            }
            if unique {
                return Some(index);
            }
        }
        None
    }
    fn slot(&self, key: ShortRecordKey) -> usize {
        // Encoding is excluded: equal ASCII keys may have compatible but
        // different encodings. Exact byte/length/encoding checks follow lookup.
        let word = key.word ^ (key.tag & 15).wrapping_mul(0x9e3779b97f4a7c15);
        ((word >> self.shift) & 15) as usize
    }
}
impl Object {
    // Keep these calls at their original evaluation positions: property
    // failures and unsupported children must retain their ordering.
    fn check_required(&self, value: Value, undefined: Value, budget: &budget::Budget) -> Verdict {
        Self::check_keys(&self.required, value, undefined, budget)
    }
    fn check_keys(
        keys: &[Value],
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        for &key in keys {
            if !budget.checkpoint() {
                return Unsupported;
            }
            if missing(value, key, undefined) {
                return Invalid;
            }
        }
        Valid
    }
    fn check_dependent_required(
        &self,
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        for (name, required) in &self.dependent_required {
            if !budget.checkpoint() {
                return Unsupported;
            }
            if !missing(value, *name, undefined) {
                let status = Self::check_keys(required, value, undefined, budget);
                if status != Valid {
                    return status;
                }
            }
        }
        Valid
    }
    fn visit_properties(
        &self,
        value: Value,
        len: usize,
        undefined: Value,
        budget: &budget::Budget,
        mut visit: impl FnMut(usize, usize, Value) -> Verdict,
    ) -> Result<usize, Verdict> {
        let mut found = 0;
        if self.properties.len() > len.saturating_mul(4).max(8)
            && self.property_targets.len() == self.properties.len()
        {
            // Discover only present schema fields, then retain schema order for
            // validity, including required failures and unsupported children.
            let mut candidates = PropertyCandidates {
                rules: self,
                budget,
                indices: Vec::with_capacity(len.min(self.properties.len())),
            };
            let status = decode(unsafe {
                sn_hash_each(
                    value,
                    (&mut candidates as *mut PropertyCandidates).cast(),
                    property_candidate,
                )
            });
            if status != Valid {
                return Err(status);
            }
            candidates.indices.sort_unstable();
            candidates.indices.dedup();
            let mut missing_required = None;
            for &index in &self.required_property_indices {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                if missing(value, self.properties[index].0, undefined) {
                    missing_required = Some(index);
                    break;
                }
            }
            for index in candidates.indices {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                if missing_required.is_some_and(|missing| missing <= index) {
                    return Err(Invalid);
                }
                let (key, child) = self.properties[index];
                // Use the schema handle for the final lookup to retain identity
                // Hash semantics, even when an equal input key found the index.
                let item = unsafe { sn_lookup(value, key) };
                if item == undefined {
                    continue;
                }
                found += 1;
                match visit(index, child, item) {
                    Valid => {}
                    status => return Err(status),
                }
            }
            if missing_required.is_some() {
                return Err(Invalid);
            }
        } else {
            for (index, &(key, child)) in self.properties.iter().enumerate() {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                let item = unsafe { sn_lookup(value, key) };
                if item == undefined {
                    if self.required_properties[index] {
                        return Err(Invalid);
                    }
                    continue;
                }
                found += 1;
                match visit(index, child, item) {
                    Valid => {}
                    status => return Err(status),
                }
            }
        }
        Ok(found)
    }

    // All execution policies use the same property/pattern/additional routing.
    // Schema-order validity scans have already visited declared properties;
    // input-order diagnostic scans visit them here as well.
    fn visit_value_rules<const PROPERTIES: bool>(
        &self,
        caches: &pattern::Caches,
        budget: &budget::Budget,
        key: Value,
        location: Option<tracking::JsonKey>,
        mut visit: impl FnMut(&'static str, Option<Value>, usize) -> Result<(), Verdict>,
    ) -> Result<bool, Verdict> {
        // Tracked scans already fingerprinted this key for location lookup.
        // Reuse that result, and skip hashing for pattern-only object rules.
        let mut matched = if self.properties.is_empty() {
            false
        } else if PROPERTIES {
            if let Some(target) = self
                .property_targets
                .get(&location.unwrap_or_else(|| tracking::JsonKey::new(key)))
            {
                visit("properties", Some(target.name), target.child)?;
                true
            } else {
                false
            }
        } else {
            self.property_keys
                .contains(&location.unwrap_or_else(|| tracking::JsonKey::new(key)))
        };
        if let Some(mut matches) = self
            .pattern_group
            .as_ref()
            .and_then(|group| group.matches(key))
        {
            while matches != 0 {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                let index = matches.trailing_zeros() as usize;
                matches &= matches - 1;
                matched = true;
                visit(
                    "patternProperties",
                    Some(self.pattern_names[index]),
                    self.patterns[index].1,
                )?;
            }
        } else {
            for ((pattern, child), &name) in self.patterns.iter().zip(&self.pattern_names) {
                if !budget.checkpoint() {
                    return Err(Unsupported);
                }
                match pattern.eval(caches, key) {
                    Unsupported => return Err(Unsupported),
                    Invalid => {}
                    Valid => {
                        matched = true;
                        visit("patternProperties", Some(name), *child)?;
                    }
                }
            }
        }
        if !matched && let Some(child) = self.additional {
            visit("additionalProperties", None, child)?;
        }
        Ok(matched || self.additional.is_some())
    }

    fn with_record(mut self) -> Self {
        if self.required_order.len() > 64
            || !self.patterns.is_empty()
            || self.names.is_some()
            || !self.diagnostic_dependencies.is_empty()
            || self.unevaluated.is_some()
        {
            return self;
        }
        let mut fields: HashMap<_, _, BuildHasherDefault<BucketHasher>> = self
            .properties
            .iter()
            .map(|&(name, child)| {
                (
                    tracking::JsonKey::new(name),
                    RecordField {
                        key: name,
                        name,
                        short_key: short_record_key(name),
                        child: Some(child),
                        bit: 0,
                        check: None,
                    },
                )
            })
            .collect();
        for &name in &self.required_order {
            fields
                .entry(tracking::JsonKey::new(name))
                .or_insert(RecordField {
                    key: name,
                    name,
                    short_key: short_record_key(name),
                    child: None,
                    bit: 0,
                    check: None,
                });
        }
        if fields.len() > 8 {
            return self;
        }
        for (index, field) in fields.values_mut().enumerate() {
            field.bit = 1_u64 << index;
        }
        // Required names share the field bits already used for duplicate-key
        // detection. Repeated required names therefore need no extra state.
        let required = self.required_order.iter().fold(0, |bits, &name| {
            bits | fields[&tracking::JsonKey::new(name)].bit
        });
        let fields: Vec<_> = fields.into_values().collect();
        let short_index = RecordShortIndex::compile(&fields);
        self.record = Some(RecordObject {
            identity_hint: self.properties.first().map_or(0, |&(key, _)| key),
            fields,
            short_index,
            required,
        });
        self
    }
}
#[derive(Default)]
pub struct Roots {
    values: Vec<Value>,
    binding_names: Vec<Value>,
}
#[derive(Default)]
pub struct Engine {
    nodes: Vec<Vec<Op>>,
    pattern_cache_count: usize,
    error_operands: Vec<Vec<(i32, Value)>>,
    tracks: Vec<bool>,
    memoizable: Vec<bool>,
    memo_contextual: Vec<bool>,
    memo_guarded: Vec<bool>,
    memo_guard_sources: Vec<bool>,
    memo_guard_same_sources: Vec<bool>,
    memo_guard_scalar_sources: Vec<bool>,
    memo_guard_scalar_amplification: Vec<bool>,
    memo_scope_projection: memo_scope::Projection,
    metadata: Vec<scope::Metadata>,
    resources: HashMap<Value, usize>,
    dynamic_bindings: HashMap<(Value, usize), usize>,
    anchor_names: Vec<tracking::JsonKey>,
    anchor_ids: HashMap<tracking::JsonKey, usize, BuildHasherDefault<BucketHasher>>,
    anchor_tables: Vec<Vec<(Value, usize)>>,
    property_ids: HashMap<tracking::JsonKey, usize, BuildHasherDefault<BucketHasher>>,
    indices: HashMap<Value, usize>,
    roots: *mut Roots,
    root: usize,
    fixnum_flag: Value,
    compiler: Value,
    validate_format: bool,
    validate_content: bool,
    undefined: Value,
}
impl Engine {
    fn retain(&mut self, value: Value) -> Value {
        // A separate allocation lets GC mark roots without aliasing the
        // compiler's exclusive Engine reference. This borrow ends before any
        // allocating Ruby call; Vec growth uses the Rust allocator only.
        unsafe { &mut *self.roots }.values.push(value);
        value
    }
    fn field(&mut self, value: Value, name: &'static [u8]) -> Result<Value, Value> {
        let mut result = 0;
        if unsafe { sn_field(value, name.as_ptr().cast(), &mut result) } != 0 {
            return Err(result);
        }
        Ok(self.retain(result))
    }
    fn values(&mut self, value: Value) -> Vec<Value> {
        if unsafe { sn_same(value, sn_nil()) } != 0 {
            return vec![];
        }
        (0..unsafe { sn_len(value) })
            .map(|i| {
                let item = unsafe { sn_entry(value, i) };
                self.retain(item)
            })
            .collect()
    }
    fn map(&mut self, value: Value) -> Result<Vec<(Value, Value)>, Value> {
        if unsafe { sn_same(value, sn_nil()) } != 0 {
            return Ok(vec![]);
        }
        let mut pairs = 0;
        if unsafe { sn_pairs(value, &mut pairs) } != 0 {
            return Err(pairs);
        }
        self.retain(pairs);
        Ok(self
            .values(pairs)
            .as_chunks::<2>()
            .0
            .iter()
            .map(|p| (p[0], p[1]))
            .collect())
    }
    fn size_field(&mut self, value: Value, name: &'static [u8]) -> Result<Option<usize>, Value> {
        let n = self.field(value, name)?;
        Ok(if unsafe { sn_same(n, sn_nil()) } != 0 {
            None
        } else if unsafe { sn_fixnum(n) } != 0 {
            Some(unsafe { sn_integer(n) } as usize)
        } else if unsafe { sn_is_float(n) } != 0 {
            // Count keywords allow integral JSON numbers such as 2.0.
            // Saturation is exact for comparisons against representable lengths.
            Some(unsafe { sn_float(n) } as usize)
        } else if unsafe { sn_kind(n) } & TYPE_INTEGER != 0 {
            Some(usize::MAX)
        } else {
            None // The only non-integral bound is maxContains' +Infinity.
        })
    }
    fn child(&mut self, value: Value, name: &'static [u8]) -> Result<Option<usize>, Value> {
        let child = self.field(value, name)?;
        if unsafe { sn_same(child, sn_nil()) } != 0 {
            Ok(None)
        } else {
            self.compile(child).map(Some)
        }
    }
    fn children(&mut self, value: Value) -> Result<Vec<usize>, Value> {
        self.values(value)
            .into_iter()
            .map(|c| self.compile(c))
            .collect()
    }
    fn branches(&mut self, value: Value) -> Result<Vec<(usize, usize)>, Value> {
        let nodes = self.children(value)?;
        let mut groups: Vec<(usize, usize)> = Vec::with_capacity(nodes.len());
        for node in nodes {
            if let Some(group) = groups
                .last_mut()
                .filter(|(prior, _)| *prior == node || self.same_simple_object(*prior, node))
            {
                group.1 += 1;
            } else {
                groups.push((node, 1));
            }
        }
        Ok(groups)
    }
    fn same_simple_object(&self, a: usize, b: usize) -> bool {
        let ([Op::Object(required_a, a)], [Op::Object(required_b, b)]) =
            (self.nodes[a].as_slice(), self.nodes[b].as_slice())
        else {
            return false;
        };
        let simple = |r: &Object| {
            r.patterns.is_empty()
                && r.additional.is_none()
                && r.names.is_none()
                && r.dependent_required.is_empty()
                && r.dependent_schemas.is_empty()
                && r.unevaluated.is_none()
        };
        required_a == required_b
            && simple(a)
            && simple(b)
            && a.min == b.min
            && a.max == b.max
            && a.required == b.required
            && a.required_properties == b.required_properties
            && a.properties.len() == b.properties.len()
            && a.properties
                .iter()
                .zip(&b.properties)
                .all(|(&(ka, ca), &(kb, cb))| {
                    // Exact key handles also preserve identity-Hash lookups. Only
                    // shape-independent leaves can ignore resource/path metadata.
                    ka == kb
                        && match (self.nodes[ca].as_slice(), self.nodes[cb].as_slice()) {
                            ([Op::Type(a)], [Op::Type(b)]) => a == b,
                            ([Op::Boolean(a)], [Op::Boolean(b)]) => a == b,
                            _ => false,
                        }
                })
    }
    fn compile_map(&mut self, value: Value) -> Result<Vec<(Value, usize)>, Value> {
        self.map(value)?
            .into_iter()
            .map(|(k, c)| Ok((k, self.compile(c)?)))
            .collect()
    }
    fn compile(&mut self, program: Value) -> Result<usize, Value> {
        if let Some(&i) = self.indices.get(&program) {
            return Ok(i);
        }
        self.retain(program);
        let index = self.nodes.len();
        self.indices.insert(program, index);
        self.nodes.push(vec![]);
        self.error_operands.push(vec![]);
        self.tracks.push(false);
        self.metadata.push(scope::Metadata::default());
        let code = self.field(program, b"code\0")?;
        let flags = unsafe { sn_integer(sn_entry(code, 0)) };
        self.tracks[index] = flags & i64::from(TRACKS_EVALUATION) != 0;
        self.compile_scope(program, index, flags)?;
        let mut ops = vec![];
        let mut error_operands = vec![];
        for i in (1..unsafe { sn_len(code) }).step_by(2) {
            let operand = self.retain(unsafe { sn_entry(code, i + 1) });
            let opcode = unsafe { sn_opcode(sn_entry(code, i)) };
            error_operands.push((opcode, operand));
            let op = match opcode {
                OP_BOOLEAN => Op::Boolean(unsafe { sn_true(operand) } != 0),
                OP_TYPE_NULL => Op::Type(TYPE_NULL),
                OP_TYPE_BOOLEAN => Op::Type(TYPE_BOOLEAN),
                OP_TYPE_OBJECT => Op::Type(TYPE_OBJECT),
                OP_TYPE_ARRAY => Op::Type(TYPE_ARRAY),
                OP_TYPE_NUMBER => Op::Type(TYPE_NUMBER),
                OP_TYPE_INTEGER => Op::Type(TYPE_INTEGER),
                OP_TYPE_STRING => Op::Type(TYPE_STRING),
                OP_TYPES => {
                    let mask = self.field(operand, b"mask\0")?;
                    Op::Type(unsafe { sn_integer(mask) } as i32)
                }
                OP_CONST => Op::Const(operand),
                OP_ENUM => Op::Enum(Box::new(enumeration::Enumeration::compile(
                    self.values(operand),
                    self.fixnum_flag,
                ))),
                OP_ALL_OF => Op::All(self.children(operand)?),
                OP_ANY_OF => Op::Any(self.branches(operand)?),
                OP_ONE_OF => Op::One(self.branches(operand)?),
                OP_NOT => Op::Not(self.compile(operand)?),
                OP_CONDITIONAL => {
                    let condition = self.field(operand, b"condition\0")?;
                    Op::Conditional(
                        self.compile(condition)?,
                        self.child(operand, b"then_branch\0")?,
                        self.child(operand, b"else_branch\0")?,
                    )
                }
                OP_NUMBER | OP_TYPED_NUMBER | OP_TYPED_INTEGER => {
                    if let Some(rules) = self.compile_number(operand)? {
                        Op::Number(
                            if opcode == OP_NUMBER {
                                0
                            } else if opcode == OP_TYPED_NUMBER {
                                TYPE_NUMBER
                            } else {
                                TYPE_INTEGER
                            },
                            Box::new(rules),
                        )
                    } else {
                        Op::Unsupported
                    }
                }
                OP_STRING | OP_TYPED_STRING => {
                    let pattern = self.field(operand, b"pattern\0")?;
                    let format = self.field(operand, b"format\0")?;
                    let base64 = self.field(operand, b"decode_base64\0")?;
                    let json = self.field(operand, b"parse_json\0")?;
                    {
                        let content = if self.validate_content
                            && unsafe { sn_true(base64) | sn_true(json) } != 0
                        {
                            Some(content::Content {
                                base64: unsafe { sn_true(base64) } != 0,
                                json: unsafe { sn_true(json) } != 0,
                            })
                        } else {
                            None
                        };
                        let assertion = self.field(operand, b"format_assertion\0")?;
                        let format = if (self.validate_format || unsafe { sn_true(assertion) } != 0)
                            && unsafe { sn_same(format, sn_nil()) } == 0
                        {
                            let name = self.field(format, b"name\0")?;
                            if unsafe { sn_same(name, sn_nil()) } != 0 {
                                None
                            } else {
                                Some(format::Format::compile(name))
                            }
                        } else {
                            None
                        };
                        Op::String(
                            if opcode == OP_TYPED_STRING {
                                TYPE_STRING
                            } else {
                                0
                            },
                            Box::new(StringRules {
                                format,
                                content,
                                min: self.size_field(operand, b"min_length\0")?,
                                max: self.size_field(operand, b"max_length\0")?,
                                pattern: if unsafe { sn_same(pattern, sn_nil()) } != 0 {
                                    None
                                } else {
                                    Some(pattern::Pattern::compile(
                                        pattern,
                                        &mut self.pattern_cache_count,
                                    ))
                                },
                            }),
                        )
                    }
                }
                OP_ARRAY | OP_TYPED_ARRAY => {
                    let unique = self.field(operand, b"unique\0")?;
                    let prefix = self.field(operand, b"prefix_items\0")?;
                    let prefix = self.children(prefix)?;
                    let items = self.field(operand, b"items\0")?;
                    let list = self.field(operand, b"items_list\0")?;
                    let list = unsafe { sn_true(list) } != 0;
                    let items = if list {
                        self.children(items)?
                    } else if unsafe { sn_same(items, sn_nil()) } != 0 {
                        vec![]
                    } else {
                        vec![self.compile(items)?]
                    };
                    Op::Array(
                        if opcode == OP_TYPED_ARRAY {
                            TYPE_ARRAY
                        } else {
                            0
                        },
                        Box::new(Array {
                            unique: unsafe { sn_true(unique) } != 0,
                            min: self.size_field(operand, b"min_items\0")?,
                            max: self.size_field(operand, b"max_items\0")?,
                            prefix,
                            items,
                            list,
                            additional: self.child(operand, b"additional\0")?,
                            contains: self.child(operand, b"contains\0")?,
                            min_contains: self.size_field(operand, b"min_contains\0")?.unwrap_or(1),
                            max_contains: self.size_field(operand, b"max_contains\0")?,
                            unevaluated: self.child(operand, b"unevaluated\0")?,
                        }),
                    )
                }
                OP_OBJECT | OP_TYPED_OBJECT => {
                    let patterns = self.field(operand, b"patterns\0")?;
                    let dependencies = self.field(operand, b"dependencies\0")?;
                    {
                        let patterns = self.compile_map(patterns)?;
                        let pattern_names: Vec<_> = patterns.iter().map(|&(key, _)| key).collect();
                        let patterns: Vec<_> = patterns
                            .into_iter()
                            .map(|(key, child)| {
                                (
                                    pattern::Pattern::compile(key, &mut self.pattern_cache_count),
                                    child,
                                )
                            })
                            .collect();
                        let pattern_group =
                            pattern::PatternGroup::compile(&pattern_names, &patterns);
                        let required = self.field(operand, b"required\0")?;
                        let required = self.values(required);
                        let required_order = required.clone();
                        let properties = self.field(operand, b"properties\0")?;
                        let properties = self.compile_map(properties)?;
                        if required
                            .iter()
                            .chain(properties.iter().map(|(key, _)| key))
                            .any(|&key| unsafe { sn_kind(key) } != TYPE_STRING)
                        {
                            ops.push(Op::Unsupported);
                            continue;
                        }
                        let property_targets: HashMap<_, _, BuildHasherDefault<BucketHasher>> =
                            properties
                                .iter()
                                .enumerate()
                                .map(|(index, &(name, child))| {
                                    (
                                        tracking::JsonKey::new(name),
                                        PropertyTarget { name, child, index },
                                    )
                                })
                                .collect();
                        let property_locations: Vec<_> = properties
                            .iter()
                            .map(|&(key, _)| tracking::JsonKey::new(key))
                            .collect();
                        let property_keys = property_locations.iter().copied().collect();
                        let property_indices = property_locations
                            .iter()
                            .map(|&key| {
                                let next = self.property_ids.len();
                                *self.property_ids.entry(key).or_insert(next)
                            })
                            .collect();
                        // Keep tiny schemas allocation-cheap; larger joins use
                        // content-keyed sets and the already compiled property index.
                        let indexed_required = properties.len().saturating_mul(required.len()) > 64;
                        let required_keys: Option<tracking::KeySet> = indexed_required.then(|| {
                            required
                                .iter()
                                .map(|&name| tracking::JsonKey::new(name))
                                .collect()
                        });
                        let required_properties: Vec<bool> = property_locations
                            .iter()
                            .map(|key| {
                                required_keys.as_ref().map_or_else(
                                    || {
                                        required.iter().any(
                                            |&name| unsafe { sn_string_equal(key.0, name) } != 0,
                                        )
                                    },
                                    |names| names.contains(key),
                                )
                            })
                            .collect();
                        let required_property_indices = required_properties
                            .iter()
                            .enumerate()
                            .filter_map(|(index, &required)| required.then_some(index))
                            .collect();
                        let required = required
                            .into_iter()
                            .filter(|&name| {
                                if indexed_required {
                                    !property_targets.contains_key(&tracking::JsonKey::new(name))
                                } else {
                                    !properties
                                        .iter()
                                        .any(|&(key, _)| unsafe { sn_string_equal(key, name) } != 0)
                                }
                            })
                            .collect();
                        let dependent = self.field(operand, b"dependent_required\0")?;
                        let mut dependent_required = vec![];
                        let mut dependent_schemas = vec![];
                        let mut diagnostic_dependencies = vec![];
                        for pair in self.values(dependencies) {
                            let name = self.retain(unsafe { sn_entry(pair, 0) });
                            let dependency = self.retain(unsafe { sn_entry(pair, 1) });
                            if unsafe { sn_kind(dependency) } == TYPE_ARRAY {
                                let names = self.values(dependency);
                                diagnostic_dependencies.push(DiagnosticDependency::Required(
                                    name,
                                    names.clone(),
                                    "dependencies",
                                ));
                                dependent_required.push((name, names));
                            } else {
                                let child = self.compile(dependency)?;
                                diagnostic_dependencies.push(DiagnosticDependency::Schema(
                                    name,
                                    child,
                                    "dependencies",
                                ));
                                dependent_schemas.push((name, child));
                            }
                        }
                        for pair in self.values(dependent) {
                            let name = self.retain(unsafe { sn_entry(pair, 0) });
                            let names = self.values(unsafe { sn_entry(pair, 1) });
                            diagnostic_dependencies.push(DiagnosticDependency::Required(
                                name,
                                names.clone(),
                                "dependentRequired",
                            ));
                            dependent_required.push((name, names));
                        }
                        let dependent = self.field(operand, b"dependent_schemas\0")?;
                        let schemas = self.compile_map(dependent)?;
                        diagnostic_dependencies.extend(schemas.iter().map(|&(name, child)| {
                            DiagnosticDependency::Schema(name, child, "dependentSchemas")
                        }));
                        dependent_schemas.extend(schemas);
                        if dependent_required.iter().any(|(name, keys)| {
                            (unsafe { sn_kind(*name) }) != TYPE_STRING
                                || keys
                                    .iter()
                                    .any(|&key| unsafe { sn_kind(key) } != TYPE_STRING)
                        }) || dependent_schemas
                            .iter()
                            .any(|&(key, _)| unsafe { sn_kind(key) } != TYPE_STRING)
                        {
                            ops.push(Op::Unsupported);
                            continue;
                        }
                        let mut object = Object {
                            record: None,
                            min: self.size_field(operand, b"min_properties\0")?,
                            max: self.size_field(operand, b"max_properties\0")?,
                            required,
                            required_order,
                            properties,
                            property_targets,
                            patterns,
                            pattern_names,
                            pattern_group,
                            required_properties,
                            required_property_indices,
                            property_keys,
                            property_indices,
                            additional: self.child(operand, b"additional\0")?,
                            names: self.child(operand, b"property_names\0")?,
                            dependent_required,
                            dependent_schemas,
                            diagnostic_dependencies,
                            unevaluated: self.child(operand, b"unevaluated\0")?,
                        }
                        .with_record();
                        if let Some(record) = &mut object.record {
                            for field in &mut record.fields {
                                field.check = field.child.and_then(|child| {
                                    match self.nodes[child].as_slice() {
                                        [Op::Number(_, rules)] => {
                                            rules.fast_limits.as_ref().map(|limits| {
                                                let (min, max) = limits.iter().fold(
                                                    (i64::MIN, i64::MAX),
                                                    |(min, max), &(bit, limit)| match bit {
                                                        MAXIMUM => (min, max.min(limit)),
                                                        MINIMUM => (min.max(limit), max),
                                                        EXCLUSIVE_MAXIMUM => {
                                                            (min, max.min(limit.saturating_sub(1)))
                                                        }
                                                        _ => {
                                                            (min.max(limit.saturating_add(1)), max)
                                                        }
                                                    },
                                                );
                                                RecordCheck::IntegerBounds(min, max)
                                            })
                                        }
                                        [Op::String(required, rules)] if rules.length_only() => {
                                            Some(RecordCheck::StringLength(
                                                *required, rules.min, rules.max,
                                            ))
                                        }
                                        _ => None,
                                    }
                                });
                                let mut key = 0;
                                if unsafe { sn_key_copy(field.name, &mut key) } != 0 {
                                    return Err(key);
                                }
                                // Distinct schema-only lookup handles also work
                                // when VM keys and input keys share an fstring.
                                field.name = self.retain(key);
                            }
                        }
                        Op::Object(
                            if opcode == OP_TYPED_OBJECT {
                                TYPE_OBJECT
                            } else {
                                0
                            },
                            Box::new(object),
                        )
                    }
                }
                OP_REF | OP_RECURSIVE_REF | OP_DYNAMIC_REF => {
                    let reference = self.field(operand, b"value\0")?;
                    let mut target = 0;
                    if unsafe { sn_resolve(self.compiler, program, reference, &mut target) } != 0 {
                        if unsafe { sn_resolution_error(target) } != 0 {
                            Op::Unsupported
                        } else {
                            return Err(target);
                        }
                    } else {
                        self.retain(target);
                        let target = self.compile(target)?;
                        self.compile_reference(operand, opcode, target)?
                    }
                }
                _ => Op::Unsupported,
            };
            ops.push(op);
        }
        self.nodes[index] = ops;
        self.error_operands[index] = error_operands;
        Ok(index)
    }
}

// A view of immutable compiled data and validator-owned regex search caches.
struct Execution<'a> {
    engine: &'a Engine,
    caches: &'a pattern::Caches,
    memo: memo::Memo,
    budget: budget::Budget,
}
impl std::ops::Deref for Execution<'_> {
    type Target = Engine;
    fn deref(&self) -> &Engine {
        self.engine
    }
}
impl Execution<'_> {
    fn eval(&self, node: usize, value: Value, depth: usize, active: scope::Context<'_>) -> Verdict {
        self.eval_with_kind(node, value, depth, active, None)
    }
    // Same-location applicators borrow an immutable instance under the GVL.
    // A full key guard can be reused; descendants at other locations recheck.
    fn eval_with_kind(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        known_kind: Option<i32>,
    ) -> Verdict {
        if !self.budget.checkpoint() {
            return Unsupported;
        }
        let Some(key) = self
            .memo
            .key(self, node, value, depth, active, &self.budget)
        else {
            if self.budget.hit.get().0 != 0 {
                return Unsupported;
            }
            return self.eval_uncached(node, value, depth, active, known_kind);
        };
        if self.budget.hit.get().0 != 0 {
            return Unsupported;
        }
        if let Some(status) = self.memo.verdict(key) {
            return status;
        }
        let status = self.eval_uncached(node, value, depth, active, known_kind);
        self.memo.record_verdict(key, status);
        status
    }
    fn eval_uncached(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        known_kind: Option<i32>,
    ) -> Verdict {
        let frame = scope::ScopeFrame {
            resource: self.metadata[node].resource,
            parent: active.scope,
            primary_binding: active
                .scope
                .and_then(|frame| frame.primary_binding)
                .or(self.metadata[node].primary_binding),
        };
        let active = self.enter_scope(node, active, &frame);
        if self.tracks[node] {
            return match known_kind {
                Some(kind) => {
                    self.eval_tracked_kind(node, value, depth, active, kind)
                        .status
                }
                None => self.eval_tracked(node, value, depth, active).status,
            };
        }
        if depth > MAX_EVALUATION_DEPTH {
            return Unsupported;
        }
        if let [Op::String(required, rules)] = self.nodes[node].as_slice()
            && rules.pattern.is_some()
        {
            return rules.eval_guarded(self.caches, *required, value);
        }
        let kind = known_kind.unwrap_or_else(|| {
            if value & self.fixnum_flag != 0 {
                TYPE_INTEGRAL_NUMBER
            } else {
                self.instance_kind(node, value)
            }
        });
        if kind == TYPE_UNSUPPORTED {
            return Unsupported;
        }
        for op in &self.nodes[node] {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let outcome = match op {
                Op::Ref(target) => {
                    if RefFrame::contains(active.active, node, value) {
                        Valid
                    } else {
                        let frame = RefFrame {
                            source: node,
                            value,
                            parent: active.active,
                        };
                        self.eval_with_kind(
                            self.reference_target(*target, active),
                            value,
                            depth + 1,
                            scope::Context {
                                active: Some(&frame),
                                ..active
                            },
                            Some(kind),
                        )
                    }
                }
                Op::All(nodes) => {
                    let mut outcome = Valid;
                    for &n in nodes {
                        if !self.budget.checkpoint() {
                            return Unsupported;
                        }
                        outcome = self.eval_with_kind(n, value, depth + 1, active, Some(kind));
                        if outcome != Valid {
                            break;
                        }
                    }
                    outcome
                }
                Op::Any(nodes) | Op::One(nodes) => {
                    let branch_kind = if matches!(op, Op::Any(_)) {
                        evaluation::BranchKind::Any
                    } else {
                        evaluation::BranchKind::One
                    };
                    match evaluation::scan_branches(
                        nodes,
                        evaluation::BranchPolicy::Validity(branch_kind),
                        |child| self.eval_with_kind(child, value, depth + 1, active, Some(kind)),
                    ) {
                        Ok(result) => verdict(branch_kind.accepts(result.matches)),
                        Err(status) => status,
                    }
                }
                Op::Not(n) => match self.eval_with_kind(*n, value, depth + 1, active, Some(kind)) {
                    Valid => Invalid,
                    Invalid => Valid,
                    Unsupported => Unsupported,
                },
                Op::Conditional(c, yes, no) => {
                    match self.eval_with_kind(*c, value, depth + 1, active, Some(kind)) {
                        Unsupported => Unsupported,
                        result => match if result == Valid { yes } else { no } {
                            Some(n) => {
                                self.eval_with_kind(*n, value, depth + 1, active, Some(kind))
                            }
                            None => Valid,
                        },
                    }
                }
                Op::Array(required, rules) => {
                    if *required != 0 && kind != TYPE_ARRAY {
                        Invalid
                    } else if kind != TYPE_ARRAY {
                        Valid
                    } else {
                        self.array(rules, value, depth + 1, active)
                    }
                }
                Op::Object(required, rules) => {
                    if *required != 0 && kind != TYPE_OBJECT {
                        Invalid
                    } else if kind != TYPE_OBJECT {
                        Valid
                    } else {
                        self.object(rules, value, depth + 1, active)
                    }
                }
                _ => self.leaf(op, kind, value, depth),
            };
            if outcome != Valid {
                return outcome;
            }
        }
        Valid
    }
    fn leaf(&self, op: &Op, kind: i32, value: Value, depth: usize) -> Verdict {
        match op {
            Op::Unsupported => Unsupported,
            Op::Boolean(v) => verdict(*v),
            Op::Type(mask) => verdict(kind & mask != 0),
            Op::Const(v) => equal_budgeted(*v, value, depth, &self.budget),
            Op::Enum(values) => values.eval(value, kind, depth, self.fixnum_flag, &self.budget),
            Op::Number(required, rules) => {
                if *required != 0 && kind & required == 0 {
                    Invalid
                } else if kind & TYPE_NUMBER == 0 {
                    Valid
                } else {
                    rules.eval(value)
                }
            }
            Op::String(required, rules) => {
                if *required != 0 && kind != TYPE_STRING {
                    Invalid
                } else if kind != TYPE_STRING {
                    Valid
                } else {
                    rules.eval(self.caches, value)
                }
            }
            _ => unreachable!("applicators must be evaluated with their context"),
        }
    }
    fn array(&self, r: &Array, value: Value, depth: usize, active: scope::Context<'_>) -> Verdict {
        if !self.budget.checkpoint() {
            return Unsupported;
        }
        let len = unsafe { sn_len(value) };
        if bounds(len, r.min, r.max) == Invalid {
            return Invalid;
        }
        if r.unique {
            let result = unique(value, depth, self.fixnum_flag, &self.budget);
            if result != Valid {
                return result;
            }
        }
        for (i, &child) in r.prefix.iter().take(len).enumerate() {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let result = self.eval(child, unsafe { sn_entry(value, i) }, depth, active);
            if result != Valid {
                return result;
            }
        }
        if r.list {
            for (i, &child) in r.items.iter().take(len).enumerate() {
                if !self.budget.checkpoint() {
                    return Unsupported;
                }
                let result = self.eval(child, unsafe { sn_entry(value, i) }, depth, active);
                if result != Valid {
                    return result;
                }
            }
            if let Some(child) = r.additional {
                for i in r.items.len()..len {
                    if !self.budget.checkpoint() {
                        return Unsupported;
                    }
                    let result = self.eval(child, unsafe { sn_entry(value, i) }, depth, active);
                    if result != Valid {
                        return result;
                    }
                }
            }
        } else if let Some(&child) = r.items.first() {
            // Borrow CRuby's storage only for this Ruby-allocation-free traversal.
            // No Ruby callback or Ruby allocation occurs while it is live.
            let values = if len == 0 {
                &[]
            } else {
                unsafe { std::slice::from_raw_parts(sn_array_data(value), len) }
            };
            let primitive = match self.nodes[child].as_slice() {
                [Op::Type(mask)] if mask & TYPE_NUMBER != 0 || mask & TYPE_INTEGER != 0 => {
                    Some(&[][..])
                }
                [Op::Number(_, rules)] => rules.fast_limits.as_deref(),
                _ => None,
            };
            let number = match self.nodes[child].as_slice() {
                [Op::Number(required, rules)]
                    if depth <= MAX_EVALUATION_DEPTH && !self.tracks[child] =>
                {
                    Some((*required, rules))
                }
                _ => None,
            };
            let string = match self.nodes[child].as_slice() {
                [Op::String(required, rules)] if depth <= MAX_EVALUATION_DEPTH => {
                    Some((*required, rules))
                }
                _ => None,
            };
            let object = match self.nodes[child].as_slice() {
                [Op::Object(required, rules)]
                    if depth <= MAX_EVALUATION_DEPTH
                        && !self.tracks[child]
                        && rules.record.is_some() =>
                {
                    Some((*required, rules))
                }
                _ => None,
            };
            // Sibling items enter the same schema resource. Reuse the immutable
            // scope frame while their child evaluations remain synchronous.
            let frame = scope::ScopeFrame {
                resource: self.metadata[child].resource,
                parent: active.scope,
                primary_binding: active
                    .scope
                    .and_then(|frame| frame.primary_binding)
                    .or(self.metadata[child].primary_binding),
            };
            let object_active = self.enter_scope(child, active, &frame);
            let pattern = string.and_then(|(required, rules)| {
                rules
                    .pattern_only()
                    .map(|pattern| (required, pattern))
                    .filter(|_| !self.budget.timed())
            });
            let format = string.and_then(|(required, rules)| {
                rules
                    .format_only()
                    .map(|format| (required, format))
                    .filter(|_| !self.budget.timed())
            });
            let content = string.and_then(|(required, rules)| {
                rules
                    .content_only()
                    .map(|content| (required, content))
                    .filter(|_| !self.budget.timed())
            });
            if let Some((required, pattern)) = pattern {
                let result = pattern.eval_items(
                    self.caches,
                    required,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                );
                if result != Valid {
                    return result;
                }
            } else if let Some((required, format)) = format {
                let result =
                    format.eval_items(required, values.get(r.prefix.len()..).unwrap_or(&[]));
                if result != Valid {
                    return result;
                }
            } else if let Some((required, content)) = content {
                let result =
                    content.eval_items(required, values.get(r.prefix.len()..).unwrap_or(&[]));
                if result != Valid {
                    return result;
                }
            } else if let Some((required, rules)) = object {
                let result = self.record_items(
                    rules,
                    required,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                    depth + 1,
                    object_active,
                );
                if result != Valid {
                    return result;
                }
            } else if let Some(limits) = primitive {
                let result = self.integer_items(
                    limits,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                    child,
                    depth,
                    active,
                );
                if result != Valid {
                    return result;
                }
            } else {
                for &item in values.iter().skip(r.prefix.len()) {
                    if !self.budget.checkpoint() {
                        return Unsupported;
                    }
                    let result = if let Some((required, rules)) = number {
                        rules.eval_guarded(required, item)
                    } else if let Some((required, rules)) = string {
                        if rules.pattern.is_some() {
                            rules.eval_guarded(self.caches, required, item)
                        } else if rules.length_only() {
                            rules.eval_length_guarded(required, item)
                        } else {
                            let kind = unsafe { sn_kind(item) };
                            if kind == TYPE_UNSUPPORTED {
                                Unsupported
                            } else if kind != TYPE_STRING {
                                verdict(required == 0)
                            } else {
                                rules.eval(self.caches, item)
                            }
                        }
                    } else {
                        self.eval(child, item, depth, active)
                    };
                    if result != Valid {
                        return result;
                    }
                }
            }
        }
        if let Some(child) = r.contains {
            if let Some(status) = self.fixnum_contains(r, child, value, len, depth) {
                return status;
            }
            let matches = match evaluation::scan_contains(
                len,
                |index| self.eval(child, unsafe { sn_entry(value, index) }, depth, active),
                |_| {},
            ) {
                Ok(matches) => matches,
                Err(status) => return status,
            };
            if bounds(matches, Some(r.min_contains), r.max_contains) == Invalid {
                return Invalid;
            }
        }
        Valid
    }
    fn fixnum_contains(
        &self,
        rules: &Array,
        child: usize,
        value: Value,
        len: usize,
        depth: usize,
    ) -> Option<Verdict> {
        if depth > MAX_EVALUATION_DEPTH || self.tracks[child] || self.budget.timed() {
            return None;
        }
        let [op] = self.nodes[child].as_slice() else {
            return None;
        };
        let total = match op {
            Op::Type(_) | Op::Boolean(_) => true,
            Op::Const(expected) => expected & self.fixnum_flag != 0,
            Op::Number(_, rules) => rules.fast_limits.is_some(),
            _ => false,
        };
        if !total {
            return None;
        }
        let values = if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(sn_array_data(value), len) }
        };
        // Preserve later Unsupported/fallback results: no predicate work may
        // be skipped until all values are proven to be supported Fixnums.
        // This guard stays linear, but is far cheaper than full node evaluation.
        if !values.iter().all(|&item| item & self.fixnum_flag != 0) {
            return None;
        }
        Some(evaluation::contains_validity(
            len,
            rules.min_contains,
            rules.max_contains,
            |index| self.leaf(op, TYPE_INTEGRAL_NUMBER, values[index], depth) == Valid,
        ))
    }
    fn integer_items(
        &self,
        limits: &[(i32, i64)],
        values: &[Value],
        child: usize,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        // Interpret exact limits once; only header-validated immediate integers
        // use this interval. Other values retain the original guarded evaluator.
        let (min, max) =
            limits.iter().fold(
                (i64::MIN, i64::MAX),
                |(min, max), &(bit, limit)| match bit {
                    MAXIMUM => (min, max.min(limit)),
                    MINIMUM => (min.max(limit), max),
                    EXCLUSIVE_MAXIMUM => (min, max.min(limit.saturating_sub(1))),
                    _ => (min.max(limit.saturating_add(1)), max),
                },
            );
        let number = match self.nodes[child].as_slice() {
            [Op::Number(required, rules)]
                if depth <= MAX_EVALUATION_DEPTH && !self.tracks[child] =>
            {
                Some((*required, rules))
            }
            _ => None,
        };
        let prefix = if self.budget.timed() {
            0
        } else {
            integer_scan::valid_prefix(values, min, max, self.fixnum_flag)
        };
        for &value in &values[prefix..] {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let result = if value & self.fixnum_flag != 0 {
                let n = immediate_integer(value);
                verdict(n >= min && n <= max)
            } else if let Some((required, rules)) = number {
                rules.eval_guarded(required, value)
            } else {
                self.eval(child, value, depth, active)
            };
            if result != Valid {
                return result;
            }
        }
        Valid
    }
    fn record_items(
        &self,
        rules: &Object,
        required: i32,
        values: &[Value],
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        for &value in values {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let kind = if value & self.fixnum_flag != 0 {
                TYPE_INTEGRAL_NUMBER
            } else {
                unsafe { sn_shallow_kind(value) }
            };
            let result = if kind == TYPE_UNSUPPORTED {
                Unsupported
            } else if kind != TYPE_OBJECT {
                verdict(required == 0)
            } else {
                self.object(rules, value, depth, active)
            };
            if result != Valid {
                return result;
            }
        }
        Valid
    }
    fn object(
        &self,
        r: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        if !self.budget.checkpoint() {
            return Unsupported;
        }
        if let Some(record) = &r.record {
            // C initializes only the written key/value pairs. The untouched
            // tail is never read, including empty and unsupported records.
            let mut buffer = std::mem::MaybeUninit::<[Value; 16]>::uninit();
            let len = unsafe { sn_small_hash(value, buffer.as_mut_ptr().cast()) };
            if len == SMALL_HASH_TOO_LARGE {
                return if unsafe { sn_kind(value) } == TYPE_OBJECT {
                    self.object_general(r, value, depth, active)
                } else {
                    Unsupported
                };
            }
            if len < 0 {
                return Unsupported;
            }
            let ordinary = len & SMALL_HASH_ORDINARY != 0;
            let len = len & SMALL_HASH_COUNT_MASK;
            let status = bounds(len as usize, r.min, r.max);
            if status != Valid {
                return status;
            }
            // Successful calls wrote exactly len pairs, bounded by eight;
            // no Ruby callback or allocation can change the Hash during C's walk.
            let entries = unsafe {
                std::slice::from_raw_parts(buffer.as_ptr().cast::<Value>(), 2 * len as usize)
            };
            let mut context = RecordContext {
                engine: self,
                rules: r,
                record,
                // Choose for this record only. Both lookup strategies verify
                // every actual key; mixed layouts cannot change the verdict.
                indexed: record.short_index.is_some()
                    && entries.first().is_some_and(|key| {
                        record.identity_hint != *key
                            && !record.fields.iter().any(|field| field.key == *key)
                    }),
                depth,
                active,
                visited: 0,
                // A proven ordinary Hash never uses this lookup handle.
                // Seed its unused slot to avoid collecting a distinct key.
                probe: ordinary.then_some(self.undefined),
                status,
            };
            for entry in entries.as_chunks::<2>().0 {
                if !self.budget.checkpoint() {
                    return Unsupported;
                }
                if record_entry(&mut context, entry[0], entry[1]) != Valid {
                    return Unsupported;
                }
            }
            if !ordinary && let Some(name) = context.probe {
                // All keys have now been checked. A successful lookup by
                // a distinct equal schema key proves ordinary Hash key
                // semantics, without calling a Ruby identity predicate.
                if missing(value, name, self.undefined) {
                    return Unsupported;
                }
            } else if !ordinary && context.visited != 0 {
                return Unsupported;
            }
            return if context.status != Valid {
                context.status
            } else {
                verdict(context.visited & record.required == record.required)
            };
        }
        self.object_general(r, value, depth, active)
    }
    fn object_general(
        &self,
        r: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        let len = unsafe { sn_len(value) };
        if bounds(len, r.min, r.max) == Invalid {
            return Invalid;
        }
        let status = r.check_required(value, self.undefined, &self.budget);
        if status != Valid {
            return status;
        }
        let found = match r.visit_properties(
            value,
            len,
            self.undefined,
            &self.budget,
            |_, child, item| self.eval(child, item, depth, active),
        ) {
            Ok(found) => found,
            Err(status) => return status,
        };
        if r.names.is_some() || !r.patterns.is_empty() || (r.additional.is_some() && found < len) {
            let mut context = ObjectContext {
                engine: self,
                rules: r,
                depth,
                active,
            };
            let result =
                unsafe { sn_object_each(value, (&mut context as *mut ObjectContext).cast()) };
            if result != VERDICT_VALID {
                return if result == 0 { Invalid } else { Unsupported };
            }
        }
        let status = r.check_dependent_required(value, self.undefined, &self.budget);
        if status != Valid {
            return status;
        }
        for &(name, child) in &r.dependent_schemas {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            if !missing(value, name, self.undefined) {
                let result = self.eval(child, value, depth, active);
                if result != Valid {
                    return result;
                }
            }
        }
        Valid
    }
    fn instance_kind(&self, node: usize, value: Value) -> i32 {
        if matches!(self.nodes[node].as_slice(), [Op::Object(_, rules)] if rules.record.is_some()) {
            unsafe { sn_shallow_kind(value) }
        } else {
            unsafe { sn_kind(value) }
        }
    }
    fn record_value(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        if !self.budget.checkpoint() {
            return Unsupported;
        }
        match self.nodes[node].as_slice() {
            [Op::String(required, rules)]
                if depth <= MAX_EVALUATION_DEPTH && rules.length_only() =>
            {
                rules.eval_length_guarded(*required, value)
            }
            [Op::String(required, rules)]
                if depth <= MAX_EVALUATION_DEPTH && rules.pattern.is_some() =>
            {
                rules.eval_guarded(self.caches, *required, value)
            }
            [
                op @ (Op::Type(_)
                | Op::Boolean(_)
                | Op::Number(..)
                | Op::String(..)
                | Op::Const(_)
                | Op::Enum(_)),
            ] if depth <= MAX_EVALUATION_DEPTH => {
                let kind = if value & self.fixnum_flag != 0 {
                    TYPE_INTEGRAL_NUMBER
                } else {
                    unsafe { sn_kind(value) }
                };
                if kind == TYPE_UNSUPPORTED {
                    Unsupported
                } else {
                    self.leaf(op, kind, value, depth)
                }
            }
            _ => self.eval(node, value, depth, active),
        }
    }
}
struct RecordContext<'a, 'b> {
    engine: &'a Execution<'a>,
    rules: &'a Object,
    record: &'a RecordObject,
    indexed: bool,
    depth: usize,
    active: scope::Context<'b>,
    visited: u64,
    probe: Option<Value>,
    status: Verdict,
}
fn indexed_record_field(record: &RecordObject, key: Value) -> Option<&RecordField> {
    let index = record.short_index.as_ref()?;
    let short = short_record_key(key);
    if short.tag == 0 {
        return None;
    }
    index.slots[index.slot(short)]
        .checked_sub(1)
        .and_then(|at| record.fields.get(at as usize))
        .filter(|field| {
            field.short_key.tag & 15 == short.tag & 15
                && field.short_key.word == short.word
                && (field.short_key.tag == short.tag
                    || unsafe { sn_string_equal(field.key, key) } != 0)
        })
}
fn record_entry(c: &mut RecordContext<'_, '_>, key: Value, value: Value) -> Verdict {
    let field = if c.indexed {
        indexed_record_field(c.record, key)
    } else {
        c.record
            .fields
            .iter()
            .find(|field| field.key == key)
            .or_else(|| {
                if c.record.short_index.is_some() {
                    return indexed_record_field(c.record, key);
                }
                let short = (c.record.fields.len() >= 4).then(|| short_record_key(key));
                c.record.fields.iter().find(|field| {
                    if let Some(short) = short.filter(|short| short.tag != 0) {
                        field.short_key.tag & 15 == short.tag & 15
                            && field.short_key.word == short.word
                            && (field.short_key.tag == short.tag
                                || unsafe { sn_string_equal(field.key, key) } != 0)
                    } else {
                        (unsafe { sn_string_equal(field.key, key) }) != 0
                    }
                })
            })
    };
    let child = if let Some(field) = field {
        if c.visited & field.bit != 0 {
            return Unsupported;
        }
        c.visited |= field.bit;
        if c.probe.is_none() && field.name != key {
            c.probe = Some(field.name);
        }
        field.child.or(c.rules.additional)
    } else {
        c.rules.additional
    };
    if c.status == Valid
        && let Some(child) = child
    {
        c.status = if c.depth <= MAX_EVALUATION_DEPTH {
            match field.and_then(|field| field.check) {
                Some(RecordCheck::IntegerBounds(min, max)) if value & c.engine.fixnum_flag != 0 => {
                    let n = immediate_integer(value);
                    verdict(n >= min && n <= max)
                }
                Some(RecordCheck::StringLength(required, min, max)) => {
                    length_guarded(value, required, min, max)
                }
                _ => c.engine.record_value(child, value, c.depth, c.active),
            }
        } else {
            c.engine.record_value(child, value, c.depth, c.active)
        };
    }
    // Keep recording matches after failure: duplicate equal keys indicate
    // identity semantics, so their speculative child results cannot be used.
    Valid
}
struct RefFrame<'a> {
    source: usize,
    value: Value,
    parent: Option<&'a RefFrame<'a>>,
}
impl RefFrame<'_> {
    fn contains(mut active: Option<&Self>, source: usize, value: Value) -> bool {
        while let Some(frame) = active {
            if frame.source == source && frame.value == value {
                return true;
            }
            active = frame.parent;
        }
        false
    }
}
fn missing(hash: Value, key: Value, undefined: Value) -> bool {
    unsafe { sn_lookup(hash, key) == undefined }
}
fn verdict(valid: bool) -> Verdict {
    if valid { Valid } else { Invalid }
}
fn bounds(len: usize, min: Option<usize>, max: Option<usize>) -> Verdict {
    verdict(!min.is_some_and(|m| len < m) && !max.is_some_and(|m| len > m))
}
fn length_guarded(value: Value, required: i32, min: Option<usize>, max: Option<usize>) -> Verdict {
    let mut len = 0;
    match unsafe { sn_string_length_guarded(value, &mut len) } {
        TYPE_UNSUPPORTED => Unsupported,
        TYPE_STRING => bounds(len, min, max),
        _ => verdict(required == 0),
    }
}
// Call only after value & the header-validated fixnum_flag is nonzero.
// Rust's signed shift is arithmetic; other encodings retain the C adapters.
fn immediate_integer(value: Value) -> i64 {
    (value as isize >> 1) as i64
}
fn equal_budgeted(a: Value, b: Value, depth: usize, budget: &budget::Budget) -> Verdict {
    equal_cached(a, b, depth, &mut structural::Cache::new(depth), budget)
}
fn equal_cached(
    a: Value,
    b: Value,
    depth: usize,
    memo: &mut structural::Cache<(Value, Value, usize), Verdict>,
    budget: &budget::Budget,
) -> Verdict {
    if !budget.checkpoint() {
        return Unsupported;
    }
    if depth > MAX_EVALUATION_DEPTH {
        return Unsupported;
    }
    let (ka, kb) = unsafe { (sn_kind(a), sn_kind(b)) };
    if ka == TYPE_UNSUPPORTED || kb == TYPE_UNSUPPORTED {
        return Unsupported;
    }
    if ka & TYPE_NUMBER != 0 && kb & TYPE_NUMBER != 0 {
        let (ia, ib) = unsafe { (sn_fixnum(a) != 0, sn_fixnum(b) != 0) };
        let (fa, fb) = unsafe { (sn_is_float(a) != 0, sn_is_float(b) != 0) };
        if ia && ib {
            return verdict(unsafe { sn_integer(a) == sn_integer(b) });
        }
        if fa && fb {
            return verdict(unsafe { sn_float(a) == sn_float(b) });
        }
        if (ia && fb) || (fa && ib) {
            let (n, f) = unsafe {
                if ia {
                    (sn_integer(a), sn_float(b))
                } else {
                    (sn_integer(b), sn_float(a))
                }
            };
            // Convert the float to an integer, never the integer to a rounded float.
            // Fixnums are strictly inside i64's bounds on supported CRuby targets.
            return verdict(
                f.is_finite()
                    && f.trunc() == f
                    && f >= i64::MIN as f64
                    && f < i64::MAX as f64
                    && f as i64 == n,
            );
        }
        if !fa && !fb {
            return verdict(
                unsafe {
                    if ia {
                        sn_big_equal(b, a)
                    } else {
                        sn_big_equal(a, b)
                    }
                } != 0,
            );
        }
        return if fa {
            number::integer_float_equal(b, unsafe { sn_float(a) })
        } else {
            number::integer_float_equal(a, unsafe { sn_float(b) })
        };
    }
    // JSON container equality visits every value, even for the same object:
    // nested NaN values are unequal and unsupported values need VM evaluation.
    if ka != TYPE_ARRAY && ka != TYPE_OBJECT && unsafe { sn_same(a, b) } != 0 {
        return Valid;
    }
    if ka != kb {
        return Invalid;
    }
    if unsafe { sn_same_class(a, b) } == 0 {
        return Invalid;
    }
    let container = ka == TYPE_ARRAY || ka == TYPE_OBJECT;
    let key = (a, b, depth);
    if container
        && memo.eligible(depth)
        && let Some(result) = memo.get(key)
    {
        return result;
    }
    let result = match ka {
        TYPE_STRING => verdict(unsafe { sn_string_equal(a, b) } != 0),
        TYPE_ARRAY => {
            let len = unsafe { sn_len(a) };
            if len != unsafe { sn_len(b) } {
                return Invalid;
            }
            for i in 0..len {
                let result = equal_cached(
                    unsafe { sn_entry(a, i) },
                    unsafe { sn_entry(b, i) },
                    depth + 1,
                    memo,
                    budget,
                );
                if result != Valid {
                    return result;
                }
            }
            Valid
        }
        TYPE_OBJECT => {
            if unsafe { sn_len(a) != sn_len(b) } {
                return Invalid;
            }
            let mut context = EqualityContext {
                other: b,
                depth: depth + 1,
                memo,
                budget,
            };
            decode(unsafe {
                sn_hash_each(
                    a,
                    (&mut context as *mut EqualityContext<'_>).cast(),
                    equal_entry,
                )
            })
        }
        TYPE_UNSUPPORTED => Unsupported,
        _ => Invalid,
    };
    if container && memo.eligible(depth) {
        memo.record(key, result);
    }
    result
}
fn decode(result: i32) -> Verdict {
    match result {
        VERDICT_INVALID => Invalid,
        VERDICT_VALID => Valid,
        _ => Unsupported,
    }
}
struct EqualityContext<'a> {
    other: Value,
    depth: usize,
    memo: &'a mut structural::Cache<(Value, Value, usize), Verdict>,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn equal_entry(context: *mut c_void, key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &mut *context.cast::<EqualityContext<'_>>() };
        if unsafe { sn_kind(key) } != TYPE_STRING {
            return Unsupported as i32;
        }
        if !c.budget.checkpoint() {
            return Unsupported as i32;
        }
        let other = unsafe { sn_lookup(c.other, key) };
        if unsafe { sn_missing(other) } != 0 {
            Invalid as i32
        } else {
            equal_cached(value, other, c.depth, c.memo, c.budget) as i32
        }
    }))
    .unwrap_or(Unsupported as i32)
}
fn mix(n: u64) -> u64 {
    let n = (n ^ (n >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    let n = (n ^ (n >> 27)).wrapping_mul(0x94d049bb133111eb);
    n ^ (n >> 31)
}
fn string_fingerprint(value: Value) -> u64 {
    bytes_fingerprint(unsafe { string_bytes(value) })
}
#[derive(Clone, Copy, Debug)]
struct ShortRecordKey {
    word: u64,
    // Low four bits encode length + 1; zero means a longer key. The remaining
    // bits hold the public CRuby encoding index, not a borrowed pointer.
    tag: u64,
}
fn short_record_key(value: Value) -> ShortRecordKey {
    let mut data = std::ptr::null();
    let mut len = 0;
    let encoding = unsafe { sn_record_key_view(value, &mut data, &mut len) };
    if len > 8 {
        return ShortRecordKey { word: 0, tag: 0 };
    }
    let bytes = unsafe { byte_view(data, len) };
    ShortRecordKey {
        word: short_word(bytes),
        tag: ((encoding as u64) << 4) | (len as u64 + 1),
    }
}
// Borrow an already classified String under the GVL. The caller must not
// allocate Ruby objects or run Ruby callbacks while the returned view is live.
unsafe fn string_bytes<'a>(value: Value) -> &'a [u8] {
    let mut data = std::ptr::null();
    let mut len = 0;
    unsafe { sn_string_raw_view(value, &mut data, &mut len) };
    unsafe { byte_view(data, len) }
}
// The caller must keep the original Ruby string alive and unchanged under
// the GVL for the entire lifetime of the view, without allocating in Ruby.
unsafe fn byte_view<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }
    }
}
// For at most eight bytes, the first/last scalar words cover every byte.
fn short_word(bytes: &[u8]) -> u64 {
    let len = bytes.len();
    match bytes.len() {
        0 => 0,
        1 => bytes[0] as u64,
        2 => bytes[0] as u64 | (bytes[1] as u64) << 8,
        3 => bytes[0] as u64 | (bytes[1] as u64) << 8 | (bytes[2] as u64) << 16,
        _ => {
            let first = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as u64;
            let last = u32::from_le_bytes(bytes[len - 4..].try_into().unwrap()) as u64;
            first | last << 32
        }
    }
}
fn bytes_fingerprint(bytes: &[u8]) -> u64 {
    // Short keys and values fit in one scalar. Overlapping first/last words
    // cover every byte without a byte-at-a-time multiplication chain.
    let len = bytes.len();
    if len <= 8 {
        let word = short_word(bytes);
        return mix(word ^ (len as u64).wrapping_mul(0x100000001b3) ^ TYPE_STRING as u64);
    }
    let mut result = 0xcbf29ce484222325_u64;
    for &byte in bytes {
        result = (result ^ byte as u64).wrapping_mul(0x100000001b3);
    }
    mix(result ^ TYPE_STRING as u64)
}
fn fingerprint_budgeted(
    value: Value,
    depth: usize,
    fixnum_flag: Value,
    big_hint: bool,
    budget: &budget::Budget,
) -> Option<u64> {
    fingerprint_cached(
        value,
        depth,
        fixnum_flag,
        big_hint,
        &mut structural::Cache::new(depth),
        budget,
    )
}
fn fingerprint_cached(
    value: Value,
    depth: usize,
    fixnum_flag: Value,
    big_hint: bool,
    memo: &mut structural::Cache<(Value, usize), Option<u64>>,
    budget: &budget::Budget,
) -> Option<u64> {
    if !budget.checkpoint() {
        return None;
    }
    if depth > MAX_EVALUATION_DEPTH {
        return None;
    }
    if value & fixnum_flag != 0 {
        // sn_fixnum_flag enables this hint only after the C headers confirm
        // the signed immediate encoding. Rust's signed shift is arithmetic.
        let integer = immediate_integer(value);
        return Some(mix(integer as u64 ^ TYPE_NUMBER as u64));
    }
    if big_hint && let Some(hash) = number::big_fingerprint(value) {
        return Some(hash);
    }
    // The C key-view iterator validates every key without Ruby lookup.
    // Avoid a separate preliminary walk of the same keys.
    let mut data = std::mem::MaybeUninit::<*const c_void>::uninit();
    let mut len = std::mem::MaybeUninit::<usize>::uninit();
    let mut n = std::mem::MaybeUninit::<f64>::uninit();
    // Read only the fields the C adapter initialized for the returned kind.
    let kind =
        unsafe { sn_fingerprint_view(value, data.as_mut_ptr(), len.as_mut_ptr(), n.as_mut_ptr()) };
    if kind == TYPE_NUMBER {
        let n = unsafe { n.assume_init() };
        // Normalize integral floats without rounding distinct integers. Exact
        // JSON equality still resolves every collision before declaring duplicates.
        if n.is_finite() && n.trunc() == n && n >= i64::MIN as f64 && n < i64::MAX as f64 {
            return Some(mix(n as i64 as u64 ^ TYPE_NUMBER as u64));
        }
        return Some(mix(n.to_bits() ^ TYPE_NUMBER as u64));
    }
    let container = kind == TYPE_ARRAY || kind == TYPE_OBJECT;
    // Batch reuse pays for wide shared containers immediately. Small shallow
    // records keep the original cheap traversal, expanding at most four levels
    // before the depth-based cache handles deeper shared graphs.
    let cacheable = container && memo.eligible_container(depth, unsafe { len.assume_init() });
    let key = (value, depth);
    if cacheable && let Some(result) = memo.get(key) {
        return result;
    }
    let result = match kind {
        TYPE_INTEGRAL_NUMBER => Some(number::integer_fingerprint(value)),
        TYPE_NULL => Some(mix(TYPE_NULL as u64)),
        TYPE_BOOLEAN => Some(mix(if unsafe { len.assume_init() } != 0 {
            2
        } else {
            3
        })),
        TYPE_STRING => Some(bytes_fingerprint(unsafe {
            byte_view(data.assume_init().cast(), len.assume_init())
        })),
        TYPE_ARRAY => {
            let mut hash = mix(TYPE_ARRAY as u64);
            let len = unsafe { len.assume_init() };
            let values = if len == 0 {
                &[]
            } else {
                unsafe { std::slice::from_raw_parts(data.assume_init().cast::<Value>(), len) }
            };
            // All descendants are read under the GVL without allocating Ruby
            // objects or invoking Ruby callbacks, so the borrowed view is stable.
            for &item in values {
                hash =
                    mix(hash
                        ^ fingerprint_cached(item, depth + 1, fixnum_flag, false, memo, budget)?);
            }
            Some(hash)
        }
        TYPE_OBJECT => {
            let len = unsafe { len.assume_init() };
            let mut c = FingerprintContext {
                hash: 0,
                depth: depth + 1,
                fixnum_flag,
                memo,
                budget,
            };
            let status = unsafe {
                sn_hash_each_key_view(
                    value,
                    (&mut c as *mut FingerprintContext<'_>).cast(),
                    fingerprint_entry,
                )
            };
            (status == VERDICT_VALID).then(|| mix(c.hash ^ len as u64 ^ TYPE_OBJECT as u64))
        }
        _ => None,
    };
    if cacheable {
        memo.record(key, result);
    }
    result
}
struct FingerprintContext<'a> {
    hash: u64,
    depth: usize,
    fixnum_flag: Value,
    memo: &'a mut structural::Cache<(Value, usize), Option<u64>>,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn fingerprint_entry(
    context: *mut c_void,
    data: *const u8,
    len: usize,
    value: Value,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &mut *context.cast::<FingerprintContext<'_>>() };
        if !c.budget.checkpoint() {
            return Unsupported as i32;
        }
        let Some(hash) = fingerprint_cached(value, c.depth, c.fixnum_flag, false, c.memo, c.budget)
        else {
            return Unsupported as i32;
        };
        c.hash ^= mix(bytes_fingerprint(unsafe { byte_view(data, len) }) ^ hash.rotate_left(17));
        Valid as i32
    }))
    .unwrap_or(Unsupported as i32)
}
// Fingerprints are already mixed uniformly. Rehashing each u64 with SipHash
// adds work without changing collision resolution, which always uses JSON equality.
#[derive(Default)]
struct BucketHasher(u64);
impl Hasher for BucketHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write_u64(&mut self, value: u64) {
        self.0 = value;
    }
    fn write(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.0 = mix(self.0 ^ byte as u64);
        }
    }
}
fn unique(value: Value, depth: usize, fixnum_flag: Value, budget: &budget::Budget) -> Verdict {
    let len = unsafe { sn_len(value) };
    if !budget.checkpoint() {
        return Unsupported;
    }
    if len <= 16 {
        for i in 0..len {
            for previous in 0..i {
                match equal_budgeted(
                    unsafe { sn_entry(value, previous) },
                    unsafe { sn_entry(value, i) },
                    depth,
                    budget,
                ) {
                    Valid => return Invalid,
                    Unsupported => return Unsupported,
                    Invalid => {}
                }
            }
        }
        return Valid;
    }
    let values = unsafe { std::slice::from_raw_parts(sn_array_data(value), len) };
    // This is a checked optimization hint, not an instance shape assumption.
    let big_hint = unsafe { sn_is_bignum(values[0]) } != 0;
    if big_hint
        && !budget.timed()
        && depth <= MAX_EVALUATION_DEPTH
        && let Some(result) = number::ordered_big_unique(values)
    {
        return result;
    }
    if big_hint && depth <= MAX_EVALUATION_DEPTH {
        let result = unordered_big_unique(values, budget);
        if result != Unsupported {
            return result;
        }
    }
    let mut fingerprints = structural::Cache::batch(depth);
    indexed_unique(
        values,
        |item| {
            fingerprint_cached(
                item,
                depth,
                fixnum_flag,
                big_hint,
                &mut fingerprints,
                budget,
            )
        },
        |a, b| equal_budgeted(a, b, depth, budget),
    )
}
// Keep Big-only sampling and retry state out of the common scalar path.
#[inline(never)]
fn unordered_big_unique(values: &[Value], budget: &budget::Budget) -> Verdict {
    let mut all_big = true;
    let result = indexed_unique_short(
        values,
        |item| {
            if !budget.checkpoint() {
                return None;
            }
            let hash = number::big_low_fingerprint(item);
            if hash.is_none() {
                all_big = false;
            }
            hash
        },
        |a, b| {
            if !budget.checkpoint() {
                return Unsupported;
            }
            // Distinct integers sharing the short sample need the wider pass.
            if unsafe { sn_big_equal(a, b) } != 0 {
                Valid
            } else {
                Unsupported
            }
        },
    );
    if result != Unsupported {
        return result;
    }
    if all_big {
        let result = indexed_unique_impl::<true>(
            values,
            |item| {
                if !budget.checkpoint() {
                    None
                } else {
                    number::big_low64_fingerprint(item)
                }
            },
            |a, b| {
                if !budget.checkpoint() {
                    return Unsupported;
                }
                verdict(unsafe { sn_big_equal(a, b) } != 0)
            },
        );
        if result != Unsupported {
            return result;
        }
        let result = indexed_unique(
            values,
            |item| {
                if !budget.checkpoint() {
                    None
                } else {
                    number::big_only_fingerprint(item)
                }
            },
            |a, b| {
                if !budget.checkpoint() {
                    return Unsupported;
                }
                verdict(unsafe { sn_big_equal(a, b) } != 0)
            },
        );
        if result != Unsupported {
            return result;
        }
    }
    // A non-Bignum invalidates both Big-only hash conventions. Restart
    // from the original array so equal Integer/Float pairs share a bucket.
    Unsupported
}
fn indexed_unique(
    values: &[Value],
    fingerprint: impl FnMut(Value) -> Option<u64>,
    equal: impl FnMut(Value, Value) -> Verdict,
) -> Verdict {
    indexed_unique_impl::<false>(values, fingerprint, equal)
}
fn indexed_unique_short(
    values: &[Value],
    fingerprint: impl FnMut(Value) -> Option<u64>,
    equal: impl FnMut(Value, Value) -> Verdict,
) -> Verdict {
    // Index zero means empty. Choose a larger slot beyond the 16-bit limit
    // so the short sample remains available without truncating an index.
    if values.len() > u32::MAX as usize {
        return Unsupported;
    }
    let Some(capacity) = values
        .len()
        .checked_mul(2)
        .and_then(usize::checked_next_power_of_two)
    else {
        return Unsupported;
    };
    if values.len() <= u16::MAX as usize {
        indexed_unique_slots::<ShortUniqueSlot, true>(values, capacity, fingerprint, equal)
    } else {
        indexed_unique_slots::<ShortWideUniqueSlot, true>(values, capacity, fingerprint, equal)
    }
}
fn indexed_unique_impl<const BOUNDED: bool>(
    values: &[Value],
    fingerprint: impl FnMut(Value) -> Option<u64>,
    equal: impl FnMut(Value, Value) -> Verdict,
) -> Verdict {
    let Some(capacity) = values
        .len()
        .checked_mul(2)
        .and_then(usize::checked_next_power_of_two)
    else {
        return Unsupported;
    };
    if values.len() <= u16::MAX as usize {
        indexed_unique_slots::<PackedUniqueSlot, BOUNDED>(values, capacity, fingerprint, equal)
    } else {
        indexed_unique_slots::<FullUniqueSlot, BOUNDED>(values, capacity, fingerprint, equal)
    }
}
trait UniqueSlot: Copy {
    const EMPTY: Self;
    fn new(hash: u64, index: usize) -> Self;
    fn index(self) -> Option<usize>;
    fn matches(self, hash: u64) -> bool;
}
#[derive(Clone, Copy)]
struct ShortUniqueSlot(u32);
impl UniqueSlot for ShortUniqueSlot {
    const EMPTY: Self = Self(0);
    fn new(hash: u64, index: usize) -> Self {
        debug_assert!(index < u16::MAX as usize);
        Self((hash as u32 & !0xffff) | (index + 1) as u32)
    }
    fn index(self) -> Option<usize> {
        let index = self.0 & 0xffff;
        (index != 0).then(|| index as usize - 1)
    }
    fn matches(self, hash: u64) -> bool {
        // Truncated filters only select an exact comparison or wider retry.
        self.0 & !0xffff == hash as u32 & !0xffff
    }
}
#[derive(Clone, Copy)]
struct ShortWideUniqueSlot(u64);
impl UniqueSlot for ShortWideUniqueSlot {
    const EMPTY: Self = Self(0);
    fn new(hash: u64, index: usize) -> Self {
        debug_assert!(index < u32::MAX as usize);
        Self((u64::from(hash as u32) << 32) | (index + 1) as u64)
    }
    fn index(self) -> Option<usize> {
        let index = self.0 as u32;
        (index != 0).then(|| index as usize - 1)
    }
    fn matches(self, hash: u64) -> bool {
        self.0 >> 32 == u64::from(hash as u32)
    }
}
#[derive(Clone, Copy)]
struct PackedUniqueSlot(u64);
impl UniqueSlot for PackedUniqueSlot {
    const EMPTY: Self = Self(0);
    fn new(hash: u64, index: usize) -> Self {
        // Selected only for at most 65535 entries. Zero is the empty marker;
        // the remaining 48 hash bits only filter exact JSON comparisons.
        debug_assert!(index < u16::MAX as usize);
        Self((hash & !0xffff) | (index + 1) as u64)
    }
    fn index(self) -> Option<usize> {
        let index = self.0 & 0xffff;
        (index != 0).then(|| index as usize - 1)
    }
    fn matches(self, hash: u64) -> bool {
        self.0 & !0xffff == hash & !0xffff
    }
}
#[derive(Clone, Copy)]
struct FullUniqueSlot(u64, usize);
impl UniqueSlot for FullUniqueSlot {
    const EMPTY: Self = Self(0, usize::MAX);
    fn new(hash: u64, index: usize) -> Self {
        Self(hash, index)
    }
    fn index(self) -> Option<usize> {
        (self.1 != usize::MAX).then_some(self.1)
    }
    fn matches(self, hash: u64) -> bool {
        self.0 == hash
    }
}
fn indexed_unique_slots<S: UniqueSlot, const BOUNDED: bool>(
    values: &[Value],
    capacity: usize,
    mut fingerprint: impl FnMut(Value) -> Option<u64>,
    mut equal: impl FnMut(Value, Value) -> Verdict,
) -> Verdict {
    // Keep at least half the slots empty, so every probe terminates. Slots
    // retain only a fingerprint and an index into the original Ruby array.
    // Equal fingerprints continue probing after exact inequality; neither
    // table-position collisions nor fingerprint collisions imply duplicates.
    let Some(mut slots) = allocate_unique_slots::<S>(capacity) else {
        return Unsupported;
    };
    let mask = capacity - 1;
    let mut collisions = 0;
    let mut probes = 0;
    for (i, &item) in values.iter().enumerate() {
        let Some(hash) = fingerprint(item) else {
            return Unsupported;
        };
        let mut at = hash as usize & mask;
        loop {
            let slot = slots[at];
            let Some(previous) = slot.index() else {
                slots[at] = S::new(hash, i);
                break;
            };
            // A full fingerprint can still have adversarial low table bits.
            // Bound probing independently of exact fingerprint collisions.
            probes += 1;
            if probes > values.len().saturating_mul(2) {
                if BOUNDED {
                    return Unsupported;
                }
                // Release the hash table before allocating the flat index.
                drop(slots);
                return sorted_unique(values, fingerprint, equal);
            }
            if slot.matches(hash) {
                match equal(values[previous], item) {
                    Valid => return Invalid,
                    Unsupported => return Unsupported,
                    Invalid => {
                        if BOUNDED {
                            collisions += 1;
                            if collisions >= 16 {
                                return Unsupported;
                            }
                        }
                    }
                }
            }
            at = (at + 1) & mask;
        }
    }
    Valid
}
fn sorted_unique(
    values: &[Value],
    mut fingerprint: impl FnMut(Value) -> Option<u64>,
    mut equal: impl FnMut(Value, Value) -> Verdict,
) -> Verdict {
    let Some(bytes) = values
        .len()
        .checked_mul(std::mem::size_of::<(u64, usize)>())
    else {
        return Unsupported;
    };
    if bytes > MAX_UNIQUE_INDEX_BYTES {
        return Unsupported;
    }
    let mut entries = Vec::new();
    if entries.try_reserve_exact(values.len()).is_err() {
        return Unsupported;
    }
    for (index, &value) in values.iter().enumerate() {
        let Some(hash) = fingerprint(value) else {
            break;
        };
        entries.push((hash, index));
    }
    let complete = entries.len() == values.len();
    // O(n log n) sorting replaces quadratic slot probing. Exact equality is
    // needed only within identical full fingerprints, in original array order.
    entries.sort_unstable();
    let mut decisive: Option<(usize, Verdict)> = None;
    for group in entries.chunk_by(|a, b| a.0 == b.0) {
        for at in 1..group.len() {
            let index = group[at].1;
            if decisive.is_some_and(|(earlier, _)| earlier <= index) {
                break;
            }
            for &(_, previous) in &group[..at] {
                let status = equal(values[previous], values[index]);
                if status != Invalid {
                    decisive = Some((index, status));
                    break;
                }
            }
        }
    }
    // A duplicate in the successfully fingerprinted prefix must precede a
    // later unavailable fingerprint, just as it does in the streaming index.
    decisive.map_or(if complete { Valid } else { Unsupported }, |(_, status)| {
        if status == Valid { Invalid } else { status }
    })
}
fn allocate_unique_slots<S: UniqueSlot>(capacity: usize) -> Option<Vec<S>> {
    let bytes = capacity.checked_mul(std::mem::size_of::<S>())?;
    if bytes > MAX_UNIQUE_INDEX_BYTES {
        return None;
    }
    let mut slots = Vec::new();
    slots.try_reserve_exact(capacity).ok()?;
    slots.resize(capacity, S::EMPTY);
    Some(slots)
}
struct PropertyCandidates<'a> {
    rules: &'a Object,
    indices: Vec<usize>,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn property_candidate(context: *mut c_void, key: Value, _: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &mut *context.cast::<PropertyCandidates<'_>>() };
        if !c.budget.checkpoint() {
            return Unsupported as i32;
        }
        if unsafe { sn_kind(key) } != TYPE_STRING {
            return Unsupported as i32;
        }
        if let Some(target) = c.rules.property_targets.get(&tracking::JsonKey::new(key)) {
            c.indices.push(target.index);
        }
        Valid as i32
    }))
    .unwrap_or(Unsupported as i32)
}

struct ObjectContext<'a> {
    engine: &'a Execution<'a>,
    rules: &'a Object,
    depth: usize,
    active: scope::Context<'a>,
}
/// Called synchronously by the C hash iterator. This never calls allocating Ruby APIs.
/// # Safety
/// The context must be a live ObjectContext from this engine and all VALUEs must be live under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_object_entry(context: *const c_void, key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &*context.cast::<ObjectContext>() };
        if !c.engine.budget.checkpoint() {
            return Unsupported as i32;
        }
        if unsafe { sn_kind(key) } != TYPE_STRING {
            return Unsupported as i32;
        }
        if let Some(child) = c.rules.names {
            let result = c.engine.eval(child, key, c.depth, c.active);
            if result != Valid {
                return result as i32;
            }
        }
        match c.rules.visit_value_rules::<false>(
            c.engine.caches,
            &c.engine.budget,
            key,
            None,
            |_, _, child| match c.engine.eval(child, value, c.depth, c.active) {
                Valid => Ok(()),
                status => Err(status),
            },
        ) {
            Ok(_) => Valid as i32,
            Err(status) => status as i32,
        }
    }))
    .unwrap_or(Unsupported as i32)
}
#[unsafe(no_mangle)]
pub extern "C" fn sn_new() -> *mut Engine {
    Box::into_raw(Box::new(Engine {
        roots: Box::into_raw(Box::new(Roots::default())),
        fixnum_flag: unsafe { sn_fixnum_flag() },
        undefined: unsafe { sn_undefined() },
        ..Engine::default()
    }))
}
/// # Safety
/// Engine/error must be writable. Program must be a live VM Program (or Array
/// of Programs when multiple is set), and compiler must be live under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_compile(
    engine: *mut Engine,
    program: Value,
    compiler: Value,
    format: i32,
    content: i32,
    multiple: i32,
    error: *mut Value,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &mut *engine };
        e.validate_format = format != 0;
        e.validate_content = content != 0;
        e.compiler = e.retain(compiler);
        if multiple != 0 {
            for program in e.values(program) {
                e.compile(program)?;
            }
        } else {
            e.root = e.compile(program)?;
        }
        e.bind_dynamic_anchors()?;
        e.simplify_dynamic_references();
        e.compile_memoization();
        Ok::<_, Value>(())
    })) {
        Ok(Ok(())) => VERDICT_VALID,
        Ok(Err(value)) => {
            unsafe { *error = value };
            STATUS_EXCEPTION
        }
        Err(_) => STATUS_PANIC,
    }
}
/// # Safety
/// Engine must be fully initialized and program must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_node_index(engine: *const Engine, program: Value) -> usize {
    unsafe { &*engine }
        .indices
        .get(&program)
        .copied()
        .unwrap_or(usize::MAX)
}
/// # Safety
/// Engine must be initialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_index(engine: *const Engine) -> usize {
    unsafe { &*engine }.root
}
/// # Safety
/// Roots must be live and compilation must have finished.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_count(roots: *const Roots) -> usize {
    unsafe { &*roots }.values.len()
}
/// # Safety
/// Roots must be live and index in bounds, outside compilation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_at(roots: *const Roots, index: usize) -> Value {
    unsafe { &*roots }.values[index]
}
/// # Safety
/// Engine must be initialized, root in bounds and value live under the GVL.
/// Caches must be null or live, owned by this validator and not in use.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_valid(
    engine: *const Engine,
    caches: *const pattern::Caches,
    root: usize,
    value: Value,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &*engine };
        let local = pattern::Caches::default();
        let caches = unsafe { caches.as_ref() }.unwrap_or(&local);
        Execution {
            engine: e,
            caches,
            memo: memo::Memo::default(),
            budget: budget::Budget::default(),
        }
        .eval(root, value, 0, scope::Context::default()) as i32
    }))
    .unwrap_or(STATUS_PANIC)
}
/// # Safety
/// Same requirements as sn_valid; all limit/output pointers must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_valid_with_limits(
    engine: *const Engine,
    caches: *const pattern::Caches,
    root: usize,
    value: Value,
    limits: *const budget::Limits,
    outcome: *mut budget::Outcome,
) -> i32 {
    let budget = budget::Budget::new(unsafe { *limits });
    let result = catch_unwind(AssertUnwindSafe(|| {
        let local = pattern::Caches::default();
        let caches = unsafe { caches.as_ref() }.unwrap_or(&local);
        let execution = Execution {
            engine: unsafe { &*engine },
            caches,
            memo: memo::Memo::default(),
            budget,
        };
        let result = if execution.budget.check_deadline() {
            execution.eval(root, value, 0, scope::Context::default())
        } else {
            Unsupported
        };
        let result = if execution.budget.check_deadline() {
            result
        } else {
            Unsupported
        };
        unsafe {
            ((*outcome).kind, (*outcome).attempted) = execution.budget.hit.get();
        }
        result as i32
    }));
    result.unwrap_or(STATUS_PANIC)
}
/// # Safety
/// Engine must be an owned pointer returned by sn_new, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_free(engine: *mut Engine) {
    let engine = unsafe { Box::from_raw(engine) };
    drop(unsafe { Box::from_raw(engine.roots) });
    drop(engine);
}
/// # Safety
/// Engine must be live and not exclusively borrowed by the compiler.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_roots(engine: *const Engine) -> *const Roots {
    unsafe { &*engine }.roots
}
/// # Safety
/// Roots must be live; call synchronously from the owning Ruby GC mark callback.
/// No mutable root borrow can be live across a Ruby allocation/callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_roots_mark(roots: *const Roots) {
    for &value in unsafe { &*roots }
        .values
        .iter()
        .chain(&unsafe { &*roots }.binding_names)
    {
        unsafe { sn_pin(value) };
    }
}
/// # Safety
/// Roots must be live with no mutable root borrow active.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_roots_size(roots: *const Roots) -> usize {
    std::mem::size_of::<Roots>()
        + (unsafe { &*roots }.values.capacity() + unsafe { &*roots }.binding_names.capacity())
            * std::mem::size_of::<Value>()
}
#[unsafe(no_mangle)]
pub extern "C" fn sn_engine_header_size() -> usize {
    std::mem::size_of::<Engine>()
}
/// # Safety
/// Engine must be live and not exclusively borrowed by the compiler.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_size(engine: *const Engine) -> usize {
    let nodes = unsafe { &*std::ptr::addr_of!((*engine).nodes) };
    let operands = unsafe { &*std::ptr::addr_of!((*engine).error_operands) };
    let contextual = unsafe { &*std::ptr::addr_of!((*engine).memo_contextual) };
    let guarded = unsafe { &*std::ptr::addr_of!((*engine).memo_guarded) };
    let sources = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_sources) };
    let same = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_same_sources) };
    let scalar = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_scalar_sources) };
    let amplification = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_scalar_amplification) };
    let projection = unsafe { &*std::ptr::addr_of!((*engine).memo_scope_projection) };
    std::mem::size_of::<Engine>()
        + projection.memory_usage()
        + (contextual.capacity()
            + guarded.capacity()
            + sources.capacity()
            + same.capacity()
            + scalar.capacity()
            + amplification.capacity())
            * std::mem::size_of::<bool>()
        + nodes.capacity() * std::mem::size_of::<Vec<Op>>()
        + operands.capacity() * std::mem::size_of::<Vec<(i32, Value)>>()
        + operands
            .iter()
            .map(|ops| ops.capacity() * std::mem::size_of::<(i32, Value)>())
            .sum::<usize>()
        + nodes
            .iter()
            .map(|n| n.capacity() * std::mem::size_of::<Op>())
            .sum::<usize>()
        + nodes
            .iter()
            .flatten()
            .map(|op| match op {
                Op::Enum(values) => values.memory_usage(),
                Op::String(_, rules) => {
                    std::mem::size_of::<StringRules>()
                        + rules
                            .pattern
                            .as_ref()
                            .map_or(0, pattern::Pattern::memory_usage)
                }
                Op::Object(_, rules) => {
                    rules
                        .pattern_group
                        .as_ref()
                        .map_or(0, pattern::PatternGroup::memory_usage)
                        + rules.patterns.capacity()
                            * std::mem::size_of::<(pattern::Pattern, usize)>()
                        + rules
                            .patterns
                            .iter()
                            .map(|(pattern, _)| pattern.memory_usage())
                            .sum::<usize>()
                }
                _ => 0,
            })
            .sum::<usize>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn falls_back_for_clustered_slots_without_comparing_distinct_fingerprints() {
        let values: Vec<_> = (1..=4096).collect();
        let mut hashes = 0;
        assert_eq!(
            indexed_unique(
                &values,
                |value| {
                    hashes += 1;
                    Some((value as u64) << 32)
                },
                |_, _| panic!("distinct full fingerprints cannot require equality"),
            ),
            Valid
        );
        assert!(hashes > values.len());
        assert!(hashes <= values.len() * 2);
    }

    #[test]
    fn sorted_collisions_preserve_exact_equality_and_early_results() {
        let hash = |value| (value != 99).then_some(value as u64 % 2);
        let equal = |a, b| verdict(a == b);
        assert_eq!(sorted_unique(&[0, 2, 4, 1, 3, 5], hash, equal), Valid);
        assert_eq!(sorted_unique(&[0, 2, 0, 99], hash, equal), Invalid);
        assert_eq!(sorted_unique(&[0, 2, 99, 0], hash, equal), Unsupported);
        assert_eq!(
            sorted_unique(&[0, 1, 1, 2], hash, |a, b| {
                if (a, b) == (0, 2) {
                    Unsupported
                } else {
                    equal(a, b)
                }
            }),
            Invalid
        );
        assert_eq!(
            sorted_unique(&[0, 2, 1, 1], hash, |a, b| {
                if (a, b) == (0, 2) {
                    Unsupported
                } else {
                    equal(a, b)
                }
            }),
            Unsupported
        );
    }

    #[test]
    fn bounds_unique_index_allocation() {
        assert_eq!(
            allocate_unique_slots::<FullUniqueSlot>(16).unwrap().len(),
            16
        );
        let over_limit = MAX_UNIQUE_INDEX_BYTES / std::mem::size_of::<FullUniqueSlot>() + 1;
        assert!(allocate_unique_slots::<FullUniqueSlot>(over_limit).is_none());
        assert!(allocate_unique_slots::<FullUniqueSlot>(usize::MAX).is_none());
    }
}
