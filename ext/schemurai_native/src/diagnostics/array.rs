//! Array report collection through C-owned handles, outside native schema frames.
use super::*;

/// # Safety
/// Report is live, immutable and rooted by C; the returned clone is owned by C.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_clone(report: *const Report) -> *mut Report {
    Box::into_raw(Box::new(unsafe { &*report }.clone()))
}
/// # Safety
/// Report is the live callback collection, immutable and rooted by C.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_callback_seed(report: *const Report) -> *mut Report {
    Box::into_raw(Box::new(unsafe { &*report }.continuation(true)))
}
/// # Safety
/// Report is live and C-rooted. Keyword is a valid library-owned UTF-8 segment.
/// The returned seed is owned by C and freed with sn_report_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_child(
    report: *const Report,
    index: usize,
    keyword: *const u8,
    len: usize,
    child: usize,
    trial: i32,
) -> *mut Report {
    let mut seed = if trial != 0 {
        Report {
            silent: true,
            annotations: true,
            ..Report::default()
        }
    } else {
        unsafe { &*report }.continuation(false)
    };
    if trial == 0 {
        seed.instance_path.index(index);
        seed.schema_path.push_str("/");
        seed.schema_path.push_str(
            std::str::from_utf8(unsafe { byte_view(keyword, len) }).expect("array keyword"),
        );
        if child != usize::MAX {
            seed.schema_path.index(child);
        }
    }
    Box::into_raw(Box::new(seed))
}
/// # Safety
/// Report/engine are live and rooted, node contains the current Array instruction,
/// keyword is one of the library's array diagnostic IDs, and frame is C-rooted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_error(
    report: *const Report,
    engine: *const Engine,
    node: usize,
    instance: Value,
    keyword: i32,
    frame: Value,
) -> *mut Report {
    let engine = unsafe { &*engine };
    let source = engine.nodes[node]
        .iter()
        .zip(&engine.error_operands[node])
        .find_map(|(op, &source)| matches!(op, Op::Array(..)).then_some(source))
        .expect("array source");
    let keyword = match keyword {
        0 => "type",
        1 => "maxItems",
        2 => "minItems",
        3 => "uniqueItems",
        4 => "contains",
        _ => unreachable!(),
    };
    let mut seed = unsafe { &*report }.continuation(false);
    seed.entry = Some(ErrorEntry {
        source,
        instance,
        keyword,
        frame,
    });
    Box::into_raw(Box::new(seed))
}
/// # Safety
/// Collector report is live and exclusively borrowed. C marks its immutable
/// seed and all completed results instead while this mutation is in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_adopt(
    report: *mut Report,
    completed: *const Report,
) -> i32 {
    unsafe { &mut *report }
        .adopt(unsafe { &*completed }.clone())
        .status as i32
}
/// # Safety
/// Report is live and holds an active array accumulator; C uses the same mutation
/// root guard as sn_array_report_adopt. Index is produced by library traversal.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_record(report: *mut Report, index: usize) {
    unsafe { &mut *report }
        .evaluation
        .as_mut()
        .expect("array locations")
        .item(index);
}
/// # Safety
/// Report is live and immutable during this call; index is a library index.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_contains(
    report: *const Report,
    index: usize,
    prior: i32,
) -> i32 {
    let report = unsafe { &*report };
    i32::from(
        if prior != 0 {
            &report.array_prior
        } else {
            &report.evaluation
        }
        .as_ref()
        .is_some_and(|locations| locations.contains_item(index)),
    )
}
/// # Safety
/// Report is live and immutable during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_silent(report: *const Report) -> i32 {
    i32::from(unsafe { &*report }.silent)
}
/// # Safety
/// Report is live, complete and immutable during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_verdict(report: *const Report) -> i32 {
    unsafe { &*report }
        .evaluation
        .as_ref()
        .expect("completed report")
        .status as i32
}
/// # Safety
/// Report is live with an active array accumulator and C guards mutation as for
/// sn_array_report_adopt. Only the library completes an array traversal.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_array_report_finish(report: *mut Report, valid: i32) {
    let report = unsafe { &mut *report };
    report.array_prior = None;
    if valid == 0 {
        report.failed = true;
        report.evaluation = Some(Tracked::new(Invalid));
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_effects_keep_the_receiving_path_and_detect_silent_failure() {
        let mut report = Report {
            attempts: 2,
            ..Report::default()
        };
        report.instance_path.index(7);
        report.schema_path.push_str("/items");
        let before = report.continuation(true);
        assert!(before.effect_since(&before).is_none());
        let mut completed = before.clone();
        completed.reserve_error().unwrap();
        completed.errors.push(Error {
            keyword: "type",
            instance_path: pointer::Rendered::Native("/7/0".into()),
            schema_path: pointer::Rendered::Native("/items/items/type".into()),
            opcode: OP_TYPE_INTEGER,
            operand: 0,
            instance: 0,
            detail: 0,
            message: 0,
        });
        let effect = completed.effect_since(&before).unwrap();
        report.apply_effect(effect);
        assert_eq!(report.attempts, 3);
        assert!(report.failed);
        assert_eq!(report.instance_path.text, "/7");
        assert_eq!(report.schema_path.text, "/items");
        assert_eq!(report.errors.len(), 1);
        assert_eq!(report.errors[0].instance_path.bytes(), b"/7/0");
        assert!(!report.annotations);
        let silent = Report {
            silent: true,
            ..Report::default()
        };
        let mut completed = silent.clone();
        completed.failed = true;
        let effect = completed.effect_since(&silent).unwrap();
        assert!(effect.failed);
        assert_eq!(effect.attempts, 0);
        assert!(effect.errors.is_empty());
    }

    #[test]
    fn item_results_preserve_accumulators_paths_and_independent_trial_policy() {
        let mut base = Report {
            attempts: 1,
            ..Report::default()
        };
        base.instance_path.text.push_str("/outer");
        base.schema_path.text.push_str("/allOf/1");
        let mut prior = Tracked::new(Valid);
        prior.item(65);
        let mut report = base.array_continuation(true, &prior);
        unsafe {
            sn_array_report_record(&mut report, 4);
        }
        assert_eq!(unsafe { sn_array_report_contains(&report, 65, 1) }, 1);
        assert_eq!(unsafe { sn_array_report_contains(&report, 4, 0) }, 1);
        assert_eq!(unsafe { sn_array_report_contains(&report, 4, 1) }, 0);
        let keyword = b"prefixItems";
        let mut completed = unsafe {
            Box::from_raw(sn_array_report_child(
                &report,
                4,
                keyword.as_ptr(),
                keyword.len(),
                4,
                0,
            ))
        };
        assert_eq!(completed.instance_path.text, "/outer/4");
        assert_eq!(completed.schema_path.text, "/allOf/1/prefixItems/4");
        completed.attempts = 2;
        completed.failed = true;
        completed.evaluation = Some(Tracked::new(Invalid));
        assert_eq!(
            unsafe { sn_array_report_adopt(&mut report, &*completed) },
            VERDICT_INVALID
        );
        assert_eq!(report.instance_path.text, "/outer");
        assert_eq!(report.schema_path.text, "/allOf/1");
        assert_eq!(unsafe { sn_array_report_contains(&report, 65, 1) }, 1);
        assert_eq!(unsafe { sn_array_report_contains(&report, 4, 0) }, 1);
        assert_eq!(report.attempts, 2);
        assert!(report.annotations);
        let trial = unsafe {
            Box::from_raw(sn_array_report_child(
                &report,
                0,
                std::ptr::null(),
                0,
                usize::MAX,
                1,
            ))
        };
        assert!(trial.silent && trial.annotations);
        assert_eq!(trial.attempts, 0);
        assert!(trial.instance_path.text.is_empty());
        assert!(trial.schema_path.text.is_empty());
        unsafe {
            sn_array_report_finish(&mut report, 1);
        }
        assert_eq!(unsafe { sn_report_verdict(&report) }, VERDICT_VALID);
        assert!(report.failed);
        assert!(report.array_prior.is_none());
    }
}
