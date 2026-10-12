//! Large enums retain a compiled fingerprint index over pinned schema values.
//! Hashes only select candidates; JSON equality still decides every match.
use super::*;

const LINEAR_LIMIT: usize = 16;
const MAX_INDEX_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug)]
pub(super) struct Enumeration {
    values: Vec<Value>,
    index: Option<Index>,
    kinds: i32,
}

impl Enumeration {
    pub(super) fn compile(values: Vec<Value>, fixnum_flag: Value) -> Self {
        let mut fingerprints = structural::Cache::batch(0);
        let budget = budget::Budget::default();
        let index = (values.len() > LINEAR_LIMIT)
            .then(|| {
                Index::compile(&values, |value| {
                    fingerprint_cached(value, 0, fixnum_flag, false, &mut fingerprints, &budget)
                })
            })
            .flatten();
        let kinds = if index.is_some() {
            values
                .iter()
                .fold(0, |mask, &value| mask | unsafe { sn_shallow_kind(value) })
        } else {
            0
        };
        Self {
            values,
            index,
            kinds,
        }
    }

    pub(super) fn eval(
        &self,
        value: Value,
        kind: i32,
        depth: usize,
        fixnum_flag: Value,
        budget: &budget::Budget,
    ) -> Verdict {
        if let Some(index) = &self.index {
            // All indexed schema values are supported. A disjoint root type
            // cannot match, even if the input contains unsupported descendants.
            // Avoid fingerprinting large containers for scalar-only enums.
            if kind & self.kinds == 0 {
                return Invalid;
            }
            // Keep the best-case linear lookup cheap. This also avoids hashing
            // a whole input container when the first candidate already matches.
            let first = equal_budgeted(self.values[0], value, depth, budget);
            if first != Invalid {
                return first;
            }
            if let Some(hash) = fingerprint_budgeted(value, depth, fixnum_flag, false, budget) {
                return self.compare(
                    index.candidates(hash).filter(|&index| index != 0),
                    value,
                    depth,
                    budget,
                );
            }
            return self.compare(1..self.values.len(), value, depth, budget);
        }
        // An unavailable fingerprint is not an unsupported comparison. Linear
        // equality can reject a different shape before reaching that value.
        self.compare(0..self.values.len(), value, depth, budget)
    }

    fn compare(
        &self,
        candidates: impl Iterator<Item = usize>,
        value: Value,
        depth: usize,
        budget: &budget::Budget,
    ) -> Verdict {
        for index in candidates {
            let result = equal_budgeted(self.values[index], value, depth, budget);
            if result != Invalid {
                return result;
            }
        }
        Invalid
    }

    pub(super) fn memory_usage(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.values.capacity() * std::mem::size_of::<Value>()
            + self.index.as_ref().map_or(0, |index| {
                index.entries.capacity() * std::mem::size_of::<(u64, usize)>()
            })
    }
}

#[derive(Debug)]
struct Index {
    entries: Vec<(u64, usize)>,
}

impl Index {
    fn compile(values: &[Value], mut hash: impl FnMut(Value) -> Option<u64>) -> Option<Self> {
        if values
            .len()
            .checked_mul(std::mem::size_of::<(u64, usize)>())?
            > MAX_INDEX_BYTES
        {
            return None;
        }
        let mut entries = Vec::new();
        entries.try_reserve_exact(values.len()).ok()?;
        for (index, &value) in values.iter().enumerate() {
            entries.push((hash(value)?, index));
        }
        // A sorted flat index bounds memory and compilation to O(E log E),
        // even for colliding fingerprints. Equal hashes retain schema order.
        entries.sort_unstable();
        Some(Self { entries })
    }

    fn candidates(&self, hash: u64) -> impl Iterator<Item = usize> + '_ {
        let start = self
            .entries
            .partition_point(|&(candidate, _)| candidate < hash);
        self.entries[start..]
            .iter()
            .take_while(move |&&(candidate, _)| candidate == hash)
            .map(|&(_, index)| index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_all_collisions_in_schema_order() {
        let index = Index::compile(&[3, 1, 3, 2, 3], |value| Some(value as u64)).unwrap();
        assert_eq!(index.candidates(3).collect::<Vec<_>>(), [0, 2, 4]);
        assert_eq!(index.candidates(1).collect::<Vec<_>>(), [1]);
        assert_eq!(index.candidates(0).count(), 0);
        assert_eq!(index.candidates(4).count(), 0);
    }

    #[test]
    fn unavailable_fingerprint_discards_the_index() {
        assert!(Index::compile(&[1, 2, 3], |value| (value != 2).then_some(value as u64)).is_none());
    }
}
