//! Resource/anchor lookup is compiled once. Evaluation only follows native
//! tables and stack frames, including when speculative branches collect annotations.
use super::*;
use tracking::JsonKey;
#[derive(Clone, Copy, Default)]
pub(super) struct Metadata {
    pub resource: Value,
    pub enters_scope: bool,
    pub recursive_anchor: bool,
    pub dynamic_anchor: Option<Value>,
    pub primary_binding: Option<usize>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acyclic_candidates_do_not_require_guards_for_unrelated_cycles() {
        let reference = |target| {
            Op::Ref(Reference {
                target,
                kind: ReferenceKind::Static,
            })
        };
        let mut engine = Engine {
            nodes: vec![
                vec![Op::Boolean(true)],
                vec![reference(1)],
                vec![reference(0)],
                vec![reference(0)],
            ],
            ..Engine::default()
        };
        engine.compile_memoization();
        assert_eq!(engine.memoizable, [true, false, false, false]);
        assert_eq!(engine.memo_guarded, [false; 4]);
        assert_eq!(engine.memo_guard_sources, [false; 4]);
    }

    #[test]
    fn clears_prior_guard_analysis_when_no_reuse_positions_remain() {
        let mut engine = Engine {
            nodes: (0..4)
                .map(|_| {
                    vec![Op::Ref(Reference {
                        target: 0,
                        kind: ReferenceKind::Static,
                    })]
                })
                .collect(),
            ..Engine::default()
        };
        engine.compile_memoization();
        assert!(engine.memo_guarded[0]);
        assert!(engine.memo_scope_projection.memory_usage() > 0);
        engine.nodes = vec![vec![Op::Boolean(true)], vec![Op::Boolean(false)]];
        engine.compile_memoization();
        assert_eq!(engine.memoizable, [false, false]);
        assert_eq!(engine.memo_guarded, [false, false]);
        assert_eq!(engine.memo_guard_sources, [false, false]);
        assert_eq!(engine.memo_scope_projection.memory_usage(), 0);
    }

    #[test]
    fn requires_guard_histories_for_cycles_reached_through_dynamic_overrides() {
        let reference = |target, kind| Op::Ref(Reference { target, kind });
        let mut engine = Engine {
            nodes: vec![
                vec![Op::Boolean(true)],
                vec![reference(0, ReferenceKind::Dynamic(0))],
                vec![reference(1, ReferenceKind::Static)],
                vec![reference(1, ReferenceKind::Static)],
                vec![reference(1, ReferenceKind::Static)],
            ],
            anchor_tables: vec![vec![(100, 0), (101, 1)]],
            ..Engine::default()
        };
        engine.compile_memoization();
        assert!(engine.memoizable[1]);
        assert!(engine.memo_guarded[1]);
        engine.nodes.pop();
        engine.compile_memoization();
        assert!(!engine.memoizable[1]);
        assert!(engine.memo_guard_sources[1]);
        engine.nodes.push(vec![reference(1, ReferenceKind::Static)]);
        engine.nodes[0] = vec![Op::Unsupported];
        engine.compile_memoization();
        assert!(!engine.memoizable[1]);
    }

