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

// Store only nonempty words. The common single-word case needs no allocation,
// even when its property IDs are near the end of a large compiled engine.
#[derive(Clone, Default)]
enum PropertyWords {
    #[default]
    Empty,
    Single(usize, u64),
    Dense(usize, Vec<u64>),
    Many(HashMap<usize, u64>),
}
#[derive(Clone, Default)]
struct PropertyBits {
    words: PropertyWords,
    count: usize,
}
impl PropertyBits {
    fn word(&self, index: usize) -> u64 {
        match &self.words {
            PropertyWords::Empty => 0,
            PropertyWords::Single(at, bits) => {
                if *at == index {
                    *bits
                } else {
                    0
                }
            }
            PropertyWords::Dense(first, words) => index
                .checked_sub(*first)
                .and_then(|offset| words.get(offset))
                .copied()
                .unwrap_or(0),
            PropertyWords::Many(words) => words.get(&index).copied().unwrap_or(0),
        }
    }
    fn insert_word(&mut self, index: usize, bits: u64) {
        let previous = self.word(index);
        self.count += (bits & !previous).count_ones() as usize;
        match &mut self.words {
            PropertyWords::Empty => self.words = PropertyWords::Single(index, bits),
            PropertyWords::Single(at, existing) if *at == index => *existing |= bits,
            PropertyWords::Single(at, existing) if at.abs_diff(index) < 128 => {
                let first = (*at).min(index);
                let mut words = vec![0; at.abs_diff(index) + 1];
                words[*at - first] = *existing;
                words[index - first] = bits;
                self.words = PropertyWords::Dense(first, words);
            }
            PropertyWords::Single(at, existing) => {
                self.words = PropertyWords::Many(HashMap::from([(*at, *existing), (index, bits)]));
            }
            PropertyWords::Dense(first, words)
                if index >= *first && index - *first < words.len() =>
            {
                words[index - *first] |= bits;
            }
            PropertyWords::Dense(first, words)
                if index.max(*first + words.len() - 1) - index.min(*first) < 128 =>
            {
                if index < *first {
                    let offset = *first - index;
                    words.splice(0..0, std::iter::repeat_n(0, offset));
                    *first = index;
                } else {
                    words.resize(index - *first + 1, 0);
                }
                words[index - *first] |= bits;
            }
            PropertyWords::Dense(first, words) => {
                let mut sparse: HashMap<_, _> = words
                    .iter()
                    .enumerate()
                    .filter(|&(_, &word)| word != 0)
                    .map(|(offset, &word)| (*first + offset, word))
                    .collect();
                sparse.insert(index, bits);
                self.words = PropertyWords::Many(sparse);
            }
            PropertyWords::Many(words) => *words.entry(index).or_default() |= bits,
        }
    }
    fn insert(&mut self, index: usize) {
        self.insert_word(index / 64, 1_u64 << (index % 64));
    }
    fn contains(&self, index: usize) -> bool {
        self.word(index / 64) & (1_u64 << (index % 64)) != 0
    }
    fn merge(&mut self, other: Self) {
        if matches!(self.words, PropertyWords::Empty) {
            *self = other;
            return;
        }
        match other.words {
            PropertyWords::Empty => {}
            PropertyWords::Single(index, bits) => self.insert_word(index, bits),
            PropertyWords::Dense(first, words) => {
                for (offset, bits) in words.into_iter().enumerate() {
                    if bits != 0 {
                        self.insert_word(first + offset, bits);
                    }
                }
            }
            PropertyWords::Many(words) => {
                for (index, bits) in words {
                    self.insert_word(index, bits);
                }
            }
        }
    }
}

