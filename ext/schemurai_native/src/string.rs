//! Staged Ruby string semantics for values without safe native storage views.
use super::*;

impl StringRules {
    pub(super) fn runtime_valid(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
    ) -> Verdict {
        caches
            .string(self.source, value, required | self.runtime_flags)
            .map_or(Unsupported, |frame| frame.step(0))
    }
    pub(super) fn runtime_failures(
        &self,
        caches: &runtime::Caches,
        required: i32,
        value: Value,
        mut visit: impl FnMut(&'static str, Value, bool) -> Result<(), Verdict>,
    ) -> Result<(), Verdict> {
        let frame = caches.string(self.source, value, required | self.runtime_flags)?;
        if !frame.predicate(1)? {
            if required != 0 {
                visit("type", frame.ordinal(), false)?;
            }
            return Ok(());
        }
        if !frame.predicate(2)? {
            visit("pattern", frame.ordinal(), true)?;
            return Ok(());
        }
        for (step, active, keyword) in [
            (3, self.runtime_flags & 4 != 0, "maxLength"),
            (4, self.runtime_flags & 8 != 0, "minLength"),
            (5, self.pattern.is_some(), "pattern"),
            (6, self.runtime_format, "format"),
            (
                7,
                self.content.is_some(),
                if self.content.as_ref().is_some_and(|c| c.base64) {
                    "contentEncoding"
                } else {
                    "contentMediaType"
                },
            ),
        ] {
            if active && !frame.predicate(step)? {
                let invalid_pattern = frame.predicate(8 + step)?;
                match visit(
                    if invalid_pattern { "pattern" } else { keyword },
                    frame.ordinal(),
                    invalid_pattern,
                ) {
                    Err(Invalid) if !invalid_pattern => {
                        visit("pattern", frame.ordinal(), true)?;
                        return Ok(());
                    }
                    result => result?,
                }
                if invalid_pattern {
                    break;
                }
            }
        }
        Ok(())
    }
}
