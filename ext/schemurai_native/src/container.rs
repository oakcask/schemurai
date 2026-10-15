//! Ruby container headers without child-schema traversal or native storage loans.
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
    pub(super) fn header_only(&self) -> bool {
        self.prefix.is_empty()
            && self.items.is_empty()
            && (!self.list || self.additional.is_none())
            && self.contains.is_none()
            && self.unevaluated.is_none()
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
