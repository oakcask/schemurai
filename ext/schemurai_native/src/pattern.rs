//! Crate-backed matching over borrowed Ruby string bytes.
//! The compatibility adapter translates VM shorthands and absolute anchors;
//! regex-syntax parses syntax, and regex-automata performs every search.
use super::*;
use regex_automata::{
    Anchored, Input, MatchKind,
    dfa::{Automaton, StartKind, dense},
    meta::Regex,
    nfa::thompson,
};
use regex_syntax::ast::{Ast, RepetitionKind, RepetitionRange};

#[derive(Debug)]
pub(super) enum Pattern {
    Unsupported,
    Dfa(Box<dense::DFA<Vec<u32>>>),
    Compiled(Regex),
}

impl Pattern {
    // Select the crate matcher once for a homogeneous array. The borrowed
    // Ruby slices are used synchronously; classification and encoding are
    // still checked on every element, including non-string instances.
    pub(super) fn eval_items(&self, required: i32, values: &[Value]) -> Verdict {
        self.visit_invalid_items(required, values, |_, _| Invalid)
    }

    pub(super) fn visit_invalid_items(
        &self,
        required: i32,
        values: &[Value],
        invalid: impl FnMut(usize, Value) -> Verdict,
    ) -> Verdict {
        match self {
            Self::Dfa(dfa) => scan_items(required, values, invalid, |bytes| {
                match dfa.try_search_fwd(&Input::new(bytes).anchored(Anchored::Yes).earliest(true))
                {
                    Ok(matched) => verdict(matched.is_some()),
                    Err(_) => Unsupported,
                }
            }),
            Self::Compiled(regex) => scan_items(required, values, invalid, |bytes| {
                verdict(regex.is_match(bytes))
            }),
            Self::Unsupported => scan_items(required, values, invalid, |_| Unsupported),
        }
    }

    pub(super) fn memory_usage(&self) -> usize {
        match self {
            Self::Dfa(dfa) => std::mem::size_of_val(&**dfa) + dfa.memory_usage(),
            Self::Compiled(regex) => regex.memory_usage(),
            Self::Unsupported => 0,
        }
    }

    pub(super) fn compile(value: Value) -> Self {
        if unsafe { sn_kind(value) } != TYPE_STRING {
            return Self::Unsupported;
        }
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_string_view(value, &mut data, &mut len) };
        if encoding == ENCODING_OTHER {
            return Self::Unsupported;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        if encoding == ENCODING_ASCII && !bytes.is_ascii() {
            return Self::Unsupported;
        }
        let Some(source) = std::str::from_utf8(bytes).ok().and_then(translate) else {
            return Self::Unsupported;
        };
        let Ok(ast) = regex_syntax::ast::parse::Parser::new().parse(&source) else {
            return Self::Unsupported;
        };
        if !compatible(&ast) {
            return Self::Unsupported;
        }
        // Use a single immutable DFA for fully start-anchored validity. The
        // meta engine retains its literal prefilters for unanchored searches.
        // Bound both the DFA table and auxiliary determinization memory.
        if let Ok(hir) = regex_syntax::hir::translate::Translator::new().translate(&source, &ast)
            && hir
                .properties()
                .look_set_prefix()
                .contains(regex_syntax::hir::Look::Start)
            && let Ok(dfa) = dense::Builder::new()
                .configure(
                    dense::Config::new()
                        .match_kind(MatchKind::LeftmostFirst)
                        .start_kind(StartKind::Anchored)
                        .dfa_size_limit(Some(1 << 16))
                        .determinize_size_limit(Some(1 << 18)),
                )
                .thompson(thompson::Config::new().nfa_size_limit(Some(1 << 20)))
                .build(&source)
        {
            return Self::Dfa(Box::new(dfa));
        }
        Regex::builder()
            .configure(
                Regex::config()
                    .nfa_size_limit(Some(1 << 20))
                    .hybrid_cache_capacity(1 << 20),
            )
            .build(&source)
            .map(Self::Compiled)
            .unwrap_or(Self::Unsupported)
    }

    pub(super) fn eval(&self, value: Value) -> Verdict {
        if matches!(self, Self::Unsupported) {
            return Unsupported;
        }
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_pattern_view(value, &mut data, &mut len) };
        if encoding == ENCODING_OTHER {
            return Unsupported;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        self.eval_bytes(bytes, encoding)
    }

