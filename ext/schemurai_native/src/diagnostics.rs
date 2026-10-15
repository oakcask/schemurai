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
#[derive(Default)]
pub struct Report {
    errors: Vec<Error>,
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
    fn add(
        &mut self,
        caches: &runtime::Caches,
        keyword: &'static str,
        source: (i32, Value),
        instance: Value,
        detail: usize,
    ) -> Result<(), Verdict> {
        if self.silent {
            self.failed = true;
            return Ok(());
        }
        if self.limits.enabled & 1 != 0 && self.errors.len() >= self.limits.max_errors {
            self.limit_hit = (1, self.errors.len().saturating_add(1));
            return Err(Unsupported);
        }
        self.failed = true;
        let instance_path = self.instance_path.render(caches, None)?;
        let keyword_segment = (!matches!(
            keyword,
            "falseSchema" | "$ref" | "$recursiveRef" | "$dynamicRef"
        ))
        .then_some(keyword);
        let schema_path = self.schema_path.render(caches, keyword_segment)?;
        let message = if self.render_messages {
            caches.error_message(keyword, source, instance, detail)?
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
            [Op::Number(required, rules)] if !rules.runtime_operands() => {
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
            [op @ (Op::Boolean(_) | Op::Type(_))] => Some(self.leaf(op, kind, value, depth)),
            [op @ Op::String(_, rules)]
                if kind != TYPE_STRING
                    || rules.length_only()
                    || rules.pattern_only().is_some()
                    || rules.format_only().is_some()
                    || rules.content_only().is_some() =>
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
        let kind = kind_state.get();
        if depth > MAX_EVALUATION_DEPTH || kind == TYPE_UNSUPPORTED {
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
        if depth > MAX_EVALUATION_DEPTH {
            return Err(Unsupported);
        }
        if !self.budget.checkpoint() {
            return Err(Unsupported);
        }
        let kind_state = InstanceKind::new(TYPE_UNCHECKED);
        let kind = self.diagnostic_kind(node, value, &kind_state);
        if kind == TYPE_UNSUPPORTED {
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
        let kind = self.diagnostic_kind(node, value, kind_state);
        if kind == TYPE_UNSUPPORTED {
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
                Op::Type(mask) => {
                    if kind & mask == 0 {
                        report.add(self.caches, "type", source, value, 0)?;
                    }
                }
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
                        match unique(value, depth, self.fixnum_flag, &self.budget) {
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
                            [Op::Type(mask)]
                                if mask & TYPE_NUMBER != 0 || mask & TYPE_INTEGER != 0 =>
                            {
                                Some(&[][..])
                            }
                            [Op::Number(_, rules)] => rules.fast_limits.as_deref(),
                            _ => None,
                        };
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
                        let pattern = pattern.filter(|_| !self.budget.timed());
                        let number = match self.nodes[child].as_slice() {
                            [Op::Number(required, number)] if depth < MAX_EVALUATION_DEPTH => {
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
                        let format = format.filter(|_| !self.budget.timed());
                        let content = match self.nodes[child].as_slice() {
                            [Op::String(required, string)] if depth < MAX_EVALUATION_DEPTH => {
                                string.content_only().map(|content| (*required, content))
                            }
                            _ => None,
                        };
                        let content = content.filter(|_| !self.budget.timed());
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
                                        Unsupported => return Err(Unsupported),
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
                    if RefFrame::contains(active.active, node, value) {
                        continue;
                    }
                    let frame = RefFrame {
                        source: node,
                        value,
                        parent: active.active,
                    };
                    let keyword = reference_keyword(source.0);
                    let target = self.reference_target(*target, active);
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
                rules.eval_guarded(self.caches, *required, value, &self.budget)
            }
            [op @ (Op::Type(_) | Op::Boolean(_) | Op::String(..) | Op::Const(_) | Op::Enum(_))]
                if depth <= MAX_EVALUATION_DEPTH =>
            {
                let kind = self.diagnostic_kind(node, value, &InstanceKind::new(TYPE_UNCHECKED));
                if kind == TYPE_UNSUPPORTED {
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
        let mut report = Report {
            render_messages: engine.runtime_messages,
            ..Report::default()
        };
        execution
            .collect::<false>(&mut report, root, instance, 0, scope::Context::default())
            .map_err(|verdict| execution.budget.status(verdict))?;
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
        let mut report = Report {
            limits,
            render_messages: execution.runtime_messages,
            ..Report::default()
        };
        let result = if execution.budget.check_deadline() {
            execution.collect::<false>(&mut report, root, instance, 0, scope::Context::default())
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
            .map(|_| Box::into_raw(Box::new(report)))
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
    let r = unsafe { &*report };
    std::mem::size_of::<Report>()
        + r.errors.capacity() * std::mem::size_of::<Error>()
        + r.instance_path.memory_usage()
        + r.schema_path.memory_usage()
        + r.errors
            .iter()
            .map(|e| e.instance_path.memory_usage() + e.schema_path.memory_usage())
            .sum::<usize>()
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
    for error in &unsafe { &*report }.errors {
        unsafe {
            sn_pin(error.instance_path.value());
            sn_pin(error.schema_path.value());
            sn_pin(error.operand);
            sn_pin(error.instance);
            sn_pin(error.message);
        }
    }
}
/// # Safety
/// Report must be owned, returned by sn_diagnose, and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_free(report: *mut Report) {
    drop(unsafe { Box::from_raw(report) });
}