    #[test]
    fn removes_scope_keys_only_for_proven_invariant_dynamic_targets() {
        let reference = |target, kind| Op::Ref(Reference { target, kind });
        let mut engine = Engine {
            nodes: vec![
                vec![Op::Boolean(true)],
                vec![reference(0, ReferenceKind::Dynamic(0))],
                vec![reference(0, ReferenceKind::Dynamic(0))],
                vec![Op::All(vec![1, 2])],
                vec![reference(3, ReferenceKind::Static)],
                vec![reference(3, ReferenceKind::Static)],
                vec![reference(0, ReferenceKind::Dynamic(1))],
                vec![reference(0, ReferenceKind::Dynamic(2))],
                vec![reference(0, ReferenceKind::Dynamic(3))],
                vec![reference(0, ReferenceKind::Recursive)],
            ],
            anchor_tables: vec![
                vec![(100, 0), (101, 0)],
                vec![(100, 0), (101, 3)],
                vec![(100, 3)],
                vec![],
            ],
            ..Engine::default()
        };
        engine.compile_memoization();
        assert!(engine.memoizable[3]);
        assert!(engine.memo_contextual[3]);
        engine.simplify_dynamic_references();
        engine.compile_memoization();
        assert!(engine.memoizable[3]);
        assert!(!engine.memo_contextual[3]);
        for node in [1, 2] {
            let Op::Ref(reference) = engine.nodes[node][0] else {
                panic!()
            };
            assert_eq!(reference.static_target(), Some(0));
        }
        // Changing bindings, fallback mismatches, absent bindings and
        // recursive references retain context-sensitive resolution.
        for node in [6, 7, 8, 9] {
            let Op::Ref(reference) = engine.nodes[node][0] else {
                panic!()
            };
            assert_eq!(reference.static_target(), None);
        }
    }
}
#[derive(Clone, Copy, Debug)]
enum ReferenceKind {
    Static,
    InvariantDynamic(usize),
    Recursive,
    Dynamic(usize),
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Reference {
    target: usize,
    kind: ReferenceKind,
}
#[derive(Clone, Copy, Default)]
pub(super) struct Context<'a> {
    pub active: Option<&'a RefFrame<'a>>,
    pub scope: Option<&'a ScopeFrame<'a>>,
}
pub(super) struct ScopeFrame<'a> {
    pub resource: Value,
    pub parent: Option<&'a ScopeFrame<'a>>,
    pub primary_binding: Option<usize>,
}
impl Reference {
    pub(super) fn dynamic_target(self) -> Option<(usize, usize)> {
        match self.kind {
            ReferenceKind::Dynamic(name) => Some((name, self.target)),
            _ => None,
        }
    }
    pub(super) fn callback_dynamic_target(self) -> Option<(usize, usize)> {
        match self.kind {
            ReferenceKind::Dynamic(name) | ReferenceKind::InvariantDynamic(name) => {
                Some((name, self.target))
            }
            _ => None,
        }
    }
    pub(super) fn recursive_target(self) -> Option<usize> {
        matches!(self.kind, ReferenceKind::Recursive).then_some(self.target)
    }
    pub(super) fn static_target(self) -> Option<usize> {
        matches!(
            self.kind,
            ReferenceKind::Static | ReferenceKind::InvariantDynamic(_)
        )
        .then_some(self.target)
    }
}
impl Engine {
    pub(super) fn simplify_dynamic_references(&mut self) {
        // Anchor binding has reached its fixed point, including resources
        // compiled while discovering overrides. A name whose every binding
        // equals the fallback target cannot change under any native scope.
        // Preserve the source opcode for diagnostic paths, while allowing
        // ordinary acyclic static-target memoization for the shared graph.
        let invariant: Vec<_> = self
            .anchor_tables
            .iter()
            .map(|bindings| {
                let &(_, target) = bindings.first()?;
                bindings
                    .iter()
                    .all(|&(_, candidate)| candidate == target)
                    .then_some(target)
            })
            .collect();
        for ops in &mut self.nodes {
            for op in ops {
                if let Op::Ref(reference) = op
                    && let ReferenceKind::Dynamic(name) = reference.kind
                    && invariant[name] == Some(reference.target)
                {
                    reference.kind = ReferenceKind::InvariantDynamic(name);
                }
            }
        }
    }

