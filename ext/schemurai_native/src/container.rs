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
        scalar: (i32, i32),
    ) -> Verdict {
        caches.contains(self.source, value, child, required, scalar)
    }
    pub(super) fn children(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        node: usize,
    ) -> Verdict {
        caches.container_children(self.source, value, node, required, self.object)
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
    pub(super) fn scalar_callbacks_safe(&self, root: usize) -> bool {
        self.callback_roots.get(root) == Some(&true)
    }
    pub(super) fn native_continuations_safe(&self, root: usize) -> bool {
        self.validity_supported.get(root) == Some(&true)
    }
    pub(super) fn report_continuations_safe(&self, root: usize) -> bool {
        self.report_supported.get(root) == Some(&true)
    }
    // Admit callbacks only when every reachable assertion has a runtime path.
    // Otherwise a later unsupported container could replay an already invoked
    // user block through the VM. Native continuations bound physical stack
    // depth, so cycles need coverage propagation rather than a DAG proof.
    pub(super) fn compile_native_validity_support(&mut self) {
        let count = self.nodes.len();
        self.has_references = self
            .nodes
            .iter()
            .flatten()
            .any(|op| matches!(op, Op::Ref(_)));
        // One zero-depth dispatch vertex per name avoids repeating every
        // possible binding edge for each dynamic reference.
        let recursive = count + self.anchor_tables.len();
        let mut edges = vec![vec![]; recursive + 1];
        let mut admitted = vec![true; edges.len()];
        let mut callbacks = vec![false; edges.len()];
        let mut report_unsupported = vec![false; edges.len()];
        for (name, bindings) in self.anchor_tables.iter().enumerate() {
            edges[count + name].extend(bindings.iter().map(|&(_, target)| target));
        }
        edges[recursive].extend(
            self.resources
                .values()
                .copied()
                .filter(|&root| self.metadata[root].recursive_anchor),
        );
        for (node, ops) in self.nodes.iter().enumerate() {
            admitted[node] = true;
            for op in ops {
                // Unresolved references have native failure and report paths;
                // only instructions without an execution path block callbacks.
                report_unsupported[node] |= matches!(op, Op::Unsupported);
                match op {
                    Op::UnresolvedRef(_)
                    | Op::Boolean(_)
                    | Op::Type(..)
                    | Op::Number(..)
                    | Op::String(..)
                    | Op::Const(_)
                    | Op::Enum(_) => {}
                    Op::Array(_, rules) if rules.header_only() => {}
                    Op::Array(_, rules) => {
                        callbacks[node] = true;
                        edges[node].extend(
                            rules
                                .callback_children()
                                .chain(rules.unevaluated.iter())
                                .copied(),
                        );
                    }
                    Op::Object(_, rules) if rules.header_only() => {}
                    Op::Object(_, rules) => {
                        callbacks[node] = true;
                        edges[node].extend(
                            rules
                                .callback_children()
                                .chain(rules.unevaluated.iter())
                                .copied(),
                        );
                    }
                    Op::Ref(reference) => {
                        if let Some((name, fallback)) = reference.callback_dynamic_target() {
                            edges[node].extend([fallback, count + name]);
                        } else if let Some(fallback) = reference.recursive_target() {
                            edges[node].extend([fallback, recursive]);
                        } else {
                            edges[node].push(reference.static_target().expect("static reference"));
                        }
                    }
                    Op::All(children) => edges[node].extend(children),
                    Op::Any(children) | Op::One(children) => {
                        edges[node].extend(children.iter().map(|&(child, _)| child))
                    }
                    Op::Not(child) => edges[node].push(*child),
                    Op::Conditional(condition, yes, no) => {
                        edges[node].push(*condition);
                        edges[node].extend(yes.iter().chain(no));
                    }
                    Op::Unsupported => admitted[node] = false,
                }
            }
        }
        let parents = graph::parents(&edges);
        graph::propagate(&mut report_unsupported, &parents);
        // Tracked arrays enter collection even through validity. They need the
        // complete result path, while ordinary validity children may also use
        // the existing object callbacks.
        for node in 0..count {
            if self.tracks[node] {
                admitted[node] &= !report_unsupported[node];
            }
        }
        let mut unsupported: Vec<_> = admitted.into_iter().map(|allowed| !allowed).collect();
        graph::propagate(&mut unsupported, &parents);
        self.report_supported = report_unsupported[..count]
            .iter()
            .map(|&blocked| !blocked)
            .collect();
        graph::propagate(&mut callbacks, &parents);
        self.validity_supported = unsupported[..count]
            .iter()
            .map(|&blocked| !blocked)
            .collect();
        self.callback_roots = callbacks[..count]
            .iter()
            .zip(&self.validity_supported)
            .map(|(&callback, &supported)| callback && supported)
            .collect();
    }
    pub(super) fn scalar_callback_kind(&self, child: usize) -> (i32, i32) {
        if self.metadata[child].enters_scope {
            return (CALLBACK_RUNTIME, 0);
        }
        match self.nodes[child].as_slice() {
            [Op::Boolean(value)] => (CALLBACK_BOOLEAN, i32::from(*value)),
            [Op::Type(mask, union)] => (CALLBACK_TYPE, mask * 2 + i32::from(*union)),
            _ => (CALLBACK_RUNTIME, 0),
        }
    }
    pub(super) fn callback_container_node(&self, node: usize) -> bool {
        self.nodes[node].iter().any(|op| match op {
            Op::Array(_, rules) => !rules.header_only() && self.array_callbacks(rules),
            Op::Object(_, rules) => !rules.header_only() && self.object_callbacks(rules),
            _ => false,
        })
    }
    // Runtime children inherit reference context but export validity only.
    pub(super) fn array_callbacks(&self, rules: &Array) -> bool {
        rules.unevaluated.is_none() && self.callback_children_safe(rules.callback_children())
    }
    pub(super) fn array_report_callbacks(&self, rules: &Array) -> bool {
        rules
            .callback_children()
            .chain(rules.unevaluated.iter())
            .all(|&child| self.report_supported.get(child) == Some(&true))
    }
    pub(super) fn object_report_callbacks(&self, rules: &Object) -> bool {
        rules
            .callback_children()
            .chain(rules.unevaluated.iter())
            .all(|&child| self.report_supported.get(child) == Some(&true))
    }
    pub(super) fn object_callbacks(&self, rules: &Object) -> bool {
        rules.unevaluated.is_none() && self.callback_children_safe(rules.callback_children())
    }
    fn callback_children_safe<'a>(&self, mut children: impl Iterator<Item = &'a usize>) -> bool {
        children.all(|&child| self.validity_supported.get(child) == Some(&true))
    }
    pub(super) fn scalar_contains(&self, rules: &Array) -> bool {
        rules.has_no_item_schemas() && rules.contains.is_some() && self.array_callbacks(rules)
    }
    pub(super) fn container_header(
        &mut self,
        source: Value,
        maximum: i32,
        minimum: i32,
        object: bool,
        tail: u8,
    ) -> Result<Header, Value> {
        let maximum = self.field(source, maximum)?;
        let minimum = self.field(source, minimum)?;
        let native_bounds = self.native_count(maximum)? && self.native_count(minimum)?;
        let required = if object {
            self.field(source, FIELD_REQUIRED)?
        } else {
            unsafe { sn_nil() }
        };
        let inspect_required = unsafe { sn_truthy(required) } != 0;
        let required_kind = unsafe { sn_kind(required) };
        let mut dependencies = vec![];
        let mut native_dependencies = true;
        if object {
            for (field, keyword) in [
                (FIELD_DEPENDENCIES, "dependencies"),
                (FIELD_DEPENDENT_REQUIRED, "dependentRequired"),
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
        let negative = self.field(value, FIELD_NEGATIVE_P)?;
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
    fn callback_children(&self) -> impl Iterator<Item = &usize> {
        self.properties
            .iter()
            .map(|(_, child)| child)
            .chain(self.patterns.iter().map(|(_, child)| child))
            .chain(self.additional.iter())
            .chain(self.names.iter())
            .chain(self.dependent_schemas.iter().map(|(_, child)| child))
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admits_unresolved_reports_but_propagates_unsupported_instructions() {
        let mut engine = Engine {
            nodes: vec![
                vec![Op::UnresolvedRef(0)],
                vec![Op::All(vec![0, 1])],
                vec![Op::Unsupported],
                vec![Op::All(vec![1, 2])],
            ],
            tracks: vec![false, true, false, true],
            metadata: vec![scope::Metadata::default(); 4],
            ..Engine::default()
        };
        engine.compile_native_validity_support();
        for root in 0..4 {
            assert_eq!(engine.native_continuations_safe(root), root < 2);
            assert_eq!(engine.report_continuations_safe(root), root < 2);
        }
    }
}
