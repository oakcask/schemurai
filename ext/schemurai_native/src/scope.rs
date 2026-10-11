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
    fn proves_only_invariant_dynamic_targets_and_enables_shared_graph_memoization() {
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
        assert!(!engine.memoizable[3]);
        engine.simplify_dynamic_references();
        engine.compile_memoization();
        assert!(engine.memoizable[3]);
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
    pub(super) fn static_target(self) -> Option<usize> {
        matches!(self.kind, ReferenceKind::Static).then_some(self.target)
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
                    reference.kind = ReferenceKind::Static;
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
        let node = self.field(program, b"node\0")?;
        let resource = self.field(node, b"resource\0")?;
        let recursive = self.field(program, b"recursive_anchor?\0")?;
        let dynamic = self.field(program, b"dynamic_anchor\0")?;
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
        let fragment = self.field(operand, b"fragment\0")?;
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
                    let index = self
                        .anchor_names
                        .iter()
                        .position(|&candidate| candidate == name)
                        .unwrap_or_else(|| {
                            let index = self.anchor_names.len();
                            self.anchor_names.push(name);
                            index
                        });
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
        loop {
            let pending: Vec<_> = self
                .resources
                .keys()
                .flat_map(|&resource| {
                    (0..self.anchor_names.len()).map(move |name| (resource, name))
                })
                .filter(|key| !self.dynamic_bindings.contains_key(key))
                .collect();
            if pending.is_empty() {
                self.anchor_tables = vec![vec![]; self.anchor_names.len()];
                for (&(resource, name), &target) in &self.dynamic_bindings {
                    if let Some(target) = target {
                        self.anchor_tables[name].push((resource, target));
                    }
                }
                if self.anchor_tables.len() == 1 {
                    for metadata in &mut self.metadata {
                        metadata.primary_binding =
                            self.anchor_tables[0]
                                .iter()
                                .find_map(|&(resource, target)| {
                                    (resource == metadata.resource).then_some(target)
                                });
                    }
                }
                return Ok(());
            }
            for (resource, name) in pending {
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
                self.retain(target);
                let target = if unsafe { sn_same(target, sn_nil()) } != 0 {
                    None
                } else {
                    Some(self.compile(target)?)
                };
                self.dynamic_bindings.insert((resource, name), target);
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
            match reference.kind {
                ReferenceKind::Static => break,
                ReferenceKind::Recursive => {
                    if let Some(&root) = self.resources.get(&frame.resource)
                        && self.metadata[root].recursive_anchor
                    {
                        target = root;
                    }
                }
                ReferenceKind::Dynamic(name) => {
                    if let Some(Some(binding)) = self.dynamic_bindings.get(&(frame.resource, name))
                    {
                        target = *binding;
                    }
                }
            }
            current = frame.parent;
        }
        target
    }
}
