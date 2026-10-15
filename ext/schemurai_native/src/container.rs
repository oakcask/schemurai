//! Ruby container primitives and native-child requests without storage loans.
use super::*;

#[derive(Debug)]
pub(super) struct Header {
    source: Value,
    checks: u8,
    object: bool,
    native_bounds: bool,
    native_required: bool,
    required_count: usize,
    native_dependencies: bool,
    dependencies: Vec<Dependency>,
}
#[derive(Debug)]
struct Dependency {
    count: usize,
    keyword: &'static str,
}
impl Header {
    pub(super) fn contains(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        child: usize,
        depth: usize,
        scalar: (i32, i32),
    ) -> Verdict {
        caches.contains(self.source, value, child, depth, required, scalar)
    }
    pub(super) fn children(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        node: usize,
        depth: usize,
    ) -> Verdict {
        caches.array_children(self.source, value, node, depth, required)
    }
    pub(super) fn runtime_required(&self, caches: &runtime::Caches, kind: i32) -> bool {
        !self.native_bounds
            || !self.native_required
            || !self.native_dependencies
            || kind == TYPE_UNSUPPORTED
            || caches.dynamic_calls()
    }
    pub(super) fn valid(&self, caches: &runtime::Caches, required: i32, value: Value) -> Verdict {
        caches
            .container(self.source, value, required, self.object)
            .map_or(Unsupported, |frame| frame.step(0))
    }
    pub(super) fn failures(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        silent: bool,
        mut visit: impl FnMut(&'static str, Value) -> Result<(), Verdict>,
    ) -> Result<bool, Verdict> {
        let frame = caches.container(self.source, value, required, self.object)?;
        if !frame.predicate(1)? {
            if required != 0 {
                visit("type", frame.ordinal())?;
            }
            return Ok(false);
        }
        for (bit, step, keyword) in [
            (
                1,
                2,
                if self.object {
                    "maxProperties"
                } else {
                    "maxItems"
                },
            ),
            (
                2,
                3,
                if self.object {
                    "minProperties"
                } else {
                    "minItems"
                },
            ),
            (4, 4, "uniqueItems"),
        ] {
            if self.checks & bit != 0 && !frame.predicate(step)? {
                visit(keyword, frame.ordinal())?;
                if silent {
                    return Ok(true);
                }
            }
        }
        if self.checks & 32 != 0 {
            frame.predicate(7)?;
            for index in 0..self.required_count {
                let step = i32::try_from(index)
                    .ok()
                    .and_then(|index| index.checked_add(8))
                    .ok_or(Unsupported)?;
                if !frame.predicate(step)? {
                    visit("required", frame.ordinal())?;
                    if silent {
                        return Ok(true);
                    }
                }
            }
        }
        if self.checks & 8 != 0 {
            frame.predicate(5)?;
        }
        if self.checks & 16 != 0 {
            frame.predicate(6)?;
        }
        let mut step = self.required_count.checked_add(8).ok_or(Unsupported)?;
        for dependency in &self.dependencies {
            let trigger = i32::try_from(step).map_err(|_| Unsupported)?;
            if frame.predicate(trigger)? {
                frame.predicate(trigger.checked_add(1).ok_or(Unsupported)?)?;
                for index in 0..dependency.count {
                    let key = step
                        .checked_add(index)
                        .and_then(|step| step.checked_add(2))
                        .and_then(|step| i32::try_from(step).ok())
                        .ok_or(Unsupported)?;
                    if !frame.predicate(key)? {
                        visit(dependency.keyword, frame.ordinal())?;
                        if silent {
                            return Ok(true);
                        }
                    }
                }
            }
            step = step
                .checked_add(dependency.count)
                .and_then(|step| step.checked_add(2))
                .ok_or(Unsupported)?;
        }
        Ok(true)
    }
}
impl Engine {
    pub(super) fn scalar_callbacks_safe(&self, root: usize, depth: usize) -> bool {
        self.scalar_callback_depths
            .get(root)
            .copied()
            .flatten()
            .is_some_and(|extra| {
                depth
                    .checked_add(extra)
                    .is_some_and(|total| total <= MAX_EVALUATION_DEPTH)
            })
    }
    // Admit callbacks only when every reachable assertion has a runtime path.
    // Otherwise a later unsupported container could replay an already invoked
    // user block through the VM. Postorder leaves cycles unproven.
    pub(super) fn compile_scalar_callback_depths(&mut self) {
        if !self.nodes.iter().flatten().any(|op| {
            matches!(op, Op::Array(_, rules) if rules.unevaluated.is_none() && !rules.header_only())
        }) {
            self.scalar_callback_depths.clear();
            self.callback_child_depths.clear();
            return;
        }
        let mut edges = vec![vec![]; self.nodes.len()];
        let mut admitted = vec![true; self.nodes.len()];
        let mut child_admitted = vec![true; self.nodes.len()];
        let mut contains = vec![false; self.nodes.len()];
        for (node, ops) in self.nodes.iter().enumerate() {
            admitted[node] = !self.tracks[node];
            for (index, op) in ops.iter().enumerate() {
                // Simplified dynamic references still have VM scope polling;
                // only original static references can enter an isolated child.
                if matches!(op, Op::Ref(_)) && self.error_operands[node][index].0 != OP_REF {
                    child_admitted[node] = false;
                }
                match op {
                    Op::Boolean(_)
                    | Op::Type(..)
                    | Op::Number(..)
                    | Op::String(..)
                    | Op::Const(_)
                    | Op::Enum(_) => {}
                    Op::Array(_, rules) if rules.header_only() => {}
                    Op::Array(_, rules) if rules.unevaluated.is_none() => {
                        contains[node] = true;
                        edges[node].extend(rules.callback_children().copied());
                    }
                    Op::Object(_, rules) if rules.header_only() => {}
                    Op::Ref(reference) => match reference.static_target() {
                        Some(child) => edges[node].push(child),
                        None => admitted[node] = false,
                    },
                    Op::All(children) => edges[node].extend(children),
                    Op::Any(children) | Op::One(children) => {
                        edges[node].extend(children.iter().map(|&(child, _)| child))
                    }
                    Op::Not(child) => edges[node].push(*child),
                    Op::Conditional(condition, yes, no) => {
                        edges[node].push(*condition);
                        edges[node].extend(yes.iter().chain(no));
                    }
                    Op::Array(..) | Op::Object(..) | Op::Unsupported | Op::UnresolvedRef(_) => {
                        admitted[node] = false
                    }
                }
            }
        }
        let order = graph::postorder(&edges, &mut vec![false; edges.len()]);
        let mut depths: Vec<Option<usize>> = vec![None; edges.len()];
        let mut child_depths: Vec<Option<usize>> = vec![None; edges.len()];
        for node in order {
            contains[node] |= edges[node].iter().any(|&child| contains[child]);
            let extend_depth = |depths: &[Option<usize>]| {
                edges[node].iter().try_fold(0, |depth, &child| {
                    Some(depth.max(depths[child]?.checked_add(1)?))
                })
            };
            if admitted[node] && child_admitted[node] {
                child_depths[node] = extend_depth(&child_depths);
            }
            let contains_children_safe = self.nodes[node].iter().all(|op| match op {
                Op::Array(_, rules) => rules
                    .callback_children()
                    .all(|&child| child_depths[child].is_some()),
                _ => true,
            });
            if admitted[node] && contains_children_safe {
                depths[node] = extend_depth(&depths);
            }
        }
        self.scalar_callback_depths = depths
            .into_iter()
            .enumerate()
            .map(|(node, depth)| if contains[node] { depth } else { None })
            .collect();
        self.callback_child_depths = child_depths;
    }
    pub(super) fn scalar_callback_kind(&self, child: usize) -> (i32, i32) {
        match self.nodes[child].as_slice() {
            [Op::Boolean(value)] => (CALLBACK_BOOLEAN, i32::from(*value)),
            [Op::Type(mask, union)] => (CALLBACK_TYPE, mask * 2 + i32::from(*union)),
            _ => (CALLBACK_RUNTIME, 0),
        }
    }
    pub(super) fn callback_array_node(&self, node: usize) -> bool {
        self.nodes[node].iter().any(|op| {
            matches!(op, Op::Array(_, rules) if !rules.header_only() && self.array_callbacks(rules))
        })
    }
    // Children share no inherited dynamic binding or exported coverage.
    pub(super) fn array_callbacks(&self, rules: &Array) -> bool {
        rules.unevaluated.is_none()
            && rules.callback_children().all(|&child| {
                self.callback_child_depths
                    .get(child)
                    .is_some_and(Option::is_some)
            })
    }
    pub(super) fn scalar_contains(&self, rules: &Array) -> bool {
        rules.has_no_item_schemas() && rules.contains.is_some() && self.array_callbacks(rules)
    }
    pub(super) fn container_header(
        &mut self,
        source: Value,
        maximum: &'static [u8],
        minimum: &'static [u8],
        object: bool,
        tail: u8,
    ) -> Result<Header, Value> {
        let maximum = self.field(source, maximum)?;
        let minimum = self.field(source, minimum)?;
        let native_bounds = self.native_count(maximum)? && self.native_count(minimum)?;
        let required = if object {
            self.field(source, b"required\0")?
        } else {
            unsafe { sn_nil() }
        };
        let inspect_required = unsafe { sn_truthy(required) } != 0;
        let required_kind = unsafe { sn_kind(required) };
        let mut dependencies = vec![];
        let mut native_dependencies = true;
        if object {
            for (field, keyword) in [
                (b"dependencies\0".as_slice(), "dependencies"),
                (b"dependent_required\0", "dependentRequired"),
            ] {
                let entries = self.field(source, field)?;
                for pair in self.values(entries) {
                    let names = unsafe { sn_entry(pair, 1) };
                    let kind = unsafe { sn_kind(names) };
                    native_dependencies &= kind == TYPE_ARRAY;
                    dependencies.push(Dependency {
                        count: if matches!(kind, TYPE_ARRAY | TYPE_OBJECT) {
                            unsafe { sn_len(names) }
                        } else {
                            0
                        },
                        keyword,
                    });
                }
            }
        }
        Ok(Header {
            source,
            native_bounds,
            native_required: !inspect_required || required_kind == TYPE_ARRAY,
            native_dependencies,
            dependencies,
            required_count: if matches!(required_kind, TYPE_ARRAY | TYPE_OBJECT) {
                unsafe { sn_len(required) }
            } else {
                0
            },
            checks: unsafe { sn_truthy(maximum) } as u8
                | ((unsafe { sn_truthy(minimum) } as u8) << 1)
                | tail
                | if inspect_required { 32 } else { 0 }
                | if object { 16 } else { 0 },
            object,
        })
    }
    fn native_count(&mut self, value: Value) -> Result<bool, Value> {
        if unsafe { sn_truthy(value) } == 0 {
            return Ok(true);
        }
        if unsafe { sn_fixnum(value) } != 0 {
            return Ok(unsafe { sn_integer(value) } >= 0);
        }
        if unsafe { sn_kind(value) } & TYPE_INTEGER == 0 {
            return Ok(false);
        }
        if unsafe { sn_is_float(value) } != 0 {
            return Ok(unsafe { sn_float(value) } >= 0.0);
        }
        let negative = self.field(value, b"negative?\0")?;
        Ok(unsafe { sn_true(negative) } == 0)
    }
}
impl Array {
    fn callback_children(&self) -> impl Iterator<Item = &usize> {
        self.prefix
            .iter()
            .chain(&self.items)
            .chain(self.additional.iter().filter(|_| self.list))
            .chain(self.contains.iter())
    }
    fn has_no_item_schemas(&self) -> bool {
        self.prefix.is_empty()
            && self.items.is_empty()
            && (!self.list || self.additional.is_none())
            && self.unevaluated.is_none()
    }
    pub(super) fn header_only(&self) -> bool {
        self.has_no_item_schemas() && self.contains.is_none()
    }
}
impl Object {
    pub(super) fn valid_header(
        &self,
        caches: &runtime::Caches,
        value: Value,
        undefined: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        let status = bounds(unsafe { sn_len(value) }, self.min, self.max);
        if status != Valid {
            return status;
        }
        let status = Self::check_keys(&self.required_order, caches, value, undefined, budget);
        if status != Valid {
            return status;
        }
        self.check_dependent_required(caches, value, undefined, budget)
    }
    pub(super) fn header_only(&self) -> bool {
        self.properties.is_empty()
            && self.patterns.is_empty()
            && self.additional.is_none()
            && self.names.is_none()
            && self.dependent_schemas.is_empty()
            && self.unevaluated.is_none()
    }
}
