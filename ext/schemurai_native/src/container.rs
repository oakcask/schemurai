//! Ruby container headers without child-schema traversal or native storage loans.
use super::*;

#[derive(Debug)]
pub(super) struct Header {
    source: Value,
    checks: u8,
    object: bool,
    native_bounds: bool,
}
impl Header {
    pub(super) fn runtime_required(&self, caches: &runtime::Caches, kind: i32) -> bool {
        !self.native_bounds || kind == TYPE_UNSUPPORTED || caches.dynamic_calls()
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
        if self.checks & 8 != 0 {
            frame.predicate(5)?;
        }
        if self.checks & 16 != 0 {
            frame.predicate(6)?;
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
        Ok(Header {
            source,
            native_bounds,
            checks: unsafe { sn_truthy(maximum) } as u8
                | ((unsafe { sn_truthy(minimum) } as u8) << 1)
                | tail
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
    pub(super) fn header_only(&self) -> bool {
        !self.inspect_required
            && self.properties.is_empty()
            && self.patterns.is_empty()
            && self.additional.is_none()
            && self.names.is_none()
            && self.dependent_required.is_empty()
            && self.dependent_schemas.is_empty()
            && self.unevaluated.is_none()
    }
}
