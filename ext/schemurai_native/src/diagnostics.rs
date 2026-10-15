//! Diagnostics traverse borrowed VALUEs without Ruby allocation. Only after
//! returning to C are the output records materialized as Ruby objects.
use super::*;
use tracking::Tracked;

fn reference_keyword(opcode: i32) -> &'static str {
    match opcode {
        OP_RECURSIVE_REF => "$recursiveRef",
        OP_DYNAMIC_REF => "$dynamicRef",
        _ => "$ref",
    }
}

#[derive(Clone)]
struct Error {
    keyword: &'static str,
    instance_path: pointer::Rendered,
    schema_path: pointer::Rendered,
    opcode: i32,
    operand: Value,
    instance: Value,
    detail: usize,
    message: Value,
}
#[derive(Clone, Default)]
pub struct Report {
    errors: Vec<Error>,
    annotations: bool,
    evaluation: Option<Tracked>,
    attempts: usize,
    instance_path: pointer::Path,
    schema_path: pointer::Path,
    // Explicit failure signal for the current evaluation, independent of the
    // number or rendering of diagnostic records. Child evaluations isolate it.
    failed: bool,
    silent: bool,
    render_messages: bool,
    limits: budget::Limits,
    limit_hit: (u32, usize),
}
impl Report {
    pub(super) fn continuation(&self, annotations: bool) -> Self {
        let mut report = self.clone();
        report.annotations = annotations;
        report.evaluation = None;
        report
    }
    pub(super) fn adopt(&mut self, mut completed: Self) -> Tracked {
        let evaluation = completed
            .evaluation
            .take()
            .expect("completed native report");
        completed.annotations = self.annotations;
        *self = completed;
        evaluation
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.errors.capacity() * std::mem::size_of::<Error>()
            + self.instance_path.memory_usage()
            + self.schema_path.memory_usage()
            + self
                .errors
                .iter()
                .map(|e| e.instance_path.memory_usage() + e.schema_path.memory_usage())
                .sum::<usize>()
            + self.evaluation.as_ref().map_or(0, Tracked::memory_usage)
    }
    pub(super) fn mark(&self) {
        for path in [&self.instance_path, &self.schema_path] {
            for &(_, value) in &path.names {
                unsafe {
                    sn_pin(value);
                }
            }
        }
        for error in &self.errors {
            unsafe {
                sn_pin(error.instance_path.value());
                sn_pin(error.schema_path.value());
                sn_pin(error.operand);
                sn_pin(error.instance);
                sn_pin(error.message);
            }
        }
        if let Some(evaluation) = &self.evaluation {
            evaluation.mark();
        }
    }
    fn add(
        &mut self,
        caches: &runtime::Caches,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        detail: usize,
    ) -> Result<(), Verdict> {
        self.add_with_frame(caches, keyword, source, instance, detail, None)
    }
    fn collect_header(
        &mut self,
        caches: &runtime::Caches,
        header: &container::Header,
        required: i32,
        value: Value,
        source: (i32, Value),
    ) -> Result<bool, Verdict> {
        let silent = self.silent;
        let applied = header.failures(caches, required, value, silent, |keyword, frame| {
            self.add_frame(caches, keyword, source, value, frame)
        })?;
        Ok(applied && silent && self.failed)
    }
    fn add_frame(
        &mut self,
        caches: &runtime::Caches,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        frame: Value,
    ) -> Result<(), Verdict> {
        self.add_with_frame(caches, keyword, source, instance, 0, Some(frame))
    }
    fn add_string(
        &mut self,
        caches: &runtime::Caches,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        frame: Value,
        rescued: bool,
    ) -> Result<(), Verdict> {
        if !self.silent && !rescued && keyword != "type" {
            if !caches.begin_string_error(frame, self.errors.len(), keyword) {
                self.reserve_error()?;
                return Err(Invalid);
            }
        } else {
            caches.end_string_error();
        }
        let result = self.add_with_frame(
            caches,
            keyword,
            source,
            instance,
            usize::from(rescued),
            Some(frame),
        );
        if result != Err(Unsupported) {
            caches.end_string_error();
        }
        result
    }
    fn reserve_error(&mut self) -> Result<(), Verdict> {
        if self.limits.enabled & 1 != 0 && self.attempts >= self.limits.max_errors {
            self.limit_hit = (1, self.attempts.saturating_add(1));
            return Err(Unsupported);
        }
        self.attempts = self.attempts.saturating_add(1);
        self.failed = true;
        Ok(())
    }
    fn add_with_frame(
        &mut self,
        caches: &runtime::Caches,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        detail: usize,
        frame: Option<Value>,
    ) -> Result<(), Verdict> {
        if self.silent {
            self.failed = true;
            return Ok(());
        }
        self.reserve_error()?;
        caches.frame_error(frame.is_some());
        let instance_path = self.instance_path.render(caches, None)?;
        let keyword_segment = (!matches!(
            keyword,
            "falseSchema" | "$ref" | "$recursiveRef" | "$dynamicRef"
        ))
        .then_some(keyword);
        let schema_path = self.schema_path.render(caches, keyword_segment)?;
        let message = if self.render_messages || caches.dynamic_calls() {
            if let Some(frame) = frame {
                caches.frame_message(
                    keyword,
                    source,
                    instance,
                    frame,
                    self.errors.len(),
                    detail != 0,
                )?
            } else {
                caches.error_message(keyword, source, instance, detail, self.errors.len())?
            }
        } else {
            unsafe { sn_nil() }
        };
        self.errors.push(Error {
            keyword,
            instance_path,
            schema_path,
            opcode: source.0,
            operand: source.1,
            instance,
            detail,
            message,
        });
        caches.frame_error(false);
        Ok(())
    }
    fn scoped<T>(
        &mut self,
        segment: &str,
        instance: Option<usize>,
        visit: impl FnOnce(&mut Self) -> Result<T, Verdict>,
    ) -> Result<T, Verdict> {
        if self.silent {
            return visit(self);
        }

        let schema_len = self.schema_path.checkpoint();
        let instance_len = self.instance_path.checkpoint();
        self.schema_path.push_str("/");
        self.schema_path.push_str(segment);
        if let Some(index) = instance {
            self.instance_path.index(index);
        }
        let result = visit(self);
        self.schema_path.truncate(schema_len);
        self.instance_path.truncate(instance_len);
        result
    }
    fn property<T>(
        &mut self,
        segment: &str,
        key: Value,
        schema_key: Option<Value>,
        visit: impl FnOnce(&mut Self) -> Result<T, Verdict>,
    ) -> Result<T, Verdict> {
        if self.silent {
            return visit(self);
        }

        let instance_len = self.instance_path.checkpoint();
        self.instance_path.name(key)?;
        let result = if let Some(key) = schema_key {
            self.schema_name(segment, key, visit)
        } else {
            self.scoped(segment, None, visit)
        };
        self.instance_path.truncate(instance_len);
        result
    }

