//! Evaluated locations stay in native buffers, scoped to one instance location.
//! Keys remain borrowed VALUEs; no Ruby objects or instance trees are allocated.
use super::*;
use std::collections::HashSet;
use std::hash::Hash;

#[derive(Clone, Copy, Debug)]
pub(super) struct JsonKey(pub Value, u64);
impl JsonKey {
    pub(super) fn new(value: Value) -> Self {
        Self(value, string_fingerprint(value))
    }
}
impl PartialEq for JsonKey {
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0 || unsafe { sn_string_equal(self.0, other.0) != 0 }
    }
}
impl Eq for JsonKey {}
impl Hash for JsonKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        state.write_u64(self.1);
    }
}
pub(super) type KeySet = HashSet<JsonKey, BuildHasherDefault<BucketHasher>>;

pub(super) struct Tracked {
    pub status: Verdict,
    properties: KeySet,
    known_properties: Vec<u64>,
    items: Vec<u64>,
}
impl Tracked {
    pub(super) fn new(status: Verdict) -> Self {
        Self {
            status,
            properties: KeySet::default(),
            known_properties: vec![],
            items: vec![],
        }
    }
    pub(super) fn item(&mut self, index: usize) {
        let word = index / 64;
        if self.items.len() <= word {
            self.items.resize(word + 1, 0);
        }
        self.items[word] |= 1_u64 << (index % 64);
    }
    pub(super) fn contains_item(&self, index: usize) -> bool {
        self.items
            .get(index / 64)
            .is_some_and(|word| word & (1_u64 << (index % 64)) != 0)
    }
    fn known_property(&mut self, index: usize) {
        let word = index / 64;
        if self.known_properties.len() <= word {
            self.known_properties.resize(word + 1, 0);
        }
        self.known_properties[word] |= 1_u64 << (index % 64);
    }
    fn contains_known_property(&self, index: usize) -> bool {
        self.known_properties
            .get(index / 64)
            .is_some_and(|word| word & (1_u64 << (index % 64)) != 0)
    }
    pub(super) fn property_count(&self) -> usize {
        self.properties.len()
            + self
                .known_properties
                .iter()
                .map(|word| word.count_ones() as usize)
                .sum::<usize>()
    }
    pub(super) fn item_count(&self) -> usize {
        self.items
            .iter()
            .map(|word| word.count_ones() as usize)
            .sum()
    }
    pub(super) fn merge(&mut self, other: Self) -> Verdict {
        if other.status != Valid {
            return other.status;
        }
        if self.properties.is_empty() {
            self.properties = other.properties;
        } else {
            self.properties.extend(other.properties);
        }
        merge_bits(&mut self.known_properties, other.known_properties);
        merge_bits(&mut self.items, other.items);
        Valid
    }
    pub(super) fn merge_diagnostics(&mut self, other: Self) -> Result<(), Verdict> {
        if other.status == Unsupported {
            return Err(Unsupported);
        }
        if self.status != Valid || other.status != Valid {
            *self = Self::new(Invalid);
        } else {
            self.merge(other);
        }
        Ok(())
    }
    pub(super) fn property(&mut self, engine: &Engine, value: Value) {
        let key = JsonKey::new(value);
        if let Some(&index) = engine.property_ids.get(&key) {
            self.known_property(index);
        } else {
            self.properties.insert(key);
        }
    }
    pub(super) fn contains_property(&self, engine: &Engine, value: Value) -> bool {
        let key = JsonKey::new(value);
        engine
            .property_ids
            .get(&key)
            .is_some_and(|&index| self.contains_known_property(index))
            || self.properties.contains(&key)
    }
}
fn merge_bits(target: &mut Vec<u64>, source: Vec<u64>) {
    // Branch annotations own native buffers of location bits. Transfer an
    // existing buffer into an empty accumulator instead of allocating a copy.
    if target.is_empty() {
        *target = source;
    } else {
        if target.len() < source.len() {
            target.resize(source.len(), 0);
        }
        for (target, source) in target.iter_mut().zip(source) {
            *target |= source;
        }
    }
}
impl Execution<'_> {
    pub(super) fn eval_tracked(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Tracked {
        if depth > MAX_EVALUATION_DEPTH {
            return Tracked::new(Unsupported);
        }
        let kind = if value & self.fixnum_flag != 0 {
            TYPE_INTEGRAL_NUMBER
        } else {
            unsafe { sn_kind(value) }
        };
        self.eval_tracked_kind(node, value, depth, active, kind)
    }
    // Applicator branches evaluate the same borrowed instance under the GVL.
    // No Ruby callback can mutate it, so its guarded kind can be reused while
    // each branch still enters its own resource scope and checks depth.
    pub(super) fn eval_tracked_kind(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        kind: i32,
    ) -> Tracked {
        let frame = scope::ScopeFrame {
            resource: self.metadata[node].resource,
            parent: active.scope,
            primary_binding: active
                .scope
                .and_then(|frame| frame.primary_binding)
                .or(self.metadata[node].primary_binding),
        };
        let active = self.enter_scope(node, active, &frame);
        if depth > MAX_EVALUATION_DEPTH {
            return Tracked::new(Unsupported);
        }
        if kind == TYPE_UNSUPPORTED {
            return Tracked::new(Unsupported);
        }
        let mut evaluation = Tracked::new(Valid);
        for op in &self.nodes[node] {
            let result = match op {
                Op::Ref(target) => {
                    if RefFrame::contains(active.active, node, value) {
                        Valid
                    } else {
                        let frame = RefFrame {
                            source: node,
                            value,
                            parent: active.active,
                        };
                        evaluation.merge(self.eval_tracked_kind(
                            self.reference_target(*target, active),
                            value,
                            depth + 1,
                            scope::Context {
                                active: Some(&frame),
                                ..active
                            },
                            kind,
                        ))
                    }
                }
                Op::All(nodes) => {
                    let mut result = Valid;
                    for &child in nodes {
                        result = evaluation.merge(self.eval_tracked_kind(
                            child,
                            value,
                            depth + 1,
                            active,
                            kind,
                        ));
                        if result != Valid {
                            break;
                        }
                    }
                    result
                }
                Op::Any(nodes) | Op::One(nodes) => {
                    let branch_kind = if matches!(op, Op::Any(_)) {
                        evaluation::BranchKind::Any
                    } else {
                        evaluation::BranchKind::One
                    };
                    match evaluation::scan_branches(
                        nodes,
                        evaluation::BranchPolicy::Complete,
                        |child| self.eval_tracked_kind(child, value, depth + 1, active, kind),
                    ) {
                        Err(status) => status,
                        Ok(result) if !branch_kind.accepts(result.matches) => Invalid,
                        Ok(result) => evaluation.merge(result.coverage),
                    }
                }
                Op::Not(child) => match self.eval(*child, value, depth + 1, active) {
                    Valid => Invalid,
                    Invalid => Valid,
                    Unsupported => Unsupported,
                },
                Op::Conditional(condition, yes, no) => {
                    let condition =
                        self.eval_tracked_kind(*condition, value, depth + 1, active, kind);
                    let status = condition.status;
                    if status == Unsupported {
                        Unsupported
                    } else {
                        let branch = if status == Valid {
                            evaluation.merge(condition);
                            yes
                        } else {
                            no
                        };
                        if let Some(child) = branch {
                            evaluation.merge(self.eval_tracked_kind(
                                *child,
                                value,
                                depth + 1,
                                active,
                                kind,
                            ))
                        } else {
                            Valid
                        }
                    }
                }
                Op::Array(required, rules) => {
                    if *required != 0 && kind != TYPE_ARRAY {
                        Invalid
                    } else if kind != TYPE_ARRAY {
                        Valid
                    } else {
                        self.array_tracked(rules, value, depth + 1, active, &mut evaluation)
                    }
                }
                Op::Object(required, rules) => {
                    if *required != 0 && kind != TYPE_OBJECT {
                        Invalid
                    } else if kind != TYPE_OBJECT {
                        Valid
                    } else {
                        self.object_tracked(rules, value, depth + 1, active, &mut evaluation)
                    }
                }
                _ => self.leaf(op, kind, value, depth),
            };
            if result != Valid {
                return Tracked::new(result);
            }
        }
        evaluation
    }
    fn array_tracked(
        &self,
        r: &Array,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        evaluation: &mut Tracked,
    ) -> Verdict {
        let len = unsafe { sn_len(value) };
        if bounds(len, r.min, r.max) == Invalid {
            return Invalid;
        }
        if r.unique {
            let result = unique(value, depth, self.fixnum_flag);
            if result != Valid {
                return result;
            }
        }
        for (index, &child) in r.prefix.iter().take(len).enumerate() {
            let result = self.eval(child, unsafe { sn_entry(value, index) }, depth, active);
            if result != Valid {
                return result;
            }
            evaluation.item(index);
        }
        for index in 0..len {
            let child = if r.list {
                r.items.get(index).copied().or(r.additional)
            } else if index >= r.prefix.len() {
                r.items.first().copied()
            } else {
                None
            };
            if let Some(child) = child {
                let result = self.eval(child, unsafe { sn_entry(value, index) }, depth, active);
                if result != Valid {
                    return result;
                }
                evaluation.item(index);
            }
        }
        if let Some(child) = r.contains {
            let count = match evaluation::scan_contains(
                len,
                |index| self.eval(child, unsafe { sn_entry(value, index) }, depth, active),
                |index| evaluation.item(index),
            ) {
                Ok(count) => count,
                Err(status) => return status,
            };
            if bounds(count, Some(r.min_contains), r.max_contains) == Invalid {
                return Invalid;
            }
        }
        if let Some(child) = r.unevaluated.filter(|_| evaluation.item_count() < len) {
            if matches!(self.nodes[child].as_slice(), [Op::Boolean(false)]) {
                return Invalid;
            }
            for index in 0..len {
                if evaluation.contains_item(index) {
                    continue;
                }
                let result = self.eval(child, unsafe { sn_entry(value, index) }, depth, active);
                if result != Valid {
                    return result;
                }
                evaluation.item(index);
            }
        }
        Valid
    }
    fn object_tracked(
        &self,
        r: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        evaluation: &mut Tracked,
    ) -> Verdict {
        let len = unsafe { sn_len(value) };
        if bounds(len, r.min, r.max) == Invalid {
            return Invalid;
        }
        for &key in &r.required {
            if missing(value, key, self.undefined) {
                return Invalid;
            }
        }
        let found = match r.visit_properties(value, len, self.undefined, |index, child, item| {
            let result = self.record_value(child, item, depth, active);
            if result == Valid {
                evaluation.known_property(r.property_indices[index]);
            }
            result
        }) {
            Ok(found) => found,
            Err(status) => return status,
        };
        if r.names.is_some() || !r.patterns.is_empty() || (r.additional.is_some() && found < len) {
            let result = self.tracked_object_walk(r, value, depth, active, evaluation, false);
            if result != Valid {
                return result;
            }
        }
        for (name, required) in &r.dependent_required {
            if !missing(value, *name, self.undefined) {
                for &key in required {
                    if missing(value, key, self.undefined) {
                        return Invalid;
                    }
                }
            }
        }
        for &(key, child) in &r.dependent_schemas {
            if !missing(value, key, self.undefined) {
                let result = evaluation.merge(self.eval_tracked(child, value, depth, active));
                if result != Valid {
                    return result;
                }
            }
        }
        if let Some(child) = r.unevaluated.filter(|_| evaluation.property_count() < len) {
            if matches!(self.nodes[child].as_slice(), [Op::Boolean(false)]) {
                return Invalid;
            }
            let result = self.tracked_object_walk(r, value, depth, active, evaluation, true);
            if result != Valid {
                return result;
            }
        }
        Valid
    }
    fn tracked_object_walk(
        &self,
        rules: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        evaluation: &mut Tracked,
        unevaluated: bool,
    ) -> Verdict {
        let mut c = TrackingContext {
            engine: self,
            rules,
            depth,
            active,
            evaluation,
            unevaluated,
        };
        decode(unsafe {
            sn_hash_each(
                value,
                (&mut c as *mut TrackingContext).cast(),
                tracking_entry,
            )
        })
    }
}
struct TrackingContext<'a> {
    engine: &'a Execution<'a>,
    rules: &'a Object,
    depth: usize,
    active: scope::Context<'a>,
    evaluation: &'a mut Tracked,
    unevaluated: bool,
}
unsafe extern "C" fn tracking_entry(context: *mut c_void, key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &mut *context.cast::<TrackingContext>() };
        if unsafe { sn_kind(key) } != TYPE_STRING {
            return Unsupported as i32;
        }
        let key_location = JsonKey::new(key);
        let known = c.engine.property_ids.get(&key_location).copied();
        let child = if c.unevaluated {
            if known.map_or_else(
                || c.evaluation.properties.contains(&key_location),
                |index| c.evaluation.contains_known_property(index),
            ) {
                return Valid as i32;
            }
            c.rules.unevaluated
        } else {
            if let Some(child) = c.rules.names {
                let result = c.engine.eval(child, key, c.depth, c.active);
                if result != Valid {
                    return result as i32;
                }
            }
            let result = c.rules.visit_value_rules::<false>(
                c.engine.caches,
                key,
                Some(key_location),
                |_, _, child| match c.engine.eval(child, value, c.depth, c.active) {
                    Valid => {
                        if let Some(index) = known {
                            c.evaluation.known_property(index);
                        } else {
                            c.evaluation.properties.insert(key_location);
                        }
                        Ok(())
                    }
                    status => Err(status),
                },
            );
            return match result {
                Ok(_) => Valid as i32,
                Err(status) => status as i32,
            };
        };
        if let Some(child) = child {
            let result = c.engine.eval(child, value, c.depth, c.active);
            if result != Valid {
                return result as i32;
            }
            if let Some(index) = known {
                c.evaluation.known_property(index);
            } else {
                c.evaluation.properties.insert(key_location);
            }
        }
        Valid as i32
    }))
    .unwrap_or(Unsupported as i32)
}
