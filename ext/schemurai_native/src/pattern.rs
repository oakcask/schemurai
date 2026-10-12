//! Crate-backed matching over borrowed Ruby string bytes.
//! The compatibility adapter translates VM shorthands and absolute anchors;
//! regex-syntax parses syntax, and regex-automata performs every search.
use super::*;
use regex_automata::{
    Anchored, Input, MatchKind,
    dfa::{Automaton, OverlappingState, StartKind, dense},
    meta::{Cache, Regex},
    nfa::thompson,
};
use regex_syntax::ast::{Ast, RepetitionKind, RepetitionRange};

// Each validator owns its search caches. Compiled regex/DFA data stays shared.
#[derive(Default)]
pub struct Caches(std::cell::RefCell<Vec<Option<Box<Cache>>>>);
impl Caches {
    fn is_match(&self, index: usize, regex: &Regex, bytes: &[u8]) -> bool {
        // Each runner is tied to one engine, whose regex indices are fixed at
        // compilation. Allocate only the caches this validator actually uses.
        let mut caches = self.0.borrow_mut();
        if caches.len() <= index {
            caches.resize_with(index + 1, || None);
        }
        let cache = caches[index].get_or_insert_with(|| Box::new(regex.create_cache()));
        regex
            .search_half_with(cache, &Input::new(bytes).earliest(true))
            .is_some()
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn sn_caches_new() -> *mut Caches {
    Box::into_raw(Box::new(Caches::default()))
}
/// # Safety
/// Caches must be owned, returned by sn_caches_new, and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_free(caches: *mut Caches) {
    drop(unsafe { Box::from_raw(caches) });
}
/// # Safety
/// Caches must be live; call under the GVL or while all Ractors are stopped.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_caches_size(caches: *const Caches) -> usize {
    // GC may inspect a stopped runner while its search has borrowed a cache.
    let Ok(caches) = (unsafe { &*caches }).0.try_borrow() else {
        return std::mem::size_of::<Caches>();
    };
    std::mem::size_of::<Caches>()
        + caches.capacity() * std::mem::size_of::<Option<Box<Cache>>>()
        + caches
            .iter()
            .flatten()
            .map(|cache| std::mem::size_of::<Cache>() + cache.memory_usage())
            .sum::<usize>()
}

#[derive(Debug)]
pub(super) enum Pattern {
    Unsupported,
    Dfa(Box<dense::DFA<Vec<u32>>>),
    Compiled { regex: Regex, index: usize },
}

// Preserve every overlapping match while scanning a key with one automaton.
// Keep individual matchers for unsupported compilation/search configurations.
#[derive(Debug)]
pub(super) struct PatternGroup {
    dfa: dense::DFA<Vec<u32>>,
    all: u64,
}
impl PatternGroup {
    pub(super) fn compile(names: &[Value], patterns: &[(Pattern, usize)]) -> Option<Self> {
        if !(2..=64).contains(&patterns.len())
            || !patterns
                .iter()
                .all(|(pattern, _)| matches!(pattern, Pattern::Dfa(_)))
        {
            return None;
        }
        // Existing DFA compilation already proved syntax, encoding, compatibility
        // and full start anchoring. Reuse exactly the same translation.
        let sources: Option<Vec<_>> = names
            .iter()
            .map(|&name| {
                std::str::from_utf8(unsafe { string_bytes(name) })
                    .ok()
                    .and_then(translate)
            })
            .collect();
        let dfa = dense::Builder::new()
            .configure(
                dense::Config::new()
                    .match_kind(MatchKind::All)
                    .start_kind(StartKind::Anchored)
                    .dfa_size_limit(Some(1 << 20))
                    .determinize_size_limit(Some(1 << 22)),
            )
            .thompson(thompson::Config::new().nfa_size_limit(Some(1 << 20)))
            .build_many(&sources?)
            .ok()?;
        let all = u64::MAX >> (64 - patterns.len());
        Some(Self { dfa, all })
    }
    pub(super) fn matches(&self, value: Value) -> Option<u64> {
        let mut data = std::ptr::null();
        let mut len = 0;
        let encoding = unsafe { sn_pattern_view(value, &mut data, &mut len) };
        if encoding == ENCODING_OTHER {
            return None;
        }
        let bytes = unsafe { byte_view(data, len) };
        if !valid_encoding(bytes, encoding) {
            return None;
        }
        let input = Input::new(bytes).anchored(Anchored::Yes);
        let mut state = OverlappingState::start();
        let mut matches = 0;
        loop {
            self.dfa
                .try_search_overlapping_fwd(&input, &mut state)
                .ok()?;
            let Some(found) = state.get_match() else {
                break;
            };
            matches |= 1_u64 << found.pattern().as_usize();
            if matches == self.all {
                break;
            }
        }
        Some(matches)
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.dfa.memory_usage()
    }
}