    fn schema_name<T>(
        &mut self,
        segment: &str,
        key: Value,
        visit: impl FnOnce(&mut Self) -> Result<T, Verdict>,
    ) -> Result<T, Verdict> {
        if self.silent {
            return visit(self);
        }

        self.scoped(segment, None, |report| {
            report.schema_path.name(key)?;
            visit(report)
        })
    }
}

impl Execution<'_> {
    pub(super) fn should_continue_report(&self, depth: usize) -> bool {
        depth >= MAX_EVALUATION_DEPTH && self.caches.report_continuations_allowed()
    }
    fn collect_report(
        &self,
        report: &mut Report,
        root: usize,
        instance: Value,
    ) -> Result<Tracked, Verdict> {
        if report.annotations {
            self.collect::<true>(report, root, instance, 0, scope::Context::default())
        } else {
            self.collect::<false>(report, root, instance, 0, scope::Context::default())
        }
    }
    // Scalar trials export no annotations and need no evaluation memo entry.
    // Keep this before memo admission, especially for contains over scalar arrays.
    pub(super) fn trial_scalar(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        kind: i32,
    ) -> Option<Verdict> {
        match self.nodes[node].as_slice() {
            [Op::Number(required, rules)]
                if kind != TYPE_UNSUPPORTED
                    && !self.caches.dynamic_calls()
                    && !rules.runtime_operands() =>
            {
                // A typed-integer failure still performs numeric conversion in
                // a trial, so preserve nonfinite decimal exceptions as well.
                let status = if kind & TYPE_NUMBER != 0 {
                    let status = rules.eval(self.caches, value, &self.budget);
                    if status != Unsupported && *required != 0 && kind & required == 0 {
                        Invalid
                    } else {
                        status
                    }
                } else {
                    verdict(*required == 0)
                };
                Some(status)
            }
            [op @ (Op::Boolean(_) | Op::Type(..))] => Some(self.leaf(op, kind, value, depth)),
            [op @ Op::String(_, rules)]
                if kind != TYPE_UNSUPPORTED
                    && !self.caches.dynamic_calls()
                    && (kind != TYPE_STRING
                        || rules.length_only()
                        || rules.pattern_only().is_some()
                        || rules.format_only().is_some()
                        || rules.content_only().is_some()) =>
            {
                Some(self.leaf(op, kind, value, depth))
            }
            _ => None,
        }
    }
    pub(super) fn collect_trial(
        &self,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        kind_state: &InstanceKind,
    ) -> Tracked {
        if self.should_continue_report(depth) {
            let mut report = Report {
                silent: true,
                ..Report::default()
            };
            return self
                .caches
                .report_child(node, value, &mut report, true)
                .unwrap_or_else(Tracked::new);
        }
        let kind = kind_state.get();
        if depth > MAX_EVALUATION_DEPTH || self.unsupported_kind(node, kind) {
            return Tracked::new(Unsupported);
        }
        if let [op @ (Op::Const(_) | Op::Enum(_))] = self.nodes[node].as_slice() {
            return Tracked::new(self.leaf(op, kind, value, depth));
        }
        let mut report = Report {
            silent: true,
            ..Report::default()
        };
        self.collect_uncached::<true>(&mut report, node, value, depth, active, kind_state)
            .unwrap_or_else(Tracked::new)
    }
    fn collect<const ANNOTATIONS: bool>(
        &self,
        report: &mut Report,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
    ) -> Result<Tracked, Verdict> {
        if self.should_continue_report(depth) {
            return self.caches.report_child(node, value, report, ANNOTATIONS);
        }
        if depth > MAX_EVALUATION_DEPTH {
            return Err(Unsupported);
        }
        if !self.budget.checkpoint() {
            return Err(Unsupported);
        }
        let kind_state = InstanceKind::new(TYPE_UNCHECKED);
        let kind = self.diagnostic_kind(node, value, &kind_state);
        if self.unsupported_kind(node, kind) {
            return Err(Unsupported);
        }
        self.collect_kind::<ANNOTATIONS>(report, node, value, depth, active, &kind_state)
    }
    fn collect_kind<const ANNOTATIONS: bool>(
        &self,
        report: &mut Report,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        kind_state: &InstanceKind,
    ) -> Result<Tracked, Verdict> {
        if self.should_continue_report(depth) {
            return self.caches.report_child(node, value, report, ANNOTATIONS);
        }
        let kind = self.diagnostic_kind(node, value, kind_state);
        if self.unsupported_kind(node, kind) {
            return Err(Unsupported);
        }
        if report.silent {
            let result = self.eval_tracked_kind(node, value, depth, active, kind_state);
            if result.status == Unsupported {
                return Err(Unsupported);
            }
            report.failed |= result.status == Invalid;
            return Ok(result);
        }
        // A diagnostic success is established by complete traversal, never by
        // a short-circuit validity result. Keep exported annotations and the
        // collection policy separate; failures retain their path-specific errors.
        if !self.budget.checkpoint() {
            return Err(Unsupported);
        }
        let key = self
            .memo
            .key(self, node, value, depth, active, &self.budget);
        if self.budget.hit.get().0 != 0 {
            return Err(Unsupported);
        }
        if let Some(key) = key
            && let Some(result) = self.memo.diagnostic_success(key, ANNOTATIONS)
        {
            return Ok(result);
        }
        let result =
            self.collect_uncached::<ANNOTATIONS>(report, node, value, depth, active, kind_state);
        if let Some(key) = key
            && let Ok(coverage) = &result
            && coverage.status == Valid
        {
            self.memo
                .record_diagnostic_success(key, ANNOTATIONS, coverage);
        }
        result
    }
    fn collect_uncached<const ANNOTATIONS: bool>(
        &self,
        report: &mut Report,
        node: usize,
        value: Value,
        depth: usize,
        active: scope::Context<'_>,
        kind_state: &InstanceKind,
    ) -> Result<Tracked, Verdict> {
        let kind = kind_state.get();
        // Callback results currently carry validity only. Preserve the existing
        // diagnostic guard before any other assertion invokes Ruby methods.
        if kind == TYPE_UNSUPPORTED && self.callback_container_node(node) {
            return Err(Unsupported);
        }
        if depth > MAX_EVALUATION_DEPTH {
            return Err(Unsupported);
        }
        let frame = scope::ScopeFrame {
            resource: self.metadata[node].resource,
            parent: active.scope,
            primary_binding: active
                .scope
                .and_then(|f| f.primary_binding)
                .or(self.metadata[node].primary_binding),
        };
        let active = self.enter_scope(node, active, &frame);
        let _scope = self
            .caches
            .scope_guard(frame.resource, self.metadata[node].enters_scope);
        let tracked = ANNOTATIONS || self.tracks[node];
        let parent_failed = std::mem::replace(&mut report.failed, false);
        let mut prior = Tracked::new(Valid);
        for (op, &source) in self.nodes[node].iter().zip(&self.error_operands[node]) {
            if !self.budget.checkpoint() {
                return Err(Unsupported);
            }
            match op {
                Op::Unsupported => return Err(Unsupported),
                Op::UnresolvedRef(message) => {
                    let keyword = reference_keyword(source.0);
                    report.add(self.caches, keyword, (source.0, *message), value, 0)?;
                    prior = Tracked::new(Invalid);
                }
                Op::Boolean(false) => {
                    report.add(self.caches, "falseSchema", source, value, 0)?;
                    prior = Tracked::new(Invalid);
                }
                Op::Boolean(true) => {}
                Op::Type(mask, union) => match self.type_verdict(*mask, *union, kind, value) {
                    Unsupported => return Err(Unsupported),
                    Valid => {}
                    Invalid => {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                },
                Op::Const(..) | Op::Enum(..) => match self.leaf(op, kind, value, depth) {
                    Unsupported => return Err(Unsupported),
                    Invalid => report.add(
                        self.caches,
                        if matches!(op, Op::Const(_)) {
                            "const"
                        } else {
                            "enum"
                        },
                        source,
                        value,
                        0,
                    )?,
                    Valid => {}
                },
                Op::Number(required, rules) => {
                    if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                        rules.runtime_failures(self.caches, *required, value, |keyword| {
                            report.add(self.caches, keyword, source, value, 0)
                        })?;
                        continue;
                    }
                    if *required != 0 && kind & required == 0 {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                    if kind & TYPE_NUMBER != 0 {
                        rules.visit_failures(self.caches, value, &self.budget, |keyword| {
                            report.add(self.caches, keyword, source, value, 0)
                        })?;
                    }
                }
                Op::String(required, rules) => {
                    if kind == TYPE_UNSUPPORTED || self.caches.dynamic_calls() {
                        rules.runtime_failures(
                            self.caches,
                            *required,
                            value,
                            |keyword, frame, rescued| {
                                report.add_string(
                                    self.caches,
                                    keyword,
                                    source,
                                    value,
                                    frame,
                                    rescued,
                                )
                            },
                        )?;
                        continue;
                    }
                    if *required != 0 && kind != TYPE_STRING {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                    if kind == TYPE_STRING {
                        let len = if rules.min.is_some() || rules.max.is_some() {
                            unsafe { sn_len(value) }
                        } else {
                            0
                        };
                        if rules.max.is_some_and(|max| len > max) {
                            report.add(self.caches, "maxLength", source, value, len)?;
                        }
                        if rules.min.is_some_and(|min| len < min) {
                            report.add(self.caches, "minLength", source, value, len)?;
                        }
                        if let Some(pattern) = &rules.pattern {
                            match pattern.assertion(self.caches, value) {
                                Unsupported => return Err(Unsupported),
                                Invalid => {
                                    let invalid = pattern.invalid(self.caches, value);
                                    report.add(
                                        self.caches,
                                        "pattern",
                                        source,
                                        value,
                                        usize::from(invalid),
                                    )?;
                                    if invalid {
                                        continue;
                                    }
                                }
                                Valid => {}
                            }
                        }
                        if let Some(format) = &rules.format {
                            match format.eval(value) {
                                Unsupported => return Err(Unsupported),
                                Invalid => report.add(self.caches, "format", source, value, 0)?,
                                Valid => {}
                            }
                        }
                        if let Some(content) = &rules.content {
                            match content.eval(self.caches, value) {
                                Unsupported => return Err(Unsupported),
                                Invalid => report.add(
                                    self.caches,
                                    if content.base64 {
                                        "contentEncoding"
                                    } else {
                                        "contentMediaType"
                                    },
                                    source,
                                    value,
                                    0,
                                )?,
                                Valid => {}
                            }
                        }
                    }
                }
                Op::Array(required, rules) => {
                    if rules.header_only() && rules.header.runtime_required(self.caches, kind) {
                        if report.collect_header(
                            self.caches,
                            &rules.header,
                            *required,
                            value,
                            source,
                        )? {
                            break;
                        }
                        continue;
                    }
                    if kind == TYPE_ARRAY && !self.budget.checkpoint() {
                        return Err(Unsupported);
                    }
                    if *required != 0 && kind != TYPE_ARRAY {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                    if kind != TYPE_ARRAY {
                        continue;
                    }
                    if report.silent {
                        let status =
                            self.array_tracked(rules, value, depth + 1, active, &mut prior);
                        if status == Unsupported {
                            return Err(Unsupported);
                        }
                        report.failed |= status == Invalid;
                        if report.failed {
                            break;
                        }
                        continue;
                    }
                    let mut coverage = Tracked::new(Valid);
                    let len = unsafe { sn_len(value) };
                    if rules.max.is_some_and(|max| len > max) {
                        report.add(self.caches, "maxItems", source, value, len)?;
                    }
                    if rules.min.is_some_and(|min| len < min) {
                        report.add(self.caches, "minItems", source, value, len)?;
                    }
                    if rules.unique {
                        match self.unique_values(value, depth) {
                            Unsupported => return Err(Unsupported),
                            Invalid => report.add(self.caches, "uniqueItems", source, value, 0)?,
                            Valid => {}
                        }
                    }
                    for (index, &child) in rules.prefix.iter().take(len).enumerate() {
                        if !self.budget.checkpoint() {
                            return Err(Unsupported);
                        }
                        if tracked {
                            coverage.item(index);
                        }
                        report.scoped(&format!("prefixItems/{index}"), Some(index), |r| {
                            self.collect::<false>(
                                r,
                                child,
                                unsafe { sn_entry(value, index) },
                                depth + 1,
                                active,
                            )
                        })?;
                    }
                    if rules.list {
                        for (index, &child) in rules.items.iter().take(len).enumerate() {
                            if !self.budget.checkpoint() {
                                return Err(Unsupported);
                            }
                            if tracked {
                                coverage.item(index);
                            }
                            report.scoped(&format!("items/{index}"), Some(index), |r| {
                                self.collect::<false>(
                                    r,
                                    child,
                                    unsafe { sn_entry(value, index) },
                                    depth + 1,
                                    active,
                                )
                            })?;
                        }
                        if let Some(child) = rules.additional {
                            for index in rules.items.len()..len {
                                if !self.budget.checkpoint() {
                                    return Err(Unsupported);
                                }
                                if tracked {
                                    coverage.item(index);
                                }
                                report.scoped("additionalItems", Some(index), |r| {
                                    self.collect::<false>(
                                        r,
                                        child,
                                        unsafe { sn_entry(value, index) },
                                        depth + 1,
                                        active,
                                    )
                                })?;
                            }
                        }
                    } else if let Some(&child) = rules.items.first() {
                        let primitive = match self.nodes[child].as_slice() {
                            [Op::Type(mask, _)]
                                if mask & TYPE_NUMBER != 0 || mask & TYPE_INTEGER != 0 =>
                            {
                                Some(&[][..])
                            }
                            [Op::Number(_, rules)] => rules.fast_limits.as_deref(),
                            _ => None,
                        };
                        let primitive = primitive.filter(|_| !self.caches.dynamic_calls());
                        let values = if len == 0 {
                            &[]
                        } else {
                            unsafe { std::slice::from_raw_parts(sn_array_data(value), len) }
                        };
                        let pattern = match self.nodes[child].as_slice() {
                            [Op::String(required, string)] if depth < MAX_EVALUATION_DEPTH => {
                                string.pattern_only().map(|pattern| (*required, pattern))
                            }
                            _ => None,
                        };
                        let pattern = pattern
                            .filter(|_| !self.budget.timed() && !self.caches.dynamic_calls());
                        let number = match self.nodes[child].as_slice() {
                            [Op::Number(required, number)]
                                if depth < MAX_EVALUATION_DEPTH && !self.caches.dynamic_calls() =>
                            {
                                Some((*required, number))
                            }
                            _ => None,
                        };
                        let format = match self.nodes[child].as_slice() {
                            [Op::String(required, string)] if depth < MAX_EVALUATION_DEPTH => {
                                string.format_only().map(|format| (*required, format))
                            }
                            _ => None,
                        };
                        let format =
                            format.filter(|_| !self.budget.timed() && !self.caches.dynamic_calls());
                        let content = match self.nodes[child].as_slice() {
                            [Op::String(required, string)] if depth < MAX_EVALUATION_DEPTH => {
                                string.content_only().map(|content| (*required, content))
                            }
                            _ => None,
                        };
                        let content = content
                            .filter(|_| !self.budget.timed() && !self.caches.dynamic_calls());
                        if pattern.is_some() || format.is_some() || content.is_some() {
                            let start = rules.prefix.len().min(len);
                            if tracked {
                                for index in start..len {
                                    if !self.budget.checkpoint() {
                                        return Err(Unsupported);
                                    }
                                    coverage.item(index);
                                }
                            }
                            // The invalid callback is shared, but each scanner retains
                            // its statically selected parser and guarded byte views.
                            let invalid = |index, item| match report.scoped(
                                "items",
                                Some(start + index),
                                |r| self.collect::<false>(r, child, item, depth + 1, active),
                            ) {
                                Ok(_) => Valid,
                                Err(status) => status,
                            };
                            let status = match (pattern, format, content) {
                                (Some((required, pattern)), _, _) => pattern.visit_invalid_items(
                                    self.caches,
                                    required,
                                    &values[start..],
                                    invalid,
                                ),
                                (_, Some((required, format)), _) => {
                                    format.visit_invalid_items(required, &values[start..], invalid)
                                }
                                (_, _, Some((required, content))) => content.visit_invalid_items(
                                    self.caches,
                                    required,
                                    &values[start..],
                                    invalid,
                                ),
                                _ => unreachable!("a scalar item scanner was selected"),
                            };
                            if status != Valid {
                                return Err(status);
                            }
                        } else {
                            for (index, &item) in values.iter().enumerate().skip(rules.prefix.len())
                            {
                                if !self.budget.checkpoint() {
                                    return Err(Unsupported);
                                }
                                if tracked {
                                    coverage.item(index);
                                }
                                let needs = if let Some(limits) = primitive.filter(|_| {
                                    item & self.fixnum_flag != 0 && depth < MAX_EVALUATION_DEPTH
                                }) {
                                    let n = if limits.is_empty() {
                                        0
                                    } else {
                                        immediate_integer(item)
                                    };
                                    !limits.iter().all(|&(bit, limit)| match bit {
                                        MAXIMUM => n <= limit,
                                        MINIMUM => n >= limit,
                                        EXCLUSIVE_MAXIMUM => n < limit,
                                        _ => n > limit,
                                    })
                                } else if let Some((required, number)) = number {
                                    match number.eval_guarded(
                                        self.caches,
                                        required,
                                        item,
                                        &self.budget,
                                    ) {
                                        Valid => false,
                                        Invalid => true,
                                        Unsupported => {
                                            self.needs_diagnostics(child, item, depth + 1)?
                                        }
                                    }
                                } else {
                                    self.needs_diagnostics(child, item, depth + 1)?
                                };
                                if !needs {
                                    continue;
                                }
                                report.scoped("items", Some(index), |r| {
                                    self.collect::<false>(r, child, item, depth + 1, active)
                                })?;
                            }
                        }
                    }
                    if let Some(child) = rules.contains {
                        let values = if len == 0 {
                            &[]
                        } else {
                            unsafe { std::slice::from_raw_parts(sn_array_data(value), len) }
                        };
                        let matches = evaluation::scan_contains(
                            len,
                            evaluation::ContainsPolicy::AllMatches,
                            |index| self.trial_status(child, values[index], depth + 1, active),
                            |index| {
                                if tracked {
                                    coverage.item(index);
                                }
                            },
                        )?;
                        if bounds(matches, Some(rules.min_contains), rules.max_contains) == Invalid
                        {
                            report.add(self.caches, "contains", source, value, matches)?;
                        }
                    }
                    if let Some(child) = rules
                        .unevaluated
                        .filter(|_| prior.item_count() < len && coverage.item_count() < len)
                    {
                        for index in 0..len {
                            if !self.budget.checkpoint() {
                                return Err(Unsupported);
                            }
                            if prior.contains_item(index) || coverage.contains_item(index) {
                                continue;
                            }
                            report.scoped("unevaluatedItems", Some(index), |r| {
                                self.collect::<false>(
                                    r,
                                    child,
                                    unsafe { sn_entry(value, index) },
                                    depth + 1,
                                    active,
                                )
                            })?;
                            coverage.item(index);
                        }
                    }
                    if tracked {
                        prior.merge_diagnostics(coverage)?;
                    }
                }
                Op::Object(required, rules) => {
                    if rules.header_only() && rules.header.runtime_required(self.caches, kind) {
                        if report.collect_header(
                            self.caches,
                            &rules.header,
                            *required,
                            value,
                            source,
                        )? {
                            break;
                        }
                        continue;
                    }
                    if kind == TYPE_OBJECT && !self.budget.checkpoint() {
                        return Err(Unsupported);
                    }
                    if *required != 0 && kind != TYPE_OBJECT {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                    if kind != TYPE_OBJECT {
                        continue;
                    }
                    if report.silent {
                        let status =
                            self.object_tracked(rules, value, depth + 1, active, &mut prior);
                        if status == Unsupported {
                            return Err(Unsupported);
                        }
                        report.failed |= status == Invalid;
                        if report.failed {
                            break;
                        }
                        continue;
                    }
                    let mut coverage = Tracked::new(Valid);
                    let len = unsafe { sn_len(value) };
                    if rules.max.is_some_and(|max| len > max) {
                        report.add(self.caches, "maxProperties", source, value, len)?;
                    }
                    if rules.min.is_some_and(|min| len < min) {
                        report.add(self.caches, "minProperties", source, value, len)?;
                    }
                    for &name in &rules.required_order {
                        if !self.budget.checkpoint() {
                            return Err(Unsupported);
                        }
                        if name.missing(self.caches, value, self.undefined)? {
                            report.add(self.caches, "required", source, name.name, 0)?;
                        }
                    }
                    let mut context = ObjectDiagnostics {
                        engine: self,
                        report,
                        rules,
                        depth: depth + 1,
                        active,
                        names: false,
                        unevaluated: false,
                        coverage: &mut coverage,
                        prior: &prior,
                        tracked,
                    };
                    if (!rules.properties.is_empty()
                        || !rules.patterns.is_empty()
                        || rules.additional.is_some())
                        && unsafe {
                            sn_hash_each(
                                value,
                                (&mut context as *mut ObjectDiagnostics).cast(),
                                object_diagnostic,
                            )
                        } != VERDICT_VALID
                    {
                        return Err(Unsupported);
                    }
                    if rules.names.is_some() {
                        context.names = true;
                        if unsafe {
                            sn_hash_each(
                                value,
                                (&mut context as *mut ObjectDiagnostics).cast(),
                                object_diagnostic,
                            )
                        } != VERDICT_VALID
                        {
                            return Err(Unsupported);
                        }
                    }
                    for dependency in &rules.diagnostic_dependencies {
                        if !self.budget.checkpoint() {
                            return Err(Unsupported);
                        }
                        match dependency {
                            DiagnosticDependency::Required(name, names, keyword) => {
                                if missing(value, *name, self.undefined) {
                                    continue;
                                }
                                for &required in names {
                                    if !self.budget.checkpoint() {
                                        return Err(Unsupported);
                                    }
                                    if required.missing(self.caches, value, self.undefined)? {
                                        report.add(
                                            self.caches,
                                            keyword,
                                            (source.0, *name),
                                            required.name,
                                            0,
                                        )?;
                                    }
                                }
                            }
                            DiagnosticDependency::Schema(name, child, keyword) => {
                                if missing(value, *name, self.undefined) {
                                    continue;
                                }
                                if tracked {
                                    let result = report.schema_name(keyword, *name, |r| {
                                        self.collect::<true>(r, *child, value, depth + 1, active)
                                    })?;
                                    if result.status == Valid {
                                        coverage.merge(result);
                                    }
                                } else if self.needs_diagnostics(*child, value, depth + 1)? {
                                    report.schema_name(keyword, *name, |r| {
                                        self.collect::<false>(r, *child, value, depth + 1, active)
                                    })?;
                                }
                            }
                        }
                    }
                    if rules.unevaluated.is_some()
                        && prior.property_count() < len
                        && coverage.property_count() < len
                    {
                        let mut context = ObjectDiagnostics {
                            engine: self,
                            report,
                            rules,
                            depth: depth + 1,
                            active,
                            names: false,
                            unevaluated: true,
                            coverage: &mut coverage,
                            prior: &prior,
                            tracked,
                        };
                        if unsafe {
                            sn_hash_each(
                                value,
                                (&mut context as *mut ObjectDiagnostics).cast(),
                                object_diagnostic,
                            )
                        } != VERDICT_VALID
                        {
                            return Err(Unsupported);
                        }
                    }
                    if tracked {
                        prior.merge_diagnostics(coverage)?;
                    }
                }
                Op::All(nodes) => {
                    let mut coverage = Tracked::new(Valid);
                    for (index, &child) in nodes.iter().enumerate() {
                        if !self.budget.checkpoint() {
                            return Err(Unsupported);
                        }
                        let result = report.scoped(&format!("allOf/{index}"), None, |r| {
                            if tracked {
                                self.collect_kind::<true>(
                                    r,
                                    child,
                                    value,
                                    depth + 1,
                                    active,
                                    kind_state,
                                )
                            } else {
                                self.collect_kind::<false>(
                                    r,
                                    child,
                                    value,
                                    depth + 1,
                                    active,
                                    kind_state,
                                )
                            }
                        })?;
                        if tracked {
                            coverage.merge_diagnostics(result)?;
                        }
                    }
                    if tracked {
                        prior.merge_diagnostics(coverage)?;
                    }
                }
                Op::Any(nodes) | Op::One(nodes) => {
                    let branch_kind = if matches!(op, Op::Any(_)) {
                        evaluation::BranchKind::Any
                    } else {
                        evaluation::BranchKind::One
                    };
                    // Trials execute complete scalar checks without retaining
                    // errors or paths; ordinary validity may stop earlier.
                    let result = evaluation::scan_branches(
                        nodes,
                        evaluation::BranchPolicy::Complete,
                        self.caches.dynamic_calls(),
                        |child| self.eval_tracked_kind(child, value, depth + 1, active, kind_state),
                    )?;
                    if !branch_kind.accepts(result.matches) {
                        report.add(
                            self.caches,
                            branch_kind.keyword(),
                            source,
                            value,
                            result.matches,
                        )?;
                    } else if tracked {
                        prior.merge_diagnostics(result.coverage)?;
                    }
                }
                Op::Not(child) => {
                    match self
                        .eval_tracked_kind(*child, value, depth + 1, active, kind_state)
                        .status
                    {
                        Unsupported => return Err(Unsupported),
                        Valid => report.add(self.caches, "not", source, value, 0)?,
                        Invalid => {}
                    }
                }
                Op::Conditional(condition, yes, no) => {
                    let condition =
                        self.eval_tracked_kind(*condition, value, depth + 1, active, kind_state);
                    let mut coverage = Tracked::new(Valid);
                    let (child, segment) = match condition.status {
                        Unsupported => return Err(Unsupported),
                        Valid => {
                            if tracked {
                                coverage.merge(condition);
                            }
                            (yes, "then")
                        }
                        Invalid => (no, "else"),
                    };
                    if let Some(child) = child {
                        let result = report.scoped(segment, None, |r| {
                            if tracked {
                                self.collect_kind::<true>(
                                    r,
                                    *child,
                                    value,
                                    depth + 1,
                                    active,
                                    kind_state,
                                )
                            } else {
                                self.collect_kind::<false>(
                                    r,
                                    *child,
                                    value,
                                    depth + 1,
                                    active,
                                    kind_state,
                                )
                            }
                        })?;
                        if tracked {
                            coverage.merge_diagnostics(result)?;
                        }
                    }
                    if tracked {
                        prior.merge_diagnostics(coverage)?;
                    }
                }
                Op::Ref(target) => {
                    let target = self.resolve_reference(*target, value, active)?;
                    let program = self.programs[node];
                    if RefFrame::contains(active.active, node, value)
                        || self.caches.reference_active(program, value)
                    {
                        continue;
                    }
                    let frame = RefFrame {
                        source: node,
                        value,
                        parent: active.active,
                    };
                    let keyword = reference_keyword(source.0);
                    let reference = self.caches.reference_frame(program, value);
                    let _guard = self.caches.reference_guard(&reference);
                    let active = scope::Context {
                        active: Some(&frame),
                        ..active
                    };
                    let result = report.scoped(keyword, None, |r| {
                        if tracked {
                            self.collect_kind::<true>(
                                r,
                                target,
                                value,
                                depth + 1,
                                active,
                                kind_state,
                            )
                        } else {
                            self.collect_kind::<false>(
                                r,
                                target,
                                value,
                                depth + 1,
                                active,
                                kind_state,
                            )
                        }
                    })?;
                    if tracked {
                        prior.merge_diagnostics(result)?;
                    }
                }
            }
            if report.silent
                && report.failed
                && matches!(
                    op,
                    Op::All(_) | Op::Any(_) | Op::One(_) | Op::Not(_) | Op::Conditional(..)
                )
            {
                break;
            }
        }
        let failed = report.failed;
        report.failed |= parent_failed;
        // Diagnostic coverage keeps local attempted locations for subsequent
        // unevaluated checks; only a successful evaluation exports annotations.
        Ok(if failed { Tracked::new(Invalid) } else { prior })
    }

    fn needs_diagnostics(
        &self,
        mut node: usize,
        value: Value,
        mut depth: usize,
    ) -> Result<bool, Verdict> {
        loop {
            if !self.budget.checkpoint() {
                return Err(Unsupported);
            }
            if depth > MAX_EVALUATION_DEPTH {
                return Ok(true);
            }
            let [Op::Ref(reference)] = self.nodes[node].as_slice() else {
                break;
            };
            let Some(target) = reference.static_target() else {
                break;
            };
            node = target;
            depth += 1;
        }
        let status = match self.nodes[node].as_slice() {
            [Op::Number(required, rules)] if depth <= MAX_EVALUATION_DEPTH => {
                if self.caches.dynamic_calls()
                    || self.diagnostic_kind(node, value, &InstanceKind::new(TYPE_UNCHECKED))
                        == TYPE_UNSUPPORTED
                {
                    return Ok(true);
                }
                rules.eval_guarded(self.caches, *required, value, &self.budget)
            }
            [
                op @ (Op::Type(..) | Op::Boolean(_) | Op::String(..) | Op::Const(_) | Op::Enum(_)),
            ] if depth <= MAX_EVALUATION_DEPTH => {
                let kind = self.diagnostic_kind(node, value, &InstanceKind::new(TYPE_UNCHECKED));
                if (kind == TYPE_UNSUPPORTED
                    && matches!(
                        op,
                        Op::Type(..) | Op::String(..) | Op::Const(_) | Op::Enum(_)
                    ))
                    || (self.caches.dynamic_calls()
                        && matches!(op, Op::String(..) | Op::Const(_) | Op::Enum(_)))
                {
                    // Collection must execute a dynamic predicate once, rather
                    // than once here and again while recording its failure.
                    return Ok(true);
                }
                if self.unsupported_kind(node, kind) {
                    Unsupported
                } else {
                    self.leaf(op, kind, value, depth)
                }
            }
            // A successful validity/trial scan can omit diagnostic-only work
            // in descendants. Only complete collection proves their success.
            _ => return Ok(true),
        };
        match status {
            Valid => Ok(false),
            Invalid => Ok(true),
            Unsupported => Err(Unsupported),
        }
    }
}

struct ObjectDiagnostics<'a, 'b, 'c> {
    engine: &'a Execution<'a>,
    report: &'b mut Report,
    rules: &'a Object,
    depth: usize,
    active: scope::Context<'c>,
    names: bool,
    unevaluated: bool,
    coverage: &'b mut Tracked,
    prior: &'b Tracked,
    tracked: bool,
}
unsafe extern "C" fn object_diagnostic(context: *mut c_void, key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let c = unsafe { &mut *context.cast::<ObjectDiagnostics<'_, '_, '_>>() };
        if !c.engine.budget.checkpoint() {
            return Unsupported as i32;
        }
        let visit = |report: &mut Report, child: usize, item: Value, segment: &str, schema_key| {
            if c.engine.needs_diagnostics(child, item, c.depth)? {
                report.property(segment, key, schema_key, |r| {
                    c.engine.collect::<false>(r, child, item, c.depth, c.active)
                })?;
            }
            Ok::<_, Verdict>(())
        };
        let result = (|| {
            if unsafe { sn_kind(key) } != TYPE_STRING {
                return Err(Unsupported);
            }
            if c.names {
                return visit(c.report, c.rules.names.unwrap(), key, "propertyNames", None);
            }
            if c.unevaluated {
                if c.prior.contains_property(c.engine, key)
                    || c.coverage.contains_property(c.engine, key)
                {
                    return Ok(());
                }
                visit(
                    c.report,
                    c.rules.unevaluated.unwrap(),
                    value,
                    "unevaluatedProperties",
                    None,
                )?;
                c.coverage.property(c.engine, key);
                return Ok(());
            }
            let evaluated = c.rules.visit_value_rules(
                c.engine.caches,
                &c.engine.budget,
                true,
                key,
                None,
                |segment, name, child| visit(c.report, child, value, segment, name),
            )?;
            if c.tracked && evaluated {
                c.coverage.property(c.engine, key);
            }
            Ok(())
        })();
        match result {
            Ok(()) => VERDICT_VALID,
            Err(_) => Unsupported as i32,
        }
    }))
    .unwrap_or(Unsupported as i32)
}