    pub(super) fn compile_scope(
        &mut self,
        program: Value,
        index: usize,
        flags: i64,
    ) -> Result<(), Value> {
        let node = self.field(program, FIELD_NODE)?;
        let resource = self.field(node, FIELD_RESOURCE)?;
        let recursive = self.field(program, FIELD_RECURSIVE_ANCHOR_P)?;
        let dynamic = self.field(program, FIELD_DYNAMIC_ANCHOR)?;
        self.metadata[index] = Metadata {
            resource,
            enters_scope: flags & i64::from(TRACKS_DYNAMIC_SCOPE) != 0,
            recursive_anchor: unsafe { sn_true(recursive) } != 0,
            primary_binding: None,
            dynamic_anchor: (unsafe { sn_same(dynamic, sn_nil()) } == 0).then_some(dynamic),
        };
        if !self.resources.contains_key(&resource) {
            // Reserve the resource before compiling its root: roots can reach
            // the current child through a recursive or dynamic reference.
            self.resources.insert(resource, usize::MAX);
            let mut root = 0;
            if unsafe { sn_resource_program(self.compiler, resource, &mut root) } != 0 {
                return Err(root);
            }
            self.retain(root);
            let root = self.compile(root)?;
            self.resources.insert(resource, root);
        }
        Ok(())
    }
    pub(super) fn compile_reference(
        &mut self,
        operand: Value,
        opcode: i32,
        target: usize,
    ) -> Result<Op, Value> {
        let fragment = self.field(operand, FIELD_FRAGMENT)?;
        let kind = if opcode == OP_RECURSIVE_REF
            && unsafe { sn_same(fragment, sn_nil()) } == 0
            && unsafe { sn_string_bytes(fragment) } == 0
            && self.metadata[target].recursive_anchor
        {
            ReferenceKind::Recursive
        } else if opcode == OP_DYNAMIC_REF {
            let anchor = self.metadata[target].dynamic_anchor;
            match anchor {
                Some(anchor)
                    if unsafe { sn_same(fragment, sn_nil()) } == 0
                        && unsafe { sn_string_bytes(fragment) } != 0
                        && unsafe { *sn_string_data(fragment) } != b'/'
                        && unsafe { sn_string_equal(fragment, anchor) } != 0 =>
                {
                    let name = JsonKey::new(fragment);
                    let index = if let Some(&index) = self.anchor_ids.get(&name) {
                        index
                    } else {
                        let index = self.anchor_names.len();
                        self.anchor_names.push(name);
                        self.anchor_ids.insert(name, index);
                        index
                    };
                    ReferenceKind::Dynamic(index)
                }
                _ => ReferenceKind::Static,
            }
        } else {
            ReferenceKind::Static
        };
        Ok(Op::Ref(Reference { target, kind }))
    }
    pub(super) fn bind_dynamic_anchors(&mut self) -> Result<(), Value> {
        // Names append during compilation. A resolved prefix per resource
        // records negative lookups without retaining their Cartesian product.
        // Snapshot only pending rows; compiling a binding can add resources
        // and names, which the next pass must resolve too.
        let mut resolved = HashMap::new();
        loop {
            let names = self.anchor_names.len();
            if names > 1 {
                return self.bind_indexed_dynamic_anchors();
            }
            let pending: Vec<_> = self
                .resources
                .keys()
                .filter_map(|&resource| {
                    let first = resolved.get(&resource).copied().unwrap_or(0);
                    (first < names).then_some((resource, first..names))
                })
                .collect();
            if pending.is_empty() {
                self.finish_dynamic_bindings();
                return Ok(());
            }
            for (resource, names) in pending {
                let end = names.end;
                for name in names {
                    let mut target = 0;
                    if unsafe {
                        sn_anchor_program(
                            self.compiler,
                            resource,
                            self.anchor_names[name].0,
                            &mut target,
                        )
                    } != 0
                    {
                        return Err(target);
                    }
                    if unsafe { sn_same(target, sn_nil()) } == 0 {
                        self.retain(target);
                        let target = self.compile(target)?;
                        self.dynamic_bindings.insert((resource, name), target);
                    }
                }
                resolved.insert(resource, end);
            }
        }
    }
    fn finish_dynamic_bindings(&mut self) {
        self.anchor_tables = vec![vec![]; self.anchor_names.len()];
        for (&(resource, name), &target) in &self.dynamic_bindings {
            self.anchor_tables[name].push((resource, target));
        }
        if self.anchor_names.len() == 1 {
            for metadata in &mut self.metadata {
                // Use the existing resource/name index instead of an
                // O(binding count) scan for every compiled node.
                metadata.primary_binding =
                    self.dynamic_bindings.get(&(metadata.resource, 0)).copied();
            }
        }
        // Compiler-only name indexes cannot be reused at runtime. Drop
        // their allocations and temporary GC roots after the fixed point.
        drop(std::mem::take(&mut self.anchor_ids));
        drop(std::mem::take(
            &mut unsafe { &mut *self.roots }.binding_names,
        ));
    }

