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
        if !budget.checkpoint() {
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
            if !budget.checkpoint() {
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

enum Work {
    Visit(Value),
    Finish(Value),
}

pub(super) enum Safety {
    Ordinary,
    Cyclic,
    Unsupported,
}

// A failed fingerprint may indicate either an optimization bound or Ruby
// behavior that native equality must not skip. Classify every reachable value
// before substituting direct comparisons or a stack error for hashing. Continue
// after detecting a cycle: any special value still requires Ruby's behavior.
// Unlike the memoization hint above, this rare path needs no depth/visit cap.
pub(super) fn ordinary_graph(value: Value, budget: &budget::Budget) -> Safety {
    let mut work = vec![Work::Visit(value)];
    let mut states = HashMap::new();
    let mut cyclic = false;
    while let Some(task) = work.pop() {
        if !budget.checkpoint() {
            return Safety::Unsupported;
        }
        match task {
            Work::Finish(value) => {
                states.insert(value, true);
            }
            Work::Visit(value) => {
                if let Some(&done) = states.get(&value) {
                    if !done {
                        cyclic = true;
                    }
                    continue;
                }
                match unsafe { sn_kind(value) } {
                    TYPE_UNSUPPORTED => return Safety::Unsupported,
                    TYPE_ARRAY => {
                        states.insert(value, false);
                        work.push(Work::Finish(value));
                        for i in (0..unsafe { sn_len(value) }).rev() {
                            work.push(Work::Visit(unsafe { sn_entry(value, i) }));
                        }
                    }
                    TYPE_OBJECT => {
                        states.insert(value, false);
                        work.push(Work::Finish(value));
                        let mut context = OrdinaryWalk {
                            work: &mut work,
                            budget,
                        };
                        if unsafe {
                            sn_hash_each(
                                value,
                                (&mut context as *mut OrdinaryWalk<'_>).cast(),
                                ordinary_entry,
                            )
                        } != VERDICT_VALID
                        {
                            return Safety::Unsupported;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    if cyclic {
        Safety::Cyclic
    } else {
        Safety::Ordinary
    }
}

struct OrdinaryWalk<'a> {
    work: &'a mut Vec<Work>,
    budget: &'a budget::Budget,
}
unsafe extern "C" fn ordinary_entry(context: *mut c_void, _: Value, value: Value) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let context = unsafe { &mut *context.cast::<OrdinaryWalk<'_>>() };
        if !context.budget.checkpoint() {
            return VERDICT_UNSUPPORTED;
        }
        context.work.push(Work::Visit(value));
        VERDICT_VALID
    }))
    .unwrap_or(VERDICT_UNSUPPORTED)
}
