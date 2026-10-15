//! Native UTF-8 pointer text with deferred names that need Ruby string semantics.
use super::*;

#[derive(Clone, Default, Eq, Hash, PartialEq)]
pub(super) struct Path {
    pub(super) text: String,
    pub(super) names: Vec<(usize, Value)>,
}
impl Path {
    pub(super) fn checkpoint(&self) -> (usize, usize) {
        (self.text.len(), self.names.len())
    }
    pub(super) fn truncate(&mut self, checkpoint: (usize, usize)) {
        self.text.truncate(checkpoint.0);
        self.names.truncate(checkpoint.1);
    }
    pub(super) fn push_str(&mut self, text: &str) {
        self.text.push_str(text);
    }
    pub(super) fn index(&mut self, index: usize) {
        use std::fmt::Write;
        write!(self.text, "/{index}").unwrap();
    }
    pub(super) fn name(&mut self, value: Value) -> Result<(), Verdict> {
        if unsafe { sn_kind(value) } != TYPE_STRING {
            return Err(Unsupported);
        }
        self.text.push('/');
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_string_view(value, &mut data, &mut len) };
        let bytes = unsafe { byte_view(data, len) };
        if matches!(encoding, ENCODING_UTF8 | ENCODING_ASCII)
            && (encoding != ENCODING_ASCII || bytes.is_ascii())
            && let Ok(name) = std::str::from_utf8(bytes)
        {
            for character in name.chars() {
                match character {
                    '~' => self.text.push_str("~0"),
                    '/' => self.text.push_str("~1"),
                    _ => self.text.push(character),
                }
            }
        } else {
            self.names.push((self.text.len(), value));
        }
        Ok(())
    }
    pub(super) fn render(
        &self,
        caches: &runtime::Caches,
        keyword: Option<&str>,
    ) -> Result<Rendered, Verdict> {
        if self.names.is_empty() {
            let text = keyword.map_or_else(
                || self.text.clone(),
                |keyword| format!("{}/{keyword}", self.text),
            );
            Ok(Rendered::Native(text))
        } else if let Some(keyword) = keyword {
            let mut path = self.clone();
            path.push_str("/");
            path.push_str(keyword);
            caches.pointer(&path).map(Rendered::Ruby)
        } else {
            caches.pointer(self).map(Rendered::Ruby)
        }
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.text.capacity() + self.names.capacity() * std::mem::size_of::<(usize, Value)>()
    }
}
#[derive(Clone)]
pub(super) enum Rendered {
    Native(String),
    Ruby(Value),
}
impl Rendered {
    pub(super) fn bytes(&self) -> &[u8] {
        match self {
            Self::Native(text) => text.as_bytes(),
            Self::Ruby(_) => &[],
        }
    }
    pub(super) fn value(&self) -> Value {
        match self {
            Self::Native(_) => unsafe { sn_nil() },
            Self::Ruby(value) => *value,
        }
    }
    pub(super) fn memory_usage(&self) -> usize {
        match self {
            Self::Native(text) => text.capacity(),
            Self::Ruby(_) => 0,
        }
    }
}
