//! Owned diagnostic seeds and results. No native frame is retained across Ruby.
use super::*;
use crate::diagnostics::Report;
use std::cell::RefCell;

#[derive(Default)]
pub(super) struct Reports {
    initial: RefCell<Option<Report>>,
    callback: RefCell<Option<Report>>,
    pending: RefCell<Option<(Value, Report)>>,
    completed: RefCell<HashMap<Value, Report>>,
    live: RefCell<Option<Report>>,
    boundary: RefCell<Option<Report>>,
    runtime_key: std::cell::Cell<Option<scopes::Key>>,
    effects: RefCell<HashMap<scopes::Key, Report>>,
    replay: RefCell<Vec<Report>>,
}
impl Reports {
    pub(super) fn clear(&self) {
        self.boundary.borrow_mut().take();
        self.live.borrow_mut().take();
        self.runtime_key.set(None);
        self.effects.borrow_mut().clear();
        self.replay.borrow_mut().clear();
        self.initial.borrow_mut().take();
        self.callback.borrow_mut().take();
        self.pending.borrow_mut().take();
        *self.completed.borrow_mut() = HashMap::new();
    }
    pub(super) fn capture(&self, report: &Report) {
        *self.boundary.borrow_mut() = Some(report.clone());
        if self.live.borrow().is_none() {
            *self.live.borrow_mut() = Some(report.clone());
        }
    }
    pub(super) fn request_runtime(&self, key: scopes::Key) {
        self.runtime_key.set(Some(key));
    }
    pub(super) fn apply_runtime(&self, key: scopes::Key) {
        if let Some(effect) = self.effects.borrow().get(&key) {
            self.replay.borrow_mut().push(effect.clone());
        }
    }
    pub(super) fn apply(&self, report: &mut Report) {
        for effect in self.replay.borrow_mut().drain(..) {
            report.apply_effect(effect);
        }
    }
    pub(super) fn reset(&self) {
        *self.callback.borrow_mut() = self.initial.borrow().clone();
        self.boundary.borrow_mut().take();
        self.live.borrow_mut().take();
        self.runtime_key.set(None);
        self.replay.borrow_mut().clear();
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
        [&self.live, &self.boundary, &self.initial, &self.callback]
            .iter()
            .map(|cell| {
                cell.try_borrow()
                    .map_or(0, |r| r.as_ref().map_or(0, Report::memory_usage))
            })
            .sum::<usize>()
            + self.effects.try_borrow().map_or(0, |effects| {
                effects.values().map(Report::memory_usage).sum::<usize>()
            })
            + self.replay.try_borrow().map_or(0, |effects| {
                effects.iter().map(Report::memory_usage).sum::<usize>()
            })
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
        if let Ok(boundary) = self.boundary.try_borrow()
            && let Some(report) = &*boundary
        {
            report.mark();
        }
        if let Ok(callback) = self.callback.try_borrow()
            && let Some(report) = &*callback
        {
            report.mark();
        }
        if let Ok(live) = self.live.try_borrow()
            && let Some(report) = &*live
        {
            report.mark();
        }
        if let Ok(effects) = self.effects.try_borrow() {
            for report in effects.values() {
                report.mark();
            }
        }
        if let Ok(replay) = self.replay.try_borrow() {
            for report in replay.iter() {
                report.mark();
            }
        }
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
    let reports = &unsafe { &*caches }.reports;
    *reports.initial.borrow_mut() = Some(unsafe { &*report }.clone());
    *reports.callback.borrow_mut() = Some(unsafe { &*report }.clone());
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

/// # Safety
/// Caches must be idle. A non-null result is an owned report rooted/freed by C.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_live(caches: *const Caches) -> *mut Report {
    unsafe { &*caches }
        .reports
        .live
        .borrow()
        .as_ref()
        .map_or(std::ptr::null_mut(), |report| {
            Box::into_raw(Box::new(report.clone()))
        })
}
/// # Safety
/// Caches and completed report must be idle, live and C-rooted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_effect(caches: *const Caches, completed: *const Report) {
    let reports = &unsafe { &*caches }.reports;
    if let Some(key) = reports.runtime_key.get()
        && let Some(before) = &*reports.live.borrow()
        && let Some(effect) = unsafe { &*completed }.effect_since(before)
    {
        reports.effects.borrow_mut().insert(key, effect);
    }
}

impl Caches {
    pub(crate) fn callback_tracked(&self, node: usize, value: Value) -> Option<Verdict> {
        let mut report = self.reports.callback.borrow().clone()?;
        self.reports.apply(&mut report);
        let result = self
            .report_child(node, value, &mut report, true)
            .map_or_else(|verdict| verdict, |evaluation| evaluation.status);
        self.reports.apply(&mut report);
        if result == Unsupported {
            self.reports.capture(&report);
        }
        *self.reports.callback.borrow_mut() = Some(report);
        Some(result)
    }
    pub(crate) fn finish_callback_report(&self, verdict: Verdict) {
        if let Some(report) = &mut *self.reports.callback.borrow_mut() {
            self.reports.apply(report);
            if verdict == Unsupported {
                self.reports.capture(report);
            }
        }
    }
}
/// # Safety
/// Caches must be idle after a successful seeded validity call. C owns the result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_callback_report_result(
    caches: *const Caches,
    valid: i32,
) -> *mut Report {
    let mut report = unsafe { &*caches }
        .reports
        .callback
        .borrow()
        .clone()
        .expect("callback report");
    report.complete_callback(valid != 0);
    Box::into_raw(Box::new(report))
}

/// # Safety
/// Caches are idle while C unwinds an interrupted runner. C owns a non-null result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_interrupted(caches: *const Caches) -> *mut Report {
    let reports = &unsafe { &*caches }.reports;
    let mut report = reports
        .boundary
        .borrow()
        .clone()
        .or_else(|| reports.callback.borrow().clone());
    if let Some(report) = &mut report {
        if let Some(key) = reports.runtime_key.get()
            && let Some(live) = &*reports.live.borrow()
            && report.same_collection_policy(live)
            && let Some(effect) = reports.effects.borrow().get(&key)
        {
            report.apply_effect(effect.clone());
        }
        report.complete_callback(false);
    }
    report.map_or(std::ptr::null_mut(), |report| {
        Box::into_raw(Box::new(report))
    })
}