    pub(super) fn eval_bytes(&self, bytes: &[u8], encoding: i32) -> Verdict {
        if encoding == ENCODING_OTHER || matches!(self, Self::Unsupported) {
            return Unsupported;
        }
        if encoding != ENCODING_SEVEN_BIT
            && ((encoding == ENCODING_ASCII && !bytes.is_ascii())
                || std::str::from_utf8(bytes).is_err())
        {
            return Unsupported;
        }
        let matched = match self {
            Self::Dfa(dfa) => match dfa
                .try_search_fwd(&Input::new(bytes).anchored(Anchored::Yes).earliest(true))
            {
                Ok(matched) => matched.is_some(),
                Err(_) => return Unsupported,
            },
            Self::Compiled(regex) => regex.is_match(bytes),
            Self::Unsupported => return Unsupported,
        };
        if matched { Valid } else { Invalid }
    }
}

fn scan_items(
    required: i32,
    values: &[Value],
    mut invalid: impl FnMut(usize, Value) -> Verdict,
    mut matches: impl FnMut(&[u8]) -> Verdict,
) -> Verdict {
    for (index, &value) in values.iter().enumerate() {
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_pattern_item_view(value, &mut data, &mut len) };
        if encoding == -TYPE_UNSUPPORTED {
            return Unsupported;
        }
        if encoding < 0 {
            if required != 0 {
                let result = invalid(index, value);
                if result != Valid {
                    return result;
                }
            }
            continue;
        }
        if encoding == ENCODING_OTHER {
            return Unsupported;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        if encoding != ENCODING_SEVEN_BIT
            && ((encoding == ENCODING_ASCII && !bytes.is_ascii())
                || std::str::from_utf8(bytes).is_err())
        {
            return Unsupported;
        }
        let result = matches(bytes);
        match result {
            Unsupported => return Unsupported,
            Invalid => {
                let result = invalid(index, value);
                if result != Valid {
                    return result;
                }
            }
            Valid => {}
        }
    }
    Valid
}

// This is a VM compatibility translation, not a regex parser. Unsupported
// escapes, class set operations and special groups retain Ruby's behavior.
fn translate(source: &str) -> Option<String> {
    let mut output = String::with_capacity(source.len());
    let mut characters = source.chars().peekable();
    let mut in_class = false;
    while let Some(character) = characters.next() {
        match character {
            '\\' => {
                let escaped = characters.next()?;
                let class = match escaped {
                    'd' => Some("0-9"),
                    'D' => Some("^0-9"),
                    'w' => Some("A-Za-z0-9_"),
                    'W' => Some("^A-Za-z0-9_"),
                    's' => Some(
                        r"\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}",
                    ),
                    'S' => Some(
                        r"^\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}",
                    ),
                    _ => None,
                };
                if let Some(class) = class {
                    if !in_class {
                        output.push('[');
                    }
                    output.push_str(class);
                    if !in_class {
                        output.push(']');
                    }
                } else if ".^$?+*(){}[]|\\-afnrtv".contains(escaped)
                    || (!in_class && matches!(escaped, 'A' | 'z'))
                {
                    output.push('\\');
                    output.push(escaped);
                } else {
                    return None;
                }
            }
            '[' => {
                if in_class {
                    return None;
                }
                in_class = true;
                output.push(character);
            }
            ']' => {
                in_class = false;
                output.push(character);
            }
            '&' if in_class => return None,
            '-' | '~' if in_class && characters.peek() == Some(&character) => return None,
            '(' if !in_class && characters.peek() == Some(&'?') => {
                characters.next();
                if characters.next() != Some(':') {
                    return None;
                }
                output.push_str("(?:");
            }
            '^' if !in_class => output.push_str(r"\A"),
            '$' if !in_class => output.push_str(r"\z"),
            _ => output.push(character),
        }
    }
    Some(output)
}

fn compatible(ast: &Ast) -> bool {
    match ast {
        Ast::Repetition(repetition) => {
            // Ruby treats adjacent repetition operators as possessive or
            // rejects them, while regex-syntax can parse nested repetitions.
            if matches!(*repetition.ast, Ast::Repetition(_)) {
                return false;
            }
            let bounded = match repetition.op.kind {
                RepetitionKind::Range(
                    RepetitionRange::Exactly(n) | RepetitionRange::AtLeast(n),
                ) => n <= 4096,
                RepetitionKind::Range(RepetitionRange::Bounded(_, max)) => max <= 4096,
                _ => true,
            };
            bounded && compatible(&repetition.ast)
        }
        Ast::Group(group) => compatible(&group.ast),
        Ast::Alternation(alternation) => alternation.asts.iter().all(compatible),
        Ast::Concat(concat) => concat.asts.iter().all(compatible),
        Ast::Flags(_) | Ast::ClassUnicode(_) | Ast::ClassPerl(_) => false,
        _ => true,
    }
}
