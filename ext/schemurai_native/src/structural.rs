//! One comparison/hash owns its cache. Ruby values cannot mutate or move
//! during these GVL-held traversals, which never call back into Ruby.
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;

const MAX_ENTRIES: usize = 4096;

pub(super) struct Cache<K, T> {
    start_depth: usize,
    shallow_width: usize,
    results: HashMap<K, T>,
    order: VecDeque<K>,
}
impl<K, T> Cache<K, T> {
    // A batch can share wide containers below distinct element roots. Keep
    // small shallow trees cheap; four expanded levels are still a constant
    // bound before depth-based reuse handles thin shared graphs.
    pub(super) fn batch(depth: usize) -> Self {
        let mut cache = Self::new(depth);
        cache.shallow_width = 16;
        cache
    }
    pub(super) fn new(depth: usize) -> Self {
        Self {
            start_depth: depth.saturating_add(4),
            shallow_width: usize::MAX,
            results: HashMap::new(),
            order: VecDeque::new(),
        }
    }
    // Shallow ordinary records/trees avoid table bookkeeping. At most four
    // levels are expanded before reuse begins, independently of graph depth.
    pub(super) fn eligible(&self, depth: usize) -> bool {
        depth >= self.start_depth
    }
    pub(super) fn eligible_container(&self, depth: usize, width: usize) -> bool {
        self.eligible(depth) || width >= self.shallow_width
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
    fn batches_admit_wide_containers_without_charging_small_shallow_trees() {
        let cache = Cache::<usize, usize>::batch(7);
        assert!(!cache.eligible_container(7, 2));
        assert!(!cache.eligible_container(10, 15));
        assert!(cache.eligible_container(8, 16));
        assert!(cache.eligible_container(11, 0));
        assert!(!Cache::<usize, usize>::new(7).eligible_container(8, 1024));
    }

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
