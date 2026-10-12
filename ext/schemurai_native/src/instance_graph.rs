//! Bounded, invocation-local proof that container values cannot revisit an
//! ancestor instance. Read under the GVL, without Ruby allocations/callbacks.
use super::*;

const MAX_VISITS: usize = 4096;

pub(super) struct Graph {
    proven: structural::Cache<Value, bool>,
}
impl Default for Graph {
    fn default() -> Self {
        Self {
            proven: structural::Cache::new(0),
        }
    }
}
impl Graph {
    pub(super) fn acyclic(&mut self, value: Value, budget: &budget::Budget) -> bool {
        self.visit(value, 0, &mut HashMap::new(), budget)
    }
    fn visit(
        &mut self,
        value: Value,
        depth: usize,
        states: &mut HashMap<Value, bool>,
        budget: &budget::Budget,
    ) -> bool {
        if !budget.charge(1) || !budget.scalar(value) {
            return false;
        }
        let kind = unsafe { sn_shallow_kind(value) };
        if kind != TYPE_ARRAY && kind != TYPE_OBJECT {
            return kind != TYPE_UNSUPPORTED;
        }
        if self.proven.get(value) == Some(true) {
            return true;
        }
        if let Some(&done) = states.get(&value) {
            return done;
        }
        if depth > MAX_EVALUATION_DEPTH || states.len() == MAX_VISITS {
            return false;
        }
        states.insert(value, false);
        let complete = if kind == TYPE_ARRAY {
            let len = unsafe { sn_len(value) };
            if !budget.charge(len) {
                return false;
            }
            (0..len).all(|i| self.visit(unsafe { sn_entry(value, i) }, depth + 1, states, budget))
        } else {
            let mut context = Walk {
                graph: self,
                states,
                depth: depth + 1,
                budget,
            };
            (unsafe { sn_hash_each(value, (&mut context as *mut Walk<'_>).cast(), entry) })
                == VERDICT_VALID
        };
        if complete {
            states.insert(value, true);
            self.proven.record(value, true);
        }
        complete
    }
}
struct Walk<'a> {
    graph: &'a mut Graph,
    states: &'a mut HashMap<Value, bool>,
    depth: usize,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn entry(context: *mut c_void, _key: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let context = unsafe { &mut *context.cast::<Walk<'_>>() };
        verdict(
            context
                .graph
                .visit(value, context.depth, context.states, context.budget),
        ) as i32
    }))
    .unwrap_or(VERDICT_INVALID)
}