impl Pattern {
    // Select the crate matcher once for a homogeneous array. The borrowed
    // Ruby slices are used synchronously; classification and encoding are
    // still checked on every element, including non-string instances.
    pub(super) fn eval_items(&self, caches: &Caches, required: i32, values: &[Value]) -> Verdict {
        self.visit_invalid_items(caches, required, values, |_, _| Invalid)
    }

    pub(super) fn visit_invalid_items(
        &self,
        caches: &Caches,
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
            Self::Compiled { regex, index } => scan_items(required, values, invalid, |bytes| {
                verdict(caches.is_match(*index, regex, bytes))
            }),
            Self::Unsupported => scan_items(required, values, invalid, |_| Unsupported),
        }
    }

    pub(super) fn memory_usage(&self) -> usize {
        match self {
            Self::Dfa(dfa) => std::mem::size_of_val(&**dfa) + dfa.memory_usage(),
            Self::Compiled { regex, .. } => regex.memory_usage(),
            Self::Unsupported => 0,
        }
    }

    pub(super) fn compile(value: Value, cache_count: &mut usize) -> Self {
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
            .map(|regex| {
                let index = *cache_count;
                *cache_count += 1;
                Self::Compiled { regex, index }
            })
            .unwrap_or(Self::Unsupported)
    }

    pub(super) fn eval(&self, caches: &Caches, value: Value) -> Verdict {
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
        self.eval_bytes(caches, bytes, encoding)
    }

    pub(super) fn eval_bytes(&self, caches: &Caches, bytes: &[u8], encoding: i32) -> Verdict {
        if encoding == ENCODING_OTHER || matches!(self, Self::Unsupported) {
            return Unsupported;
        }
        if !valid_encoding(bytes, encoding) {
            return Unsupported;
        }
        let matched = match self {
            Self::Dfa(dfa) => match dfa
                .try_search_fwd(&Input::new(bytes).anchored(Anchored::Yes).earliest(true))
            {
                Ok(matched) => matched.is_some(),
                Err(_) => return Unsupported,
            },
            Self::Compiled { regex, index } => caches.is_match(*index, regex, bytes),
            Self::Unsupported => return Unsupported,
        };
        if matched { Valid } else { Invalid }
    }
}

// Keep short checks in std and skip scanning when Ruby already proved ASCII.
// The compatibility SIMD API retains early rejection of malformed UTF-8.
fn valid_encoding(bytes: &[u8], encoding: i32) -> bool {
    if encoding == ENCODING_SEVEN_BIT {
        true
    } else if encoding == ENCODING_ASCII {
        bytes.is_ascii()
    } else if bytes.len() < 64 {
        std::str::from_utf8(bytes).is_ok()
    } else {
        simdutf8::compat::from_utf8(bytes).is_ok()
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
        if !valid_encoding(bytes, encoding) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoding_validation_matches_std_across_simd_blocks_and_tails() {
        let original = "日𐀀é".repeat(32).into_bytes();
        for length in [63, 64, 65, 127, 128, 129, original.len()] {
            for at in 0..length {
                for byte in 0..=255 {
                    let mut input = original[..length].to_vec();
                    input[at] = byte;
                    assert_eq!(
                        valid_encoding(&input, ENCODING_UTF8),
                        std::str::from_utf8(&input).is_ok(),
                        "length {length}, position {at}, byte {byte}"
                    );
                    assert_eq!(valid_encoding(&input, ENCODING_ASCII), input.is_ascii());
                }
            }
        }
        assert!(valid_encoding(&original, ENCODING_UTF8));
        assert!(valid_encoding(b"already classified", ENCODING_SEVEN_BIT));
    }

    #[test]
    fn reports_memory_when_a_search_cache_is_borrowed() {
        let caches = Caches::default();
        let regex = Regex::new("value[0-9]+").unwrap();
        assert!(caches.is_match(0, &regex, b"value1"));
        assert!(unsafe { sn_caches_size(&caches) } > std::mem::size_of::<Caches>());
        let _search = caches.0.borrow_mut();
        assert_eq!(
            unsafe { sn_caches_size(&caches) },
            std::mem::size_of::<Caches>()
        );
    }
}