#[repr(C)]
pub struct Record {
    keyword: *const u8,
    keyword_len: usize,
    instance_path: *const u8,
    instance_len: usize,
    schema_path: *const u8,
    schema_len: usize,
    instance_pointer: Value,
    schema_pointer: Value,
    opcode: i32,
    operand: Value,
    instance: Value,
    detail: usize,
    message: Value,
}
fn report_outcome(result: std::thread::Result<Result<*mut Report, i32>>) -> (*mut Report, i32) {
    match result {
        Ok(Ok(report)) => (report, VERDICT_VALID),
        Ok(Err(code)) => (std::ptr::null_mut(), code),
        Err(_) => (std::ptr::null_mut(), STATUS_PANIC),
    }
}
/// # Safety
/// Engine/status must be live under the GVL; root must be in bounds and
/// instance live. Caches must be null or live, validator-owned and not in use.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_diagnose(
    engine: *const Engine,
    caches: *const runtime::Caches,
    root: usize,
    instance: Value,
    status: *mut i32,
) -> *mut Report {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let engine = unsafe { &*engine };
        let local = runtime::Caches::default();
        let caches = unsafe { caches.as_ref() }.unwrap_or(&local);
        let execution = Execution {
            engine,
            caches,
            memo: memo::Memo::default(),
            budget: budget::Budget::default(),
        };
        caches.allow_report_continuations(engine.report_continuations_safe(root));
        let inherited = caches.initial_report();
        let resumed = inherited.is_some();
        let mut report = inherited.unwrap_or_else(|| Report {
            render_messages: engine.runtime_messages,
            ..Report::default()
        });
        let result = execution
            .collect_report(&mut report, root, instance)
            .map_err(|verdict| execution.budget.status(verdict))?;
        report.evaluation = if resumed { Some(result) } else { None };
        Ok::<_, i32>(Box::into_raw(Box::new(report)))
    }));
    let (report, code) = report_outcome(result);
    unsafe { *status = code };
    report
}
/// # Safety
/// Same requirements as sn_diagnose; all limit/output pointers must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_diagnose_with_limits(
    engine: *const Engine,
    caches: *const runtime::Caches,
    root: usize,
    instance: Value,
    status: *mut i32,
    limits: *const budget::Limits,
    outcome: *mut budget::Outcome,
) -> *mut Report {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let local = runtime::Caches::default();
        let caches = unsafe { caches.as_ref() }.unwrap_or(&local);
        let limits = unsafe { *limits };
        let execution = Execution {
            engine: unsafe { &*engine },
            caches,
            memo: memo::Memo::default(),
            budget: caches.budget(limits),
        };
        caches.allow_report_continuations(execution.report_continuations_safe(root));
        let inherited = caches.initial_report();
        let resumed = inherited.is_some();
        let mut report = inherited.unwrap_or_else(|| Report {
            limits,
            render_messages: execution.runtime_messages,
            ..Report::default()
        });
        let result = if execution.budget.check_deadline() {
            execution.collect_report(&mut report, root, instance)
        } else {
            Err(Unsupported)
        };
        let result = if execution.budget.check_deadline() {
            result
        } else {
            Err(Unsupported)
        };
        let hit = if report.limit_hit.0 != 0 {
            report.limit_hit
        } else {
            execution.budget.hit.get()
        };
        unsafe {
            ((*outcome).kind, (*outcome).attempted) = hit;
        }
        result
            .map(|evaluation| {
                report.evaluation = if resumed { Some(evaluation) } else { None };
                Box::into_raw(Box::new(report))
            })
            .map_err(|verdict| execution.budget.status(verdict))
    }));
    let (report, code) = report_outcome(result);
    unsafe { *status = code };
    report
}
/// # Safety
/// Report must be live under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_len(report: *const Report) -> usize {
    unsafe { &*report }.errors.len()
}
/// # Safety
/// Report must be live under the GVL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_size(report: *const Report) -> usize {
    std::mem::size_of::<Report>() + unsafe { &*report }.memory_usage()
}
/// # Safety
/// Report must be live, index in bounds, and record a writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_record(
    report: *const Report,
    index: usize,
    record: *mut Record,
) {
    let e = &unsafe { &*report }.errors[index];
    unsafe {
        *record = Record {
            keyword: e.keyword.as_ptr(),
            keyword_len: e.keyword.len(),
            instance_path: e.instance_path.bytes().as_ptr(),
            instance_len: e.instance_path.bytes().len(),
            schema_path: e.schema_path.bytes().as_ptr(),
            schema_len: e.schema_path.bytes().len(),
            instance_pointer: e.instance_path.value(),
            schema_pointer: e.schema_path.value(),
            opcode: e.opcode,
            operand: e.operand,
            instance: e.instance,
            detail: e.detail,
            message: e.message,
        }
    };
}
/// # Safety
/// Report must be live; call only from its synchronous Ruby GC mark callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_mark(report: *const Report) {
    unsafe { &*report }.mark();
}
/// # Safety
/// Report must be owned, returned by sn_diagnose, and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_free(report: *mut Report) {
    drop(unsafe { Box::from_raw(report) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_seeds_and_results_own_error_paths_limits_and_locations() {
        let mut report = Report {
            attempts: 2,
            failed: true,
            ..Report::default()
        };
        report.instance_path.text.push_str("/item");
        report.schema_path.text.push_str("/allOf/1");
        report.limits = budget::Limits {
            enabled: 1,
            max_errors: 3,
            ..budget::Limits::default()
        };
        report.errors.push(Error {
            keyword: "type",
            instance_path: pointer::Rendered::Native("/item".into()),
            schema_path: pointer::Rendered::Native("/allOf/0/type".into()),
            opcode: OP_TYPE_INTEGER,
            operand: 0,
            instance: 0,
            detail: 0,
            message: 0,
        });
        let mut locations = Tracked::new(Valid);
        locations.item(4);
        locations.item(65);
        report.evaluation = Some(locations);
        let mut seed = report.continuation(true);
        assert!(seed.annotations);
        assert!(seed.evaluation.is_none());
        assert_eq!(seed.attempts, 2);
        assert!(seed.failed);
        assert_eq!(seed.limits.max_errors, 3);
        seed.instance_path.text.push_str("/child");
        seed.errors.clear();
        assert_eq!(report.instance_path.text, "/item");
        assert_eq!(report.errors.len(), 1);
        assert!(report.memory_usage() > 0);
        let mut adopted = Report::default();
        let mut completed = report.clone();
        completed.annotations = true;
        let mut result = adopted.adopt(completed);
        result.item(8);
        assert_eq!(result.item_count(), 3);
        assert_eq!(report.evaluation.as_ref().unwrap().item_count(), 2);
        assert!(report.evaluation.as_ref().unwrap().contains_item(65));
        assert!(adopted.evaluation.is_none());
        assert!(!adopted.annotations);
        assert_eq!(adopted.attempts, 2);
    }
}