    fn bind_indexed_dynamic_anchors(&mut self) -> Result<(), Value> {
        // Join registered names with resources that actually bind them. Resource
        // tables append names, including when external indexing augments an
        // existing resource. An indexed prefix admits only newly added names.
        let mut available: HashMap<JsonKey, Vec<Value>, BuildHasherDefault<BucketHasher>> =
            HashMap::default();
        let mut resolved_names = 0;
        let mut indexed = HashMap::new();
        loop {
            let mut pending = vec![];
            for &resource in self.resources.keys() {
                let first = indexed.get(&resource).copied().unwrap_or(0);
                if unsafe { sn_anchor_count(resource) } == first {
                    continue;
                }
                let mut names = 0;
                if unsafe { sn_anchor_names(self.compiler, resource, &mut names) } != 0 {
                    return Err(names);
                }
                // Copy handles before any Ruby callback. The snapshot Array
                // is never borrowed across allocation, and temporary roots
                // pin its names while the reverse index remains live.
                let count = unsafe { sn_len(names) };
                for i in first..count {
                    let name = unsafe { sn_entry(names, i) };
                    unsafe { &mut *self.roots }.binding_names.push(name);
                    let name = JsonKey::new(name);
                    available.entry(name).or_default().push(resource);
                    if let Some(&id) = self.anchor_ids.get(&name)
                        && id < resolved_names
                    {
                        pending.push((resource, id));
                    }
                }
                indexed.insert(resource, count);
            }
            let names = self.anchor_names.len();
            for id in resolved_names..names {
                if let Some(resources) = available.get(&self.anchor_names[id]) {
                    pending.extend(resources.iter().map(|&resource| (resource, id)));
                }
            }
            resolved_names = names;
            if pending.is_empty() {
                self.finish_dynamic_bindings();
                return Ok(());
            }
            for (resource, name) in pending {
                // Switching from single-name discovery can revisit a positive
                // pair already compiled. It must not invoke compilation twice.
                if self.dynamic_bindings.contains_key(&(resource, name)) {
                    continue;
                }
                let mut target = 0;
                if unsafe {
                    sn_anchor_program(
                        self.compiler,
                        resource,
                        self.anchor_names[name].0,
                        &mut target,
                    )
                } != 0
                {
                    return Err(target);
                }
                if unsafe { sn_same(target, sn_nil()) } == 0 {
                    self.retain(target);
                    let target = self.compile(target)?;
                    self.dynamic_bindings.insert((resource, name), target);
                }
            }
        }
    }
    pub(super) fn enter_scope<'a>(
        &self,
        node: usize,
        active: Context<'a>,
        frame: &'a ScopeFrame<'a>,
    ) -> Context<'a> {
        if self.metadata[node].enters_scope
            && active
                .scope
                .is_none_or(|scope| scope.resource != frame.resource)
        {
            Context {
                scope: Some(frame),
                ..active
            }
        } else {
            active
        }
    }
    fn scope_binding(&self, reference: Reference, resource: Value) -> Option<usize> {
        if let Some((name, _)) = reference.callback_dynamic_target() {
            return self.dynamic_bindings.get(&(resource, name)).copied();
        }
        let &root = self.resources.get(&resource)?;
        (reference.recursive_target().is_some() && self.metadata[root].recursive_anchor)
            .then_some(root)
    }
    pub(super) fn reference_target(&self, reference: Reference, context: Context<'_>) -> usize {
        if matches!(reference.kind, ReferenceKind::Dynamic(0)) && self.anchor_tables.len() == 1 {
            return context
                .scope
                .and_then(|frame| frame.primary_binding)
                .unwrap_or(reference.target);
        }
        let mut target = reference.target;
        let mut current = context.scope;
        // Linked frames walk inner to outer. Keep replacing a match so the
        // outermost matching resource wins, just as the VM's scope.each does.
        while let Some(frame) = current {
            if reference.static_target().is_some() {
                break;
            }
            if let Some(binding) = self.scope_binding(reference, frame.resource) {
                target = binding;
            }
            current = frame.parent;
        }
        target
    }
}

impl Execution<'_> {
    pub(super) fn resolve_reference(
        &self,
        reference: Reference,
        value: Value,
        active: Context<'_>,
    ) -> Result<usize, Verdict> {
        if !self.caches.scopes_enabled() {
            return Ok(self.engine.reference_target(reference, active));
        }
        let dynamic = reference.callback_dynamic_target();
        let recursive = reference.recursive_target();
        if dynamic.is_none() && recursive.is_none() {
            return Ok(reference.static_target().expect("static reference"));
        }
        let mut index = 0;
        while let Some(resource) = self.caches.scope_at(index) {
            if self.caches.callback_checkpoint(value) != Valid {
                return Err(Unsupported);
            }
            if let Some(target) = self.engine.scope_binding(reference, resource) {
                return Ok(target);
            }
            index += 1;
        }
        Ok(dynamic
            .map(|(_, fallback)| fallback)
            .or(recursive)
            .expect("scoped reference"))
    }
}
