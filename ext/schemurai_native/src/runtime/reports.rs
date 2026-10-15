//! Owned diagnostic seeds and results. No native frame is retained across Ruby.
use super::*;
use crate::diagnostics::Report;
use std::cell::RefCell;

#[derive(Default)]
pub(super) struct Reports {
    initial: RefCell<Option<Report>>,
    pending: RefCell<Option<(Value, Report)>>,
    completed: RefCell<HashMap<Value, Report>>,
}
impl Reports {
    pub(super) fn clear(&self) {
        self.initial.borrow_mut().take();
        self.pending.borrow_mut().take();
        *self.completed.borrow_mut() = HashMap::new();
    }
    pub(super) fn reset(&self) {
        self.pending.borrow_mut().take();
    }
    pub(super) fn initial(&self) -> Option<Report> {
        self.initial.borrow().clone()
    }
    pub(super) fn request(&self, key: Value, report: Report) {
        *self.pending.borrow_mut() = Some((key, report));
    }
    pub(super) fn result(&self, key: Value) -> Option<Report> {
        self.completed.borrow().get(&key).cloned()
    }
    pub(super) fn memory_usage(&self) -> usize {
        self.initial
            .try_borrow()
            .map_or(0, |r| r.as_ref().map_or(0, Report::memory_usage))
            + self
                .pending
                .try_borrow()
                .map_or(0, |r| r.as_ref().map_or(0, |(_, r)| r.memory_usage()))
            + self.completed.try_borrow().map_or(0, |r| {
                r.capacity() * std::mem::size_of::<(Value, Report)>()
                    + r.values().map(Report::memory_usage).sum::<usize>()
            })
    }
    pub(super) fn mark(&self) {
        // C additionally roots every completed report and inherited seed.
        // Pending snapshots use input/schema handles and runtime observations
        // already owned by the runner while a stopped pass borrows this state.
        if let Ok(initial) = self.initial.try_borrow()
            && let Some(report) = &*initial
        {
            report.mark();
        }
        if let Ok(pending) = self.pending.try_borrow()
            && let Some((_, report)) = &*pending
        {
            report.mark();
        }
        if let Ok(completed) = self.completed.try_borrow() {
            for report in completed.values() {
                report.mark();
            }
        }
    }
}
/// # Safety
/// Caches must be idle and own a pending native report request. The returned
/// report is owned by C TypedData and freed exactly once with sn_report_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_seed(caches: *const Caches) -> *mut Report {
    Box::into_raw(Box::new(
        unsafe { &*caches }
            .reports
            .pending
            .borrow()
            .as_ref()
            .expect("pending native report")
            .1
            .clone(),
    ))
}
/// # Safety
/// Caches must be idle and report live and C-rooted through the invocation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_inherit(caches: *const Caches, report: *const Report) {
    *unsafe { &*caches }.reports.initial.borrow_mut() = Some(unsafe { &*report }.clone());
}
/// # Safety
/// Caches must be idle with a pending report request; report must be live,
/// complete, and retained by the runner's completed-report roots before calling.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_accept(caches: *const Caches, report: *const Report) {
    let reports = &unsafe { &*caches }.reports;
    let key = reports
        .pending
        .borrow()
        .as_ref()
        .expect("pending native report")
        .0;
    reports
        .completed
        .borrow_mut()
        .insert(key, unsafe { &*report }.clone());
}
