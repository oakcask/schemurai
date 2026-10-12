//! One comparison/hash owns its cache. Ruby values cannot mutate or move
//! during these GVL-held traversals, which never call back into Ruby.
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;

const MAX_ENTRIES: usize = 4096;

pub(super) struct Cache<K, T> {
    start_depth: usize,
    results: HashMap<K, T>,
    order: VecDeque<K>,
}
impl<K, T> Cache<K, T> {
    // A batch can share containers immediately below distinct element roots.
    // It owns one bounded cache until the entire GVL-held scan completes.
    pub(super) fn batch(depth: usize) -> Self {
        Self {
            start_depth: depth,
            results: HashMap::new(),
            order: VecDeque::new(),
        }
    }
    pub(super) fn new(depth: usize) -> Self {
        Self {
            start_depth: depth.saturating_add(4),
            results: HashMap::new(),
            order: VecDeque::new(),
        }
    }
    // Shallow ordinary records/trees avoid table bookkeeping. At most four
    // levels are expanded before reuse begins, independently of graph depth.
    pub(super) fn eligible(&self, depth: usize) -> bool {
        depth >= self.start_depth
    }
}
impl<K: Copy + Eq + Hash, T: Copy> Cache<K, T> {
    pub(super) fn get(&self, key: K) -> Option<T> {
        self.results.get(&key).copied()
    }
    pub(super) fn record(&mut self, key: K, result: T) {
        if self.results.contains_key(&key) {
            return;
        }
        if self.results.len() == MAX_ENTRIES {
            self.results.remove(&self.order.pop_front().unwrap());
        }
        self.results.insert(key, result);
        self.order.push_back(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separates_depth_and_admits_later_shared_values() {
        let mut cache = Cache::new(0);
        for value in 0..MAX_ENTRIES * 3 {
            cache.record((value, 0), Some(value));
            cache.record((value, 0), None);
        }
        assert_eq!(cache.results.len(), MAX_ENTRIES);
        assert_eq!(cache.order.len(), MAX_ENTRIES);
        assert_eq!(cache.get((0, 0)), None);
        assert_eq!(
            cache.get((MAX_ENTRIES * 3 - 1, 0)),
            Some(Some(MAX_ENTRIES * 3 - 1))
        );
        assert_eq!(cache.get((MAX_ENTRIES * 3 - 1, 1)), None);
    }
}
