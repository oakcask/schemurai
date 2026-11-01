//! A VM over borrowed CRuby VALUE handles. No instance decoding or serialization.
//! Ruby runs with the GVL held. Evaluation calls only non-allocating C adapters;
//! Ruby callbacks during compilation are protected on the C side.
use std::collections::HashMap;
use std::ffi::c_void;
use std::hash::{BuildHasherDefault, Hasher};
use std::panic::{AssertUnwindSafe, catch_unwind};
mod budget;
mod container;
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
mod pointer;
mod runtime;
mod string;
// Some shared constants are consumed only by C or Ruby.
#[allow(dead_code)]
mod protocol {
    include!(concat!(env!("OUT_DIR"), "/protocol.rs"));
}
use protocol::*;
mod ruby;
mod ruby_trace;
mod scope;
mod structural;
mod tracking;
use ruby::*;
use ruby_trace::{Trace, trace_fields};
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(i32)]
enum Verdict {
    Invalid = VERDICT_INVALID,
    Valid = VERDICT_VALID,
    Unsupported = VERDICT_UNSUPPORTED,
}
use Verdict::*;
const MAX_EVALUATION_DEPTH: usize = 256;
// Control-flow instructions can forward an instance without examining its kind.
// No real classified Ruby value has this kind.
const TYPE_UNCHECKED: i32 = 0;
type InstanceKind = std::cell::Cell<i32>;
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum KindDemand {
    None,
    Predicate,
    Data,
}
const MAX_UNIQUE_INDEX_BYTES: usize = 64 * 1024 * 1024;
#[derive(Debug)]
enum Op {
    Unsupported,
    UnresolvedRef(Value),
    Boolean(bool),
    Ref(scope::Reference),
    Type(i32, bool),
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
    header: container::Header,
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
    count_contains: bool,
    unevaluated: Option<usize>,
}
#[derive(Debug)]
struct StringRules {
    source: Value,
    runtime_flags: i32,
    runtime_format: bool,
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
    fn eval_length_guarded(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
    ) -> Verdict {
        if caches.dynamic_calls() {
            return self.runtime_valid(caches, required, value);
        }
        let result = length_guarded(value, required, self.min, self.max);
        if result == Unsupported {
            self.runtime_valid(caches, required, value)
        } else {
            result
        }
    }
    fn eval_guarded(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
    ) -> Verdict {
        if caches.dynamic_calls() {
            return self.runtime_valid(caches, required, value);
        }
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_pattern_item_view(value, &mut data, &mut len) };
        if encoding == -TYPE_UNSUPPORTED {
            self.runtime_valid(caches, required, value)
        } else if encoding < 0 {
            verdict(required == 0)
        } else {
            let bytes = unsafe { vm.bytes(data, len) };
            self.eval_with_view::<true>(vm, caches, value, Some((bytes, encoding)))
        }
    }
    fn eval(&self, vm: &Ruby, caches: &runtime::Caches, value: Value) -> Verdict {
        self.eval_with_view::<false>(vm, caches, value, None)
    }
    fn eval_with_view<const BORROWED: bool>(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
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
                Some((bytes, encoding)) => pattern.eval_bytes(caches, value, bytes, encoding),
                None => pattern.assertion(vm, caches, value),
            };
            if result != Valid {
                return result;
            }
        }
        if let Some(format) = &self.format {
            let result = match view {
                Some((bytes, _)) => format.eval_bytes(bytes),
                None => format.eval(vm, value),
            };
            if result != Valid {
                return result;
            }
        }
        self.content.as_ref().map_or(Valid, |content| match view {
            Some((bytes, encoding)) => content.eval_borrowed(vm, caches, value, bytes, encoding),
            None => content.eval(vm, caches, value),
        })
    }
}
#[derive(Debug)]
enum DiagnosticDependency {
    Required(Value, Vec<RequiredKey>, &'static str),
    Schema(Value, usize, &'static str),
}
// Keep ordinary String lookups native; other operands may dispatch Ruby hash
// methods. Retain the original value for runtime lookup and ordered rendering.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RequiredKey {
    name: Value,
    ordinary_string: bool,
}
impl RequiredKey {
    fn missing(
        self,
        caches: &runtime::Caches,
        value: Value,
        undefined: Value,
    ) -> Result<bool, Verdict> {
        if self.ordinary_string {
            Ok(missing(value, self.name, undefined))
        } else {
            match caches.required_missing(self.name, value) {
                Valid => Ok(true),
                Invalid => Ok(false),
                Unsupported => Err(Unsupported),
            }
        }
    }
}
#[derive(Clone, Copy, Debug)]
struct PropertyTarget {
    name: Value,
    child: usize,
    index: usize,
}
#[derive(Debug)]
struct Object {
    header: container::Header,
    inspect_required: bool,
    record: Option<RecordObject>,
    min: Option<usize>,
    max: Option<usize>,
    required: Vec<RequiredKey>,
    required_order: Vec<RequiredKey>,
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
    dependent_required: Vec<(Value, Vec<RequiredKey>)>,
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
    fn check_required(
        &self,
        caches: &runtime::Caches,
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        Self::check_keys(&self.required, caches, value, undefined, budget)
    }
    fn check_keys(
        keys: &[RequiredKey],
        caches: &runtime::Caches,
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        for &key in keys {
            if !budget.checkpoint() {
                return Unsupported;
            }
            match key.missing(caches, value, undefined) {
                Ok(false) => {}
                Ok(true) => return Invalid,
                Err(status) => return status,
            }
        }
        Valid
    }
    fn check_dependent_required(
        &self,
        caches: &runtime::Caches,
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        for (name, required) in &self.dependent_required {
            if !budget.checkpoint() {
                return Unsupported;
            }
            if !missing(value, *name, undefined) {
                let status = Self::check_keys(required, caches, value, undefined, budget);
                if status != Valid {
                    return status;
                }
            }
        }
        Valid
    }
    fn visit_properties(
        &self,
        vm: &Ruby,
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
                vm,
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
    fn visit_value_rules(
        &self,
        vm: &Ruby,
        caches: &runtime::Caches,
        budget: &budget::Budget,
        properties: bool,
        (key, location): (Value, Option<tracking::JsonKey>),
        mut visit: impl FnMut(&'static str, Option<Value>, usize) -> Result<(), Verdict>,
    ) -> Result<bool, Verdict> {
        // Tracked scans already fingerprinted this key for location lookup.
        // Reuse that result, and skip hashing for pattern-only object rules.
        let mut matched = if self.properties.is_empty() {
            false
        } else if properties {
            if let Some(target) = self
                .property_targets
                .get(&location.unwrap_or_else(|| tracking::JsonKey::new(vm, key)))
            {
                visit("properties", Some(target.name), target.child)?;
                true
            } else {
                false
            }
        } else {
            self.property_keys
                .contains(&location.unwrap_or_else(|| tracking::JsonKey::new(vm, key)))
        };
        if let Some(mut matches) = self
            .pattern_group
            .as_ref()
            .and_then(|group| group.matches(vm, key))
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
                match pattern.eval(vm, caches, key) {
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

    fn with_record(mut self, vm: &Ruby) -> Self {
        if self.required_order.len() > 64
            || self.required_order.iter().any(|key| !key.ordinary_string)
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
                    tracking::JsonKey::new(vm, name),
                    RecordField {
                        key: name,
                        name,
                        short_key: short_record_key(vm, name),
                        child: Some(child),
                        bit: 0,
                        check: None,
                    },
                )
            })
            .collect();
        for key in &self.required_order {
            let name = key.name;
            fields
                .entry(tracking::JsonKey::new(vm, name))
                .or_insert(RecordField {
                    key: name,
                    name,
                    short_key: short_record_key(vm, name),
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
        let required = self.required_order.iter().fold(0, |bits, key| {
            bits | fields[&tracking::JsonKey::new(vm, key.name)].bit
        });
        let fields: Vec<_> = fields.into_values().collect();
        let short_index = RecordShortIndex::compile(&fields);
        self.record = Some(RecordObject {
            identity_hint: self
                .properties
                .first()
                .map_or(Value::default(), |&(key, _)| key),
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
trace_fields!(Roots { values, binding_names ; });
#[derive(Default)]
pub struct Engine {
    nodes: Vec<Vec<Op>>,
    programs: Vec<Value>,
    pattern_cache_count: usize,
    error_operands: Vec<Vec<(i32, Value)>>,
    tracks: Vec<bool>,
    kind_demand: Vec<KindDemand>,
    callback_roots: Vec<bool>,
    validity_supported: Vec<bool>,
    report_supported: Vec<bool>,
    has_references: bool,
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
    fixnum_flag: usize,
    compiler: Value,
    runtime_messages: bool,
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
    fn field(&mut self, vm: &mut Ruby, value: Value, name: i32) -> Result<Value, Value> {
        let mut result = Value::default();
        if unsafe { vm.sn_field(value, name, &mut result) } != 0 {
            return Err(result);
        }
        Ok(self.retain(result))
    }
    fn required_keys(&mut self, value: Value) -> Vec<RequiredKey> {
        // Non-array operands retain their Ruby iteration/error behavior in a
        // runtime frame; they cannot authorize borrowed Array storage.
        if unsafe { sn_kind(value) } != TYPE_ARRAY {
            return vec![];
        }
        self.values(value)
            .into_iter()
            .map(|name| {
                let ordinary_string = unsafe { sn_kind(name) } == TYPE_STRING;
                self.runtime_messages |= !ordinary_string;
                RequiredKey {
                    name,
                    ordinary_string,
                }
            })
            .collect()
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
    fn map(&mut self, vm: &mut Ruby, value: Value) -> Result<Vec<(Value, Value)>, Value> {
        if unsafe { sn_same(value, sn_nil()) } != 0 {
            return Ok(vec![]);
        }
        let mut pairs = Value::default();
        if unsafe { vm.sn_pairs(value, &mut pairs) } != 0 {
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
    fn size_field(
        &mut self,
        vm: &mut Ruby,
        value: Value,
        name: i32,
    ) -> Result<Option<usize>, Value> {
        let n = self.field(vm, value, name)?;
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
    fn child(&mut self, vm: &mut Ruby, value: Value, name: i32) -> Result<Option<usize>, Value> {
        let child = self.field(vm, value, name)?;
        if unsafe { sn_same(child, sn_nil()) } != 0 {
            Ok(None)
        } else {
            self.compile(vm, child).map(Some)
        }
    }
    fn children(&mut self, vm: &mut Ruby, value: Value) -> Result<Vec<usize>, Value> {
        self.values(value)
            .into_iter()
            .map(|c| self.compile(vm, c))
            .collect()
    }
    fn branches(&mut self, vm: &mut Ruby, value: Value) -> Result<Vec<(usize, usize)>, Value> {
        let nodes = self.children(vm, value)?;
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
                            ([Op::Type(a, ua)], [Op::Type(b, ub)]) => a == b && ua == ub,
                            ([Op::Boolean(a)], [Op::Boolean(b)]) => a == b,
                            _ => false,
                        }
                })
    }
    fn compile_map(&mut self, vm: &mut Ruby, value: Value) -> Result<Vec<(Value, usize)>, Value> {
        self.map(vm, value)?
            .into_iter()
            .map(|(k, c)| Ok((k, self.compile(vm, c)?)))
            .collect()
    }
    fn compile(&mut self, vm: &mut Ruby, program: Value) -> Result<usize, Value> {
        if let Some(&i) = self.indices.get(&program) {
            return Ok(i);
        }
        self.retain(program);
        let index = self.nodes.len();
        self.indices.insert(program, index);
        self.nodes.push(vec![]);
        self.programs.push(program);
        self.error_operands.push(vec![]);
        self.tracks.push(false);
        self.kind_demand.push(KindDemand::None);
        self.metadata.push(scope::Metadata::default());
        let code = self.field(vm, program, FIELD_CODE)?;
        let flags = unsafe { sn_integer(sn_entry(code, 0)) };
        self.tracks[index] = flags & i64::from(TRACKS_EVALUATION) != 0;
        self.compile_scope(vm, program, index, flags)?;
        let mut ops = vec![];
        let mut error_operands = vec![];
        for i in (1..unsafe { sn_len(code) }).step_by(2) {
            let operand = self.retain(unsafe { sn_entry(code, i + 1) });
            let opcode = unsafe { sn_opcode(sn_entry(code, i)) };
            error_operands.push((opcode, operand));
            let op = match opcode {
                OP_BOOLEAN => Op::Boolean(unsafe { sn_true(operand) } != 0),
                OP_TYPE_NULL => Op::Type(TYPE_NULL, false),
                OP_TYPE_BOOLEAN => Op::Type(TYPE_BOOLEAN, false),
                OP_TYPE_OBJECT => Op::Type(TYPE_OBJECT, false),
                OP_TYPE_ARRAY => Op::Type(TYPE_ARRAY, false),
                OP_TYPE_NUMBER => Op::Type(TYPE_NUMBER, false),
                OP_TYPE_INTEGER => Op::Type(TYPE_INTEGER, false),
                OP_TYPE_STRING => Op::Type(TYPE_STRING, false),
                OP_TYPES => {
                    let mask = self.field(vm, operand, FIELD_MASK)?;
                    Op::Type(unsafe { sn_integer(mask) } as i32, true)
                }
                OP_CONST => Op::Const(operand),
                OP_ENUM => Op::Enum(Box::new(enumeration::Enumeration::compile(
                    vm,
                    operand,
                    self.values(operand),
                    self.fixnum_flag,
                ))),
                OP_ALL_OF => Op::All(self.children(vm, operand)?),
                OP_ANY_OF => Op::Any(self.branches(vm, operand)?),
                OP_ONE_OF => Op::One(self.branches(vm, operand)?),
                OP_NOT => Op::Not(self.compile(vm, operand)?),
                OP_CONDITIONAL => {
                    let condition = self.field(vm, operand, FIELD_CONDITION)?;
                    Op::Conditional(
                        self.compile(vm, condition)?,
                        self.child(vm, operand, FIELD_THEN_BRANCH)?,
                        self.child(vm, operand, FIELD_ELSE_BRANCH)?,
                    )
                }
                OP_NUMBER | OP_TYPED_NUMBER | OP_TYPED_INTEGER => {
                    if let Some(rules) = self.compile_number(vm, operand)? {
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
                    let pattern = self.field(vm, operand, FIELD_PATTERN)?;
                    let format = self.field(vm, operand, FIELD_FORMAT)?;
                    let base64 = self.field(vm, operand, FIELD_DECODE_BASE64)?;
                    let json = self.field(vm, operand, FIELD_PARSE_JSON)?;
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
                        let assertion = self.field(vm, operand, FIELD_FORMAT_ASSERTION)?;
                        let runtime_format = (self.validate_format
                            || unsafe { sn_true(assertion) } != 0)
                            && unsafe { sn_same(format, sn_nil()) } == 0;
                        let format = if runtime_format {
                            let name = self.field(vm, format, FIELD_NAME)?;
                            if unsafe { sn_same(name, sn_nil()) } != 0 {
                                None
                            } else {
                                Some(format::Format::compile(vm, name))
                            }
                        } else {
                            None
                        };
                        let max_length = self.field(vm, operand, FIELD_MAX_LENGTH)?;
                        let min_length = self.field(vm, operand, FIELD_MIN_LENGTH)?;
                        let length_flags = (unsafe { sn_truthy(max_length) } << 2)
                            | (unsafe { sn_truthy(min_length) } << 3);
                        Op::String(
                            if opcode == OP_TYPED_STRING {
                                TYPE_STRING
                            } else {
                                0
                            },
                            Box::new(StringRules {
                                source: operand,
                                runtime_flags: i32::from(self.validate_format)
                                    | (i32::from(self.validate_content) << 1)
                                    | length_flags,
                                runtime_format,
                                format,
                                content,
                                min: self.size_field(vm, operand, FIELD_MIN_LENGTH)?,
                                max: self.size_field(vm, operand, FIELD_MAX_LENGTH)?,
                                pattern: if unsafe { sn_truthy(pattern) } == 0 {
                                    None
                                } else {
                                    Some(pattern::Pattern::compile(
                                        vm,
                                        pattern,
                                        &mut self.pattern_cache_count,
                                    ))
                                },
                            }),
                        )
                    }
                }
                OP_ARRAY | OP_TYPED_ARRAY => {
                    let unique = self.field(vm, operand, FIELD_UNIQUE)?;
                    let prefix = self.field(vm, operand, FIELD_PREFIX_ITEMS)?;
                    let prefix = self.children(vm, prefix)?;
                    let items = self.field(vm, operand, FIELD_ITEMS)?;
                    let list = self.field(vm, operand, FIELD_ITEMS_LIST)?;
                    let list = unsafe { sn_true(list) } != 0;
                    let items = if list {
                        self.children(vm, items)?
                    } else if unsafe { sn_same(items, sn_nil()) } != 0 {
                        vec![]
                    } else {
                        vec![self.compile(vm, items)?]
                    };
                    Op::Array(
                        if opcode == OP_TYPED_ARRAY {
                            TYPE_ARRAY
                        } else {
                            0
                        },
                        Box::new(Array {
                            header: self.container_header(
                                vm,
                                operand,
                                FIELD_MAX_ITEMS,
                                FIELD_MIN_ITEMS,
                                false,
                                (if unsafe { sn_truthy(unique) } != 0 {
                                    4
                                } else {
                                    0
                                }) | (if list { 8 } else { 0 }),
                            )?,
                            unique: unsafe { sn_truthy(unique) } != 0,
                            min: self.size_field(vm, operand, FIELD_MIN_ITEMS)?,
                            max: self.size_field(vm, operand, FIELD_MAX_ITEMS)?,
                            prefix,
                            items,
                            list,
                            additional: self.child(vm, operand, FIELD_ADDITIONAL)?,
                            contains: self.child(vm, operand, FIELD_CONTAINS)?,
                            min_contains: self
                                .size_field(vm, operand, FIELD_MIN_CONTAINS)?
                                .unwrap_or(1),
                            max_contains: self.size_field(vm, operand, FIELD_MAX_CONTAINS)?,
                            count_contains: unsafe {
                                sn_true(self.field(vm, operand, FIELD_COUNT_CONTAINS)?)
                            } != 0,
                            unevaluated: self.child(vm, operand, FIELD_UNEVALUATED)?,
                        }),
                    )
                }
                OP_OBJECT | OP_TYPED_OBJECT => {
                    let patterns = self.field(vm, operand, FIELD_PATTERNS)?;
                    let dependencies = self.field(vm, operand, FIELD_DEPENDENCIES)?;
                    {
                        let patterns = self.compile_map(vm, patterns)?;
                        let pattern_names: Vec<_> = patterns.iter().map(|&(key, _)| key).collect();
                        let patterns: Vec<_> = patterns
                            .into_iter()
                            .map(|(key, child)| {
                                (
                                    pattern::Pattern::compile(
                                        vm,
                                        key,
                                        &mut self.pattern_cache_count,
                                    ),
                                    child,
                                )
                            })
                            .collect();
                        let pattern_group =
                            pattern::PatternGroup::compile(vm, &pattern_names, &patterns);
                        let required = self.field(vm, operand, FIELD_REQUIRED)?;
                        let inspect_required = unsafe { sn_truthy(required) } != 0
                            && !(unsafe { sn_kind(required) } == TYPE_ARRAY
                                && unsafe { sn_len(required) } == 0);
                        let required = self.required_keys(required);
                        let required_order = required.clone();
                        let required_strings: Vec<_> = required
                            .iter()
                            .filter(|key| key.ordinary_string)
                            .map(|key| key.name)
                            .collect();
                        let properties = self.field(vm, operand, FIELD_PROPERTIES)?;
                        let properties = self.compile_map(vm, properties)?;
                        if properties
                            .iter()
                            .any(|&(key, _)| unsafe { sn_kind(key) } != TYPE_STRING)
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
                                        tracking::JsonKey::new(vm, name),
                                        PropertyTarget { name, child, index },
                                    )
                                })
                                .collect();
                        let property_locations: Vec<_> = properties
                            .iter()
                            .map(|&(key, _)| tracking::JsonKey::new(vm, key))
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
                            required_strings
                                .iter()
                                .map(|&name| tracking::JsonKey::new(vm, name))
                                .collect()
                        });
                        let required_properties: Vec<bool> = property_locations
                            .iter()
                            .map(|key| {
                                required_keys.as_ref().map_or_else(
                                    || {
                                        required_strings.iter().any(
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
                            .filter(|key| {
                                if !key.ordinary_string {
                                    return true;
                                }
                                let name = key.name;
                                if indexed_required {
                                    !property_targets
                                        .contains_key(&tracking::JsonKey::new(vm, name))
                                } else {
                                    !properties
                                        .iter()
                                        .any(|&(key, _)| unsafe { sn_string_equal(key, name) } != 0)
                                }
                            })
                            .collect();
                        let dependent = self.field(vm, operand, FIELD_DEPENDENT_REQUIRED)?;
                        let mut dependent_required = vec![];
                        let mut dependent_schemas = vec![];
                        let mut diagnostic_dependencies = vec![];
                        for pair in self.values(dependencies) {
                            let name = self.retain(unsafe { sn_entry(pair, 0) });
                            let dependency = self.retain(unsafe { sn_entry(pair, 1) });
                            if unsafe { sn_kind(dependency) } == TYPE_ARRAY {
                                let names = self.required_keys(dependency);
                                diagnostic_dependencies.push(DiagnosticDependency::Required(
                                    name,
                                    names.clone(),
                                    "dependencies",
                                ));
                                dependent_required.push((name, names));
                            } else {
                                let child = self.compile(vm, dependency)?;
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
                            let names = self.required_keys(unsafe { sn_entry(pair, 1) });
                            diagnostic_dependencies.push(DiagnosticDependency::Required(
                                name,
                                names.clone(),
                                "dependentRequired",
                            ));
                            dependent_required.push((name, names));
                        }
                        let dependent = self.field(vm, operand, FIELD_DEPENDENT_SCHEMAS)?;
                        let schemas = self.compile_map(vm, dependent)?;
                        diagnostic_dependencies.extend(schemas.iter().map(|&(name, child)| {
                            DiagnosticDependency::Schema(name, child, "dependentSchemas")
                        }));
                        dependent_schemas.extend(schemas);
                        if dependent_required
                            .iter()
                            .any(|(name, _)| unsafe { sn_kind(*name) } != TYPE_STRING)
                            || dependent_schemas
                                .iter()
                                .any(|&(key, _)| unsafe { sn_kind(key) } != TYPE_STRING)
                        {
                            ops.push(Op::Unsupported);
                            continue;
                        }
                        let mut object = Object {
                            header: self.container_header(
                                vm,
                                operand,
                                FIELD_MAX_PROPERTIES,
                                FIELD_MIN_PROPERTIES,
                                true,
                                0,
                            )?,
                            inspect_required,
                            record: None,
                            min: self.size_field(vm, operand, FIELD_MIN_PROPERTIES)?,
                            max: self.size_field(vm, operand, FIELD_MAX_PROPERTIES)?,
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
                            additional: self.child(vm, operand, FIELD_ADDITIONAL)?,
                            names: self.child(vm, operand, FIELD_PROPERTY_NAMES)?,
                            dependent_required,
                            dependent_schemas,
                            diagnostic_dependencies,
                            unevaluated: self.child(vm, operand, FIELD_UNEVALUATED)?,
                        }
                        .with_record(vm);
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
                                let mut key = Value::default();
                                if unsafe { vm.sn_key_copy(field.name, &mut key) } != 0 {
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
                    let reference = self.field(vm, operand, FIELD_VALUE)?;
                    let mut target = Value::default();
                    if unsafe { vm.sn_resolve(self.compiler, program, reference, &mut target) } != 0
                    {
                        // Classification and message access can run Ruby. Root
                        // the exception explicitly instead of relying on Rust
                        // stack scanning. It is not an instruction operand.
                        let temporary_root = unsafe { &*self.roots }.values.len();
                        self.retain(target);
                        let mut classified = Value::default();
                        if unsafe { vm.sn_resolution_error(target, &mut classified) } != 0 {
                            return Err(classified);
                        }
                        if unsafe { sn_true(classified) } != 0 {
                            let message = self.field(vm, target, FIELD_MESSAGE)?;
                            // Only the retained message survives compilation;
                            // do not publish/freeze the exception's backtrace.
                            unsafe { &mut *self.roots }
                                .values
                                .swap_remove(temporary_root);
                            Op::UnresolvedRef(message)
                        } else {
                            return Err(target);
                        }
                    } else {
                        self.retain(target);
                        let target = self.compile(vm, target)?;
                        self.compile_reference(vm, operand, opcode, target)?
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
    fn compile_kind_demands(&mut self) {
        self.kind_demand = self
            .nodes
            .iter()
            .map(|ops| self.kind_demand_for(ops))
            .collect();
    }
    fn kind_demand_for(&self, ops: &[Op]) -> KindDemand {
        ops.iter()
            .map(|op| match op {
                Op::Type(..) | Op::Number(..) | Op::String(..) | Op::Const(_) | Op::Enum(_) => {
                    KindDemand::Predicate
                }
                Op::Array(_, rules)
                    if rules.header_only()
                        || self.array_callbacks(rules)
                        || self.array_report_callbacks(rules) =>
                {
                    KindDemand::Predicate
                }
                Op::Object(_, rules)
                    if rules.header_only()
                        || self.object_callbacks(rules)
                        || self.object_report_callbacks(rules) =>
                {
                    KindDemand::Predicate
                }
                Op::Array(..) | Op::Object(..) => KindDemand::Data,
                Op::Unsupported
                | Op::Boolean(_)
                | Op::UnresolvedRef(_)
                | Op::Ref(_)
                | Op::All(_)
                | Op::Any(_)
                | Op::One(_)
                | Op::Not(_)
                | Op::Conditional(..) => KindDemand::None,
            })
            .max()
            .unwrap_or(KindDemand::None)
    }
}

// A view of immutable compiled data and validator-owned runtime caches.
struct Execution<'a> {
    vm: &'a Ruby,
    engine: &'a Engine,
    caches: &'a runtime::Caches,
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
        known_kind: Option<&InstanceKind>,
    ) -> Verdict {
        // Suspend before entering the next node. C runs a fresh native stack
        // only after these frames and their borrowed views have unwound.
        if depth >= MAX_EVALUATION_DEPTH && self.caches.continuations_allowed() {
            return self.caches.native_child(node, value);
        }
        if self.caches.callback_checkpoint(value) != Valid || !self.budget.checkpoint() {
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
        known_kind: Option<&InstanceKind>,
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
        let _scope = self
            .caches
            .scope_guard(frame.resource, self.metadata[node].enters_scope);
        if self.tracks[node] {
            if let Some(result) = self.caches.callback_tracked(node, value) {
                return result;
            }
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
            && !self.caches.scalar_callback()
        {
            return rules.eval_guarded(self.vm, self.caches, *required, value);
        }
        let local_kind = InstanceKind::new(TYPE_UNCHECKED);
        let kind_state = known_kind.unwrap_or(&local_kind);
        let kind = if known_kind.is_some() {
            // A proof shared with sibling branches must guard every Hash key.
            self.diagnostic_kind(node, value, kind_state)
        } else {
            let kind = self.instance_kind(node, value);
            kind_state.set(kind);
            kind
        };
        if self.unsupported_kind(node, kind) {
            return Unsupported;
        }
        for op in &self.nodes[node] {
            // Runtime observations checkpoint each reached opcode once, after
            // earlier assertions and descendant calls have completed.
            if self.caches.callback_checkpoint(value) != Valid {
                return Unsupported;
            }
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let outcome = match op {
                Op::Ref(target) => {
                    let target = match self.resolve_reference(*target, value, active) {
                        Ok(target) => target,
                        Err(status) => return status,
                    };
                    let program = self.programs[node];
                    if RefFrame::contains(active.active, node, value)
                        || self.caches.reference_active(program, value)
                    {
                        Valid
                    } else {
                        let frame = RefFrame {
                            source: node,
                            value,
                            parent: active.active,
                        };
                        let reference = self.caches.reference_frame(program, value);
                        let _guard = self.caches.reference_guard(&reference);
                        self.eval_with_kind(
                            target,
                            value,
                            depth + 1,
                            scope::Context {
                                active: Some(&frame),
                                ..active
                            },
                            Some(kind_state),
                        )
                    }
                }
                Op::All(nodes) => {
                    let mut outcome = Valid;
                    for &n in nodes {
                        if !self.budget.checkpoint() {
                            return Unsupported;
                        }
                        outcome =
                            self.eval_with_kind(n, value, depth + 1, active, Some(kind_state));
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
                        self.caches.dynamic_calls(),
                        |child| {
                            if matches!(op, Op::One(_))
                                && self.caches.callback_checkpoint(value) != Valid
                            {
                                return Unsupported;
                            }
                            self.eval_with_kind(child, value, depth + 1, active, Some(kind_state))
                        },
                        |_, _| Ok(()),
                    ) {
                        Ok(result) => verdict(branch_kind.accepts(result.matches)),
                        Err(status) => status,
                    }
                }
                Op::Not(n) => {
                    match self.eval_with_kind(*n, value, depth + 1, active, Some(kind_state)) {
                        Valid => Invalid,
                        Invalid => Valid,
                        Unsupported => Unsupported,
                    }
                }
                Op::Conditional(c, yes, no) => {
                    match self.eval_with_kind(*c, value, depth + 1, active, Some(kind_state)) {
                        Unsupported => Unsupported,
                        result => match if result == Valid { yes } else { no } {
                            Some(n) => {
                                self.eval_with_kind(*n, value, depth + 1, active, Some(kind_state))
                            }
                            None => Valid,
                        },
                    }
                }
                Op::Array(required, rules) => {
                    if rules.header_only() && rules.header.runtime_required(self.caches, kind) {
                        rules.header.valid(self.caches, *required, value)
                    } else if self.caches.callbacks_allowed()
                        && rules.header.runtime_required(self.caches, kind)
                        && self.scalar_contains(rules)
                    {
                        rules.header.contains(
                            self.caches,
                            *required,
                            value,
                            rules.contains.expect("scalar contains child"),
                            self.scalar_callback_kind(
                                rules.contains.expect("scalar contains child"),
                            ),
                        )
                    } else if self.caches.callbacks_allowed()
                        && rules.header.runtime_required(self.caches, kind)
                        && self.array_callbacks(rules)
                    {
                        rules.header.children(self.caches, *required, value, node)
                    } else if *required != 0 && kind != TYPE_ARRAY {
                        Invalid
                    } else if kind != TYPE_ARRAY {
                        Valid
                    } else {
                        self.array(rules, value, depth + 1, active)
                    }
                }
                Op::Object(required, rules) => {
                    if rules.header_only() && rules.header.runtime_required(self.caches, kind) {
                        rules.header.valid(self.caches, *required, value)
                    } else if self.caches.callbacks_allowed()
                        && rules.header.runtime_required(self.caches, kind)
                        && self.object_callbacks(rules)
                    {
                        rules.header.children(self.caches, *required, value, node)
                    } else if *required != 0 && kind != TYPE_OBJECT {
                        Invalid
                    } else if kind != TYPE_OBJECT {
                        Valid
                    } else if rules.header_only() {
                        rules.valid_header(self.caches, value, self.undefined, &self.budget)
                    } else {
                        let result = self.object(rules, value, depth + 1, active);
                        if self.can_call_runtime(result)
                            && self.caches.callbacks_allowed()
                            && self.object_callbacks(rules)
                        {
                            rules.header.children(self.caches, *required, value, node)
                        } else {
                            result
                        }
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
            Op::UnresolvedRef(_) => Invalid,
            Op::Boolean(v) => verdict(*v),
            Op::Type(mask, union) => self.type_verdict(*mask, *union, kind, value),
            Op::Const(v) => {
                let result = if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                    Unsupported
                } else {
                    equal_budgeted(*v, value, depth, &self.budget)
                };
                if self.can_call_runtime(result) {
                    self.caches.equality(*v, value, RUNTIME_EQUAL)
                } else {
                    result
                }
            }
            Op::Enum(values) => {
                let result = if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                    Unsupported
                } else {
                    values.eval(self.vm, value, kind, depth, self.fixnum_flag, &self.budget)
                };
                if self.can_call_runtime(result) {
                    values.runtime(self.caches, value)
                } else {
                    result
                }
            }
            Op::Number(required, rules) => {
                if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                    return rules.runtime_valid(self.caches, *required, value);
                }
                if *required != 0 && kind & required == 0 {
                    Invalid
                } else if kind & TYPE_NUMBER == 0 {
                    Valid
                } else {
                    rules.eval(self.caches, value, &self.budget)
                }
            }
            Op::String(required, rules) => {
                if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                    return rules.runtime_valid(self.caches, *required, value);
                }
                if *required != 0 && kind != TYPE_STRING {
                    Invalid
                } else if kind != TYPE_STRING {
                    Valid
                } else {
                    rules.eval(self.vm, self.caches, value)
                }
            }
            _ => unreachable!("applicators must be evaluated with their context"),
        }
    }
    fn can_call_runtime(&self, result: Verdict) -> bool {
        result == Unsupported && self.budget.failure.get() == 0 && self.budget.hit.get().0 == 0
    }
    fn unique_values(&self, value: Value, depth: usize) -> Verdict {
        let result = if self.caches.dynamic_calls() {
            Unsupported
        } else {
            unique(self.vm, value, depth, self.fixnum_flag, &self.budget)
        };
        if self.can_call_runtime(result) {
            self.caches
                .equality(unsafe { sn_nil() }, value, RUNTIME_UNIQUE)
        } else {
            result
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
            let result = self.unique_values(value, depth);
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
                unsafe { self.vm.array(value) }
            };
            let primitive = match self.nodes[child].as_slice() {
                [Op::Type(mask, _)] if mask & TYPE_NUMBER != 0 || mask & TYPE_INTEGER != 0 => {
                    Some(&[][..])
                }
                [Op::Number(_, rules)] => rules.fast_limits.as_deref(),
                _ => None,
            };
            let primitive = primitive.filter(|_| !self.caches.dynamic_calls());
            let number = match self.nodes[child].as_slice() {
                [Op::Number(required, rules)]
                    if depth <= MAX_EVALUATION_DEPTH
                        && !self.tracks[child]
                        && !self.caches.dynamic_calls() =>
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
            let _scope = self.caches.scope_guard(
                frame.resource,
                object.is_some() && self.metadata[child].enters_scope,
            );
            let pattern = string.and_then(|(required, rules)| {
                rules
                    .pattern_only()
                    .map(|pattern| (required, pattern))
                    .filter(|_| !self.budget.timed() && !self.caches.dynamic_calls())
            });
            let format = string.and_then(|(required, rules)| {
                rules
                    .format_only()
                    .map(|format| (required, format))
                    .filter(|_| !self.budget.timed() && !self.caches.dynamic_calls())
            });
            let content = string.and_then(|(required, rules)| {
                rules
                    .content_only()
                    .map(|content| (required, content))
                    .filter(|_| !self.budget.timed() && !self.caches.dynamic_calls())
            });
            if let Some((required, pattern)) = pattern {
                let result = pattern.visit_invalid_items(
                    self.vm,
                    self.caches,
                    required,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                    |_, item| self.eval(child, item, depth, active),
                );
                if result != Valid {
                    return result;
                }
            } else if let Some((required, format)) = format {
                let result = format.visit_invalid_items(
                    self.vm,
                    required,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                    |_, item| self.eval(child, item, depth, active),
                );
                if result != Valid {
                    return result;
                }
            } else if let Some((required, content)) = content {
                let result = content.visit_invalid_items(
                    self.vm,
                    self.caches,
                    required,
                    values.get(r.prefix.len()..).unwrap_or(&[]),
                    |_, item| self.eval(child, item, depth, active),
                );
                if result != Valid {
                    return result;
                }
            } else if let Some((required, rules)) = object {
                let result = self.record_items(
                    child,
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
                        let status = rules.eval_guarded(self.caches, required, item, &self.budget);
                        if status == Unsupported {
                            self.eval(child, item, depth, active)
                        } else {
                            status
                        }
                    } else if let Some((required, rules)) = string {
                        if rules.pattern.is_some() {
                            rules.eval_guarded(self.vm, self.caches, required, item)
                        } else if rules.length_only() {
                            rules.eval_length_guarded(self.caches, required, item)
                        } else {
                            let kind = unsafe { sn_kind(item) };
                            if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                                rules.runtime_valid(self.caches, required, item)
                            } else if kind != TYPE_STRING {
                                verdict(required == 0)
                            } else {
                                rules.eval(self.vm, self.caches, item)
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
            if r.count_contains
                && let Some(status) = self.fixnum_contains(r, child, value, len, depth)
            {
                return status;
            }
            let matches = match evaluation::scan_contains(
                len,
                if r.count_contains {
                    evaluation::ContainsPolicy::AllMatches
                } else {
                    evaluation::ContainsPolicy::FirstMatch
                },
                |index| self.eval(child, unsafe { sn_entry(value, index) }, depth, active),
                |_| {},
            ) {
                Ok(matches) => matches,
                Err(status) => return status,
            };
            let (min, max) = if r.count_contains {
                (r.min_contains, r.max_contains)
            } else {
                (1, None)
            };
            if bounds(matches, Some(min), max) == Invalid {
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
            Op::Type(..) | Op::Boolean(_) => true,
            Op::Const(expected) => expected.has_fixnum_tag(self.fixnum_flag),
            Op::Number(_, rules) => rules.fast_limits.is_some(),
            _ => false,
        };
        if !total {
            return None;
        }
        let values = if len == 0 {
            &[]
        } else {
            unsafe { self.vm.array(value) }
        };
        // Preserve later Unsupported/fallback results: no predicate work may
        // be skipped until all values are proven to be supported Fixnums.
        // This guard stays linear, but is far cheaper than full node evaluation.
        if !values
            .iter()
            .all(|&item| item.has_fixnum_tag(self.fixnum_flag))
        {
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
                if depth <= MAX_EVALUATION_DEPTH
                    && !self.tracks[child]
                    && !self.caches.dynamic_calls() =>
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
            let result = if value.has_fixnum_tag(self.fixnum_flag) {
                let n = immediate_integer(value);
                verdict(n >= min && n <= max)
            } else if let Some((required, rules)) = number {
                let status = rules.eval_guarded(self.caches, required, value, &self.budget);
                if status == Unsupported {
                    self.eval(child, value, depth, active)
                } else {
                    status
                }
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
        node: usize,
        rules: &Object,
        required: i32,
        values: &[Value],
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        let header_only = rules.header_only();
        for &value in values {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let kind = if value.has_fixnum_tag(self.fixnum_flag) {
                TYPE_INTEGRAL_NUMBER
            } else {
                unsafe { sn_shallow_kind(value) }
            };
            let runtime = header_only && rules.header.runtime_required(self.caches, kind);
            let result = if runtime {
                rules.header.valid(self.caches, required, value)
            } else if kind == TYPE_UNSUPPORTED {
                Unsupported
            } else if kind != TYPE_OBJECT {
                verdict(required == 0)
            } else {
                self.object(rules, value, depth, active)
            };
            let result = if self.can_call_runtime(result)
                && self.caches.callbacks_allowed()
                && self.object_callbacks(rules)
            {
                rules.header.children(self.caches, required, value, node)
            } else if header_only && !runtime && self.can_call_runtime(result) {
                // A declined record guard has not invoked instance methods.
                // Preserve the fast record walk while handing special values
                // to the same runtime frame as general header evaluation.
                rules.header.valid(self.caches, required, value)
            } else {
                result
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
        if !self.caches.runtime_order()
            && let Some(record) = &r.record
        {
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
            let entries = unsafe { ruby::initialized_values(&buffer, 2 * len as usize) };
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
        let status = r.check_required(self.caches, value, self.undefined, &self.budget);
        if status != Valid {
            return status;
        }
        let ordered = self.caches.runtime_order();
        let found = if ordered {
            0
        } else {
            match r.visit_properties(
                self.vm,
                value,
                len,
                self.undefined,
                &self.budget,
                |_, child, item| self.eval(child, item, depth, active),
            ) {
                Ok(found) => found,
                Err(status) => return status,
            }
        };
        if ordered
            || r.names.is_some()
            || !r.patterns.is_empty()
            || (r.additional.is_some() && found < len)
        {
            let mut context = ObjectContext {
                engine: self,
                rules: r,
                depth,
                active,
                names_only: false,
            };
            let result =
                unsafe { sn_object_each(value, (&mut context as *mut ObjectContext).cast()) };
            if result != VERDICT_VALID {
                return if result == 0 { Invalid } else { Unsupported };
            }
        }
        if ordered && r.names.is_some() {
            let status = self.object_names(r, value, depth, active);
            if status != Valid {
                return status;
            }
        }
        let status = r.check_dependent_required(self.caches, value, self.undefined, &self.budget);
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
    fn object_names(
        &self,
        rules: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        let mut context = ObjectContext {
            engine: self,
            rules,
            depth,
            active,
            names_only: true,
        };
        decode(unsafe { sn_object_each(value, (&mut context as *mut ObjectContext).cast()) })
    }
    fn unsupported_kind(&self, node: usize, kind: i32) -> bool {
        kind == TYPE_UNSUPPORTED
            && (self.kind_demand[node] == KindDemand::Data
                || (!self.caches.callbacks_allowed()
                    && !self.caches.report_continuations_allowed()
                    && self.callback_container_node(node)))
    }
    fn type_verdict(&self, mask: i32, union: bool, kind: i32, value: Value) -> Verdict {
        if kind == TYPE_UNSUPPORTED
            || self.caches.scalar_callback()
            || (self.caches.callbacks_allowed() && self.caches.dynamic_calls())
        {
            self.caches.type_predicate(value, mask, union)
        } else {
            verdict(kind & mask != 0)
        }
    }
    fn instance_kind(&self, node: usize, value: Value) -> i32 {
        if self.caches.scalar_callback() && self.kind_demand[node] == KindDemand::Predicate {
            return TYPE_UNSUPPORTED;
        }
        if value.has_fixnum_tag(self.fixnum_flag) {
            return TYPE_INTEGRAL_NUMBER;
        }
        if self.kind_demand[node] == KindDemand::None {
            return TYPE_UNCHECKED;
        }
        if matches!(self.nodes[node].as_slice(), [Op::Object(_, rules)]
            if rules.record.is_some() && (!rules.header_only() || (!rules.inspect_required && rules.dependent_required.is_empty())))
        {
            unsafe { sn_shallow_kind(value) }
        } else {
            unsafe { sn_kind(value) }
        }
    }
    // Diagnostic/trial paths require a full Hash-key guard. A known parent kind
    // remains reusable, while control-flow-only children need no classification.
    fn diagnostic_kind(&self, node: usize, value: Value, known: &InstanceKind) -> i32 {
        if self.caches.scalar_callback() && self.kind_demand[node] == KindDemand::Predicate {
            return TYPE_UNSUPPORTED;
        }
        if known.get() != TYPE_UNCHECKED {
            return known.get();
        }
        let kind = if value.has_fixnum_tag(self.fixnum_flag) {
            TYPE_INTEGRAL_NUMBER
        } else if self.kind_demand[node] == KindDemand::None {
            TYPE_UNCHECKED
        } else {
            unsafe { sn_kind(value) }
        };
        known.set(kind);
        kind
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
                rules.eval_length_guarded(self.caches, *required, value)
            }
            [Op::String(required, rules)]
                if depth <= MAX_EVALUATION_DEPTH && rules.pattern.is_some() =>
            {
                rules.eval_guarded(self.vm, self.caches, *required, value)
            }
            [
                op @ (Op::Type(..)
                | Op::Boolean(_)
                | Op::Number(..)
                | Op::String(..)
                | Op::Const(_)
                | Op::Enum(_)),
            ] if depth <= MAX_EVALUATION_DEPTH => {
                let kind = self.diagnostic_kind(node, value, &InstanceKind::new(TYPE_UNCHECKED));
                if self.unsupported_kind(node, kind) {
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
fn indexed_record_field<'a>(
    vm: &Ruby,
    record: &'a RecordObject,
    key: Value,
) -> Option<&'a RecordField> {
    let index = record.short_index.as_ref()?;
    let short = short_record_key(vm, key);
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
        indexed_record_field(c.engine.vm, c.record, key)
    } else {
        c.record
            .fields
            .iter()
            .find(|field| field.key == key)
            .or_else(|| {
                if c.record.short_index.is_some() {
                    return indexed_record_field(c.engine.vm, c.record, key);
                }
                let short =
                    (c.record.fields.len() >= 4).then(|| short_record_key(c.engine.vm, key));
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
                Some(RecordCheck::IntegerBounds(min, max))
                    if value.has_fixnum_tag(c.engine.fixnum_flag)
                        && !c.engine.caches.dynamic_calls() =>
                {
                    let n = immediate_integer(value);
                    verdict(n >= min && n <= max)
                }
                Some(RecordCheck::StringLength(required, min, max))
                    if !c.engine.caches.dynamic_calls() =>
                {
                    let status = length_guarded(value, required, min, max);
                    if status == Unsupported {
                        c.engine.record_value(child, value, c.depth, c.active)
                    } else {
                        status
                    }
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
    (value.bits() as isize >> 1) as i64
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
        return equal_iterative(a, b, depth, memo, budget);
    }
    let ka = match equality_kind(a, b) {
        Ok(kind) => kind,
        Err(result) => return result,
    };
    let key = (a, b, depth);
    if memo.eligible(depth)
        && let Some(result) = memo.get(key)
    {
        return result;
    }
    let result = match ka {
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
        _ => unreachable!("equality_kind returns only container kinds"),
    };
    if memo.eligible(depth) {
        memo.record(key, result);
    }
    result
}

// Resolve scalar equality once for both recursive and explicit-stack traversal.
// Only ordinary equal-class containers require child traversal.
fn equality_kind(a: Value, b: Value) -> Result<i32, Verdict> {
    let (ka, kb) = unsafe { (sn_kind(a), sn_kind(b)) };
    if ka == TYPE_UNSUPPORTED || kb == TYPE_UNSUPPORTED {
        return Err(Unsupported);
    }
    if ka & TYPE_NUMBER != 0 && kb & TYPE_NUMBER != 0 {
        let (ia, ib) = unsafe { (sn_fixnum(a) != 0, sn_fixnum(b) != 0) };
        let (fa, fb) = unsafe { (sn_is_float(a) != 0, sn_is_float(b) != 0) };
        if ia && ib {
            return Err(verdict(unsafe { sn_integer(a) == sn_integer(b) }));
        }
        if fa && fb {
            return Err(verdict(unsafe { sn_float(a) == sn_float(b) }));
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
            return Err(verdict(
                f.is_finite()
                    && f.trunc() == f
                    && f >= i64::MIN as f64
                    && f < i64::MAX as f64
                    && f as i64 == n,
            ));
        }
        if !fa && !fb {
            return Err(verdict(
                unsafe {
                    if ia {
                        sn_big_equal(b, a)
                    } else {
                        sn_big_equal(a, b)
                    }
                } != 0,
            ));
        }
        return Err(if fa {
            number::integer_float_equal(b, unsafe { sn_float(a) })
        } else {
            number::integer_float_equal(a, unsafe { sn_float(b) })
        });
    }
    // JSON container equality visits every value, even for the same object:
    // nested NaN values are unequal and unsupported values need VM evaluation.
    if ka != TYPE_ARRAY && ka != TYPE_OBJECT && unsafe { sn_same(a, b) } != 0 {
        return Err(Valid);
    }
    if ka != kb {
        return Err(Invalid);
    }
    if unsafe { sn_same_class(a, b) } == 0 {
        return Err(Invalid);
    }
    match ka {
        TYPE_ARRAY | TYPE_OBJECT => Ok(ka),
        TYPE_STRING => Err(verdict(unsafe { sn_string_equal(a, b) } != 0)),
        _ => Err(Invalid),
    }
}

enum EqualityWork {
    Compare(Value, Value, usize),
    Array(Value, Value, usize, usize, usize),
    Object(Value, Vec<(Value, Value)>, usize, usize),
    Finish(Value, Value, usize),
}

// Keep shallow comparisons on their allocation-free recursive path. Beyond
// that bounded prefix, explicit continuations preserve depth-first order
// without growing the native call stack. Scalar rules remain shared above.
fn equal_iterative(
    a: Value,
    b: Value,
    depth: usize,
    memo: &mut structural::Cache<(Value, Value, usize), Verdict>,
    budget: &budget::Budget,
) -> Verdict {
    let mut work = vec![EqualityWork::Compare(a, b, depth)];
    let mut active = std::collections::HashSet::new();
    while let Some(task) = work.pop() {
        if !budget.checkpoint() {
            return Unsupported;
        }
        match task {
            EqualityWork::Compare(a, b, depth) => {
                let kind = match equality_kind(a, b) {
                    Ok(kind) => kind,
                    Err(Valid) => continue,
                    Err(result) => return result,
                };
                let key = (a, b, depth);
                if memo.eligible(depth)
                    && let Some(result) = memo.get(key)
                {
                    if result != Valid {
                        return result;
                    }
                    continue;
                }
                let len = unsafe { sn_len(a) };
                if len != unsafe { sn_len(b) } {
                    return Invalid;
                }
                // Report Ruby's recursive-comparison error after unwinding;
                // an active pair is not proof of JSON equality.
                if !active.insert((a, b)) {
                    budget.failure.set(STATUS_STACK_ERROR);
                    return Unsupported;
                }
                work.push(EqualityWork::Finish(a, b, depth));
                if len == 0 {
                    continue;
                }
                if kind == TYPE_ARRAY {
                    work.push(EqualityWork::Array(a, b, 0, len, depth + 1));
                } else {
                    let mut entries = EqualityEntries {
                        values: Vec::with_capacity(len),
                        budget,
                    };
                    let status = decode(unsafe {
                        sn_hash_each(
                            a,
                            (&mut entries as *mut EqualityEntries<'_>).cast(),
                            equality_entry,
                        )
                    });
                    if status != Valid {
                        return status;
                    }
                    work.push(EqualityWork::Object(b, entries.values, 0, depth + 1));
                }
            }
            EqualityWork::Array(a, b, index, len, depth) => {
                let pair = unsafe { (sn_entry(a, index), sn_entry(b, index)) };
                if index + 1 < len {
                    work.push(EqualityWork::Array(a, b, index + 1, len, depth));
                }
                work.push(EqualityWork::Compare(pair.0, pair.1, depth));
            }
            EqualityWork::Object(b, entries, index, depth) => {
                let (key, value) = entries[index];
                let other = unsafe { sn_lookup(b, key) };
                if unsafe { sn_missing(other) } != 0 {
                    return Invalid;
                }
                if index + 1 < entries.len() {
                    work.push(EqualityWork::Object(b, entries, index + 1, depth));
                }
                work.push(EqualityWork::Compare(value, other, depth));
            }
            EqualityWork::Finish(a, b, depth) => {
                active.remove(&(a, b));
                if memo.eligible(depth) {
                    memo.record((a, b, depth), Valid);
                }
            }
        }
    }
    Valid
}

struct EqualityEntries<'a> {
    values: Vec<(Value, Value)>,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn equality_entry(context: *mut c_void, key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let entries = unsafe { &mut *context.cast::<EqualityEntries<'_>>() };
        if !entries.budget.checkpoint() {
            return Unsupported as i32;
        }
        entries.values.push((key, value));
        Valid as i32
    }))
    .unwrap_or(Unsupported as i32)
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
fn string_fingerprint(vm: &Ruby, value: Value) -> u64 {
    bytes_fingerprint(unsafe { vm.string(value) })
}
#[derive(Clone, Copy, Debug)]
struct ShortRecordKey {
    word: u64,
    // Low four bits encode length + 1; zero means a longer key. The remaining
    // bits hold the public CRuby encoding index, not a borrowed pointer.
    tag: u64,
}
fn short_record_key(vm: &Ruby, value: Value) -> ShortRecordKey {
    let mut data = std::ptr::null();
    let mut len = 0;
    let encoding = unsafe { sn_record_key_view(value, &mut data, &mut len) };
    if len > 8 {
        return ShortRecordKey { word: 0, tag: 0 };
    }
    let bytes = unsafe { vm.bytes(data, len) };
    ShortRecordKey {
        word: short_word(bytes),
        tag: ((encoding as u64) << 4) | (len as u64 + 1),
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
    vm: &Ruby,
    value: Value,
    depth: usize,
    fixnum_flag: usize,
    big_hint: bool,
    budget: &budget::Budget,
) -> Option<u64> {
    fingerprint_cached(
        vm,
        value,
        fixnum_flag,
        depth,
        big_hint,
        &mut structural::Cache::new(depth),
        budget,
    )
}
fn fingerprint_cached(
    vm: &Ruby,
    value: Value,
    depth: usize,
    fixnum_flag: usize,
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
    if value.has_fixnum_tag(fixnum_flag) {
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
        TYPE_IDENTITY_SCALAR => Some(mix(value.bits() as u64 ^ TYPE_IDENTITY_SCALAR as u64)),
        TYPE_NULL => Some(mix(TYPE_NULL as u64)),
        TYPE_BOOLEAN => Some(mix(if unsafe { len.assume_init() } != 0 {
            2
        } else {
            3
        })),
        TYPE_STRING => Some(bytes_fingerprint(unsafe {
            vm.bytes(data.assume_init().cast(), len.assume_init())
        })),
        TYPE_ARRAY => {
            let mut hash = mix(TYPE_ARRAY as u64);
            let len = unsafe { len.assume_init() };
            let values = if len == 0 {
                &[]
            } else {
                unsafe { vm.values(data.assume_init().cast::<Value>(), len) }
            };
            // All descendants are read under the GVL without allocating Ruby
            // objects or invoking Ruby callbacks, so the borrowed view is stable.
            for &item in values {
                hash = mix(hash
                    ^ fingerprint_cached(vm, item, depth + 1, fixnum_flag, false, memo, budget)?);
            }
            Some(hash)
        }
        TYPE_OBJECT => {
            let len = unsafe { len.assume_init() };
            let mut c = FingerprintContext {
                vm,
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
    vm: &'a Ruby,
    hash: u64,
    depth: usize,
    fixnum_flag: usize,
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
        let Some(hash) =
            fingerprint_cached(c.vm, value, c.depth, c.fixnum_flag, false, c.memo, c.budget)
        else {
            return Unsupported as i32;
        };
        c.hash ^= mix(bytes_fingerprint(unsafe { c.vm.bytes(data, len) }) ^ hash.rotate_left(17));
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
fn unique(
    vm: &Ruby,
    value: Value,
    depth: usize,
    fixnum_flag: usize,
    budget: &budget::Budget,
) -> Verdict {
    let len = unsafe { sn_len(value) };
    if !budget.checkpoint() {
        return Unsupported;
    }
    if len <= 16 {
        return unique_linear(value, depth, budget, false);
    }
    let values = unsafe { vm.array(value) };
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
    let result = indexed_unique(
        values,
        |item| {
            fingerprint_cached(
                vm,
                item,
                fixnum_flag,
                depth,
                big_hint,
                &mut fingerprints,
                budget,
            )
        },
        |a, b| equal_budgeted(a, b, depth, budget),
    );
    if result == Unsupported && budget.failure.get() == 0 && budget.checkpoint() {
        unique_linear(value, depth, budget, true)
    } else {
        result
    }
}
// Index availability is an optimization decision. Exact ordered comparisons
// can still decide uniqueness when a depth or memory bound declines hashing.
fn unique_linear(value: Value, depth: usize, budget: &budget::Budget, check_hash: bool) -> Verdict {
    for i in 0..unsafe { sn_len(value) } {
        if check_hash {
            match instance_graph::ordinary_graph(unsafe { sn_entry(value, i) }, budget) {
                instance_graph::Safety::Ordinary => {}
                instance_graph::Safety::Cyclic => {
                    budget.failure.set(STATUS_STACK_ERROR);
                    return Unsupported;
                }
                instance_graph::Safety::Unsupported => return Unsupported,
            }
        }
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
    Valid
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
    vm: &'a Ruby,
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
        if let Some(target) = c
            .rules
            .property_targets
            .get(&tracking::JsonKey::new(c.vm, key))
        {
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
    names_only: bool,
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
        if (c.names_only || !c.engine.caches.runtime_order())
            && let Some(child) = c.rules.names
        {
            let result = c.engine.eval(child, key, c.depth, c.active);
            if result != Valid {
                return result as i32;
            }
        }
        if c.names_only {
            return Valid as i32;
        }
        match c.rules.visit_value_rules(
            c.engine.vm,
            c.engine.caches,
            &c.engine.budget,
            c.engine.caches.runtime_order(),
            (key, None),
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
    let mut vm = unsafe { Ruby::enter() };
    match catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &mut *engine };
        e.validate_format = format != 0;
        e.validate_content = content != 0;
        e.compiler = e.retain(compiler);
        if multiple != 0 {
            for program in e.values(program) {
                e.compile(&mut vm, program)?;
            }
        } else {
            e.root = e.compile(&mut vm, program)?;
        }
        e.bind_dynamic_anchors(&mut vm)?;
        e.simplify_dynamic_references();
        e.compile_memoization();
        e.compile_native_validity_support();
        e.compile_kind_demands();
        Ok::<_, Value>(
            !e.nodes
                .iter()
                .flatten()
                .any(|op| matches!(op, Op::Unsupported)),
        )
    })) {
        Ok(Ok(true)) => VERDICT_VALID,
        Ok(Ok(false)) => VERDICT_UNSUPPORTED,
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
/// Engine must be initialized, node compiled, and flags writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_callback_kind(
    engine: *const Engine,
    node: usize,
    flags: *mut i32,
) -> i32 {
    let (kind, value) = unsafe { &*engine }.scalar_callback_kind(node);
    unsafe { *flags = value };
    kind
}
/// # Safety
/// Engine must be initialized and root compiled.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_reference_context(engine: *const Engine) -> i32 {
    // Any scalar Ruby primitive can reenter a schema block, including from
    // tracked/diagnostic traversals that cannot admit container callbacks.
    i32::from(unsafe { &*engine }.has_references)
}
/// # Safety
/// Engine must be initialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_root_index(engine: *const Engine) -> usize {
    unsafe { &*engine }.root
}
/// # Safety
/// Engine must be live and compilation must have finished.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_has_unresolved_references(engine: *const Engine) -> i32 {
    i32::from(
        unsafe { &*engine }
            .nodes
            .iter()
            .flatten()
            .any(|op| matches!(op, Op::UnresolvedRef(_))),
    )
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
    caches: *const runtime::Caches,
    root: usize,
    value: Value,
    depth: usize,
) -> i32 {
    let vm = unsafe { Ruby::enter() };
    catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &*engine };
        let mut local = None;
        let caches = runtime::Caches::supplied_or_default(unsafe { caches.as_ref() }, &mut local);
        caches.admit(e, root);
        let execution = Execution {
            vm: &vm,
            engine: e,
            caches,
            memo: memo::Memo::default(),
            budget: budget::Budget::default(),
        };
        let result = execution.eval(root, value, depth, scope::Context::default());
        caches.finish_callback_report(result);
        execution.budget.status(result)
    }))
    .unwrap_or(STATUS_PANIC)
}
/// # Safety
/// Same requirements as sn_valid; all limit/output pointers must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_valid_with_limits(
    engine: *const Engine,
    caches: *const runtime::Caches,
    root: usize,
    value: Value,
    depth: usize,
    limits: *const budget::Limits,
    outcome: *mut budget::Outcome,
) -> i32 {
    let vm = unsafe { Ruby::enter() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let mut local = None;
        let caches = runtime::Caches::supplied_or_default(unsafe { caches.as_ref() }, &mut local);
        let e = unsafe { &*engine };
        caches.admit(e, root);
        let execution = Execution {
            vm: &vm,
            engine: unsafe { &*engine },
            caches,
            memo: memo::Memo::default(),
            budget: caches.budget(unsafe { *limits }),
        };
        let result = if execution.budget.check_deadline() {
            execution.eval(root, value, depth, scope::Context::default())
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
        caches.finish_callback_report(result);
        execution.budget.status(result)
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
    unsafe { (&*roots).mark() };
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
    let programs = unsafe { &*std::ptr::addr_of!((*engine).programs) };
    let contextual = unsafe { &*std::ptr::addr_of!((*engine).memo_contextual) };
    let kinds = unsafe { &*std::ptr::addr_of!((*engine).kind_demand) };
    let callback_roots = unsafe { &*std::ptr::addr_of!((*engine).callback_roots) };
    let validity_supported = unsafe { &*std::ptr::addr_of!((*engine).validity_supported) };
    let report_supported = unsafe { &*std::ptr::addr_of!((*engine).report_supported) };
    let guarded = unsafe { &*std::ptr::addr_of!((*engine).memo_guarded) };
    let sources = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_sources) };
    let same = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_same_sources) };
    let scalar = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_scalar_sources) };
    let amplification = unsafe { &*std::ptr::addr_of!((*engine).memo_guard_scalar_amplification) };
    let projection = unsafe { &*std::ptr::addr_of!((*engine).memo_scope_projection) };
    std::mem::size_of::<Engine>()
        + projection.memory_usage()
        + kinds.capacity() * std::mem::size_of::<KindDemand>()
        + (callback_roots.capacity() + validity_supported.capacity() + report_supported.capacity())
            * std::mem::size_of::<bool>()
        + (contextual.capacity()
            + guarded.capacity()
            + sources.capacity()
            + same.capacity()
            + scalar.capacity()
            + amplification.capacity())
            * std::mem::size_of::<bool>()
        + programs.capacity() * std::mem::size_of::<Value>()
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
                Op::Number(_, rules) => rules.memory_usage(),
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

impl ruby_trace::NativeOnly for Verdict {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ruby::test_value as v;

    #[test]
    fn falls_back_for_clustered_slots_without_comparing_distinct_fingerprints() {
        let values: Vec<_> = (1..=4096).map(v).collect();
        let mut hashes = 0;
        assert_eq!(
            indexed_unique(
                &values,
                |value| {
                    hashes += 1;
                    Some((value.bits() as u64) << 32)
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
        let hash = |value: Value| (value != v(99)).then_some(value.bits() as u64 % 2);
        let equal = |a, b| verdict(a == b);
        assert_eq!(
            sorted_unique(&[v(0), v(2), v(4), v(1), v(3), v(5)], hash, equal),
            Valid
        );
        assert_eq!(
            sorted_unique(&[v(0), v(2), v(0), v(99)], hash, equal),
            Invalid
        );
        assert_eq!(
            sorted_unique(&[v(0), v(2), v(99), v(0)], hash, equal),
            Unsupported
        );
        assert_eq!(
            sorted_unique(&[v(0), v(1), v(1), v(2)], hash, |a, b| {
                if (a, b) == (v(0), v(2)) {
                    Unsupported
                } else {
                    equal(a, b)
                }
            }),
            Invalid
        );
        assert_eq!(
            sorted_unique(&[v(0), v(2), v(1), v(1)], hash, |a, b| {
                if (a, b) == (v(0), v(2)) {
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