#[derive(Clone)]
pub(super) struct Tracked {
    pub status: Verdict,
    properties: KeySet,
    known_properties: PropertyBits,
    items: Vec<u64>,
}
impl Tracked {
    // Bound retained annotation slots independently of the number of results.
    pub(super) fn memo_slots(&self) -> usize {
        self.properties.capacity()
            + self.items.capacity()
            + match &self.known_properties.words {
                PropertyWords::Empty | PropertyWords::Single(..) => 0,
                PropertyWords::Dense(_, words) => words.capacity(),
                PropertyWords::Many(words) => words.capacity(),
            }
    }
    pub(super) fn new(status: Verdict) -> Self {
        Self {
            status,
            properties: KeySet::default(),
            known_properties: PropertyBits::default(),
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
        self.known_properties.insert(index);
    }
    fn contains_known_property(&self, index: usize) -> bool {
        self.known_properties.contains(index)
    }
    pub(super) fn property_count(&self) -> usize {
        self.properties.len() + self.known_properties.count
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
        self.known_properties.merge(other.known_properties);
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
    // contains needs the trial outcome, not the child's exported annotations.
    pub(super) fn trial_status(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Verdict {
        if depth > MAX_EVALUATION_DEPTH || !self.budget.checkpoint() {
            return Unsupported;
        }
        let kind_state = InstanceKind::new(TYPE_UNCHECKED);
        let kind = self.diagnostic_kind(node, value, &kind_state);
        if kind == TYPE_UNSUPPORTED {
            return Unsupported;
        }
        self.trial_scalar(node, value, depth, kind)
            .unwrap_or_else(|| {
                self.eval_tracked_kind(node, value, depth, active, &kind_state)
                    .status
            })
    }
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
        if !self.budget.checkpoint() {
            return Tracked::new(Unsupported);
        }
        let kind = InstanceKind::new(TYPE_UNCHECKED);
        self.eval_tracked_kind(node, value, depth, active, &kind)
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
        kind_state: &InstanceKind,
    ) -> Tracked {
        let kind = self.diagnostic_kind(node, value, kind_state);
        if !self.budget.checkpoint() {
            return Tracked::new(Unsupported);
        }
        if depth <= MAX_EVALUATION_DEPTH
            && kind != TYPE_UNSUPPORTED
            && let Some(status) = self.trial_scalar(node, value, depth, kind)
        {
            return Tracked::new(status);
        }
        let Some(key) = self
            .memo
            .key(self, node, value, depth, active, &self.budget)
        else {
            if self.budget.hit.get().0 != 0 {
                return Tracked::new(Unsupported);
            }
            return self.eval_tracked_uncached(node, value, depth, active, kind_state);
        };
        if self.budget.hit.get().0 != 0 || !self.budget.checkpoint() {
            return Tracked::new(Unsupported);
        }
        if let Some(result) = self.memo.tracked(key) {
            return result;
        }
        let result = self.eval_tracked_uncached(node, value, depth, active, kind_state);
        self.memo.record_tracked(key, &result);
        result
    }
    fn eval_tracked_uncached(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        kind_state: &InstanceKind,
    ) -> Tracked {
        self.collect_trial(node, value, depth, active, kind_state)
    }
    pub(super) fn array_tracked(
        &self,
        r: &Array,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        evaluation: &mut Tracked,
    ) -> Verdict {
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
        for (index, &child) in r.prefix.iter().take(len).enumerate() {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
            let result = self.eval(child, unsafe { sn_entry(value, index) }, depth, active);
            if result != Valid {
                return result;
            }
            evaluation.item(index);
        }
        for index in 0..len {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
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
                evaluation::ContainsPolicy::AllMatches,
                |index| self.trial_status(child, unsafe { sn_entry(value, index) }, depth, active),
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
                if !self.budget.checkpoint() {
                    return Unsupported;
                }
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
    pub(super) fn object_tracked(
        &self,
        r: &Object,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        evaluation: &mut Tracked,
    ) -> Verdict {
        if !self.budget.checkpoint() {
            return Unsupported;
        }
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
                value,
                len,
                self.undefined,
                &self.budget,
                |index, child, item| {
                    let result = self.record_value(child, item, depth, active);
                    if result == Valid {
                        evaluation.known_property(r.property_indices[index]);
                    }
                    result
                },
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
            let result = self.tracked_object_walk(r, value, depth, active, evaluation, false);
            if result != Valid {
                return result;
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
        for &(key, child) in &r.dependent_schemas {
            if !self.budget.checkpoint() {
                return Unsupported;
            }
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
        if !c.engine.budget.checkpoint() {
            return Unsupported as i32;
        }
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
            if !c.engine.caches.runtime_order()
                && let Some(child) = c.rules.names
            {
                let result = c.engine.eval(child, key, c.depth, c.active);
                if result != Valid {
                    return result as i32;
                }
            }
            let result = c.rules.visit_value_rules(
                c.engine.caches,
                &c.engine.budget,
                c.engine.caches.runtime_order(),
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
