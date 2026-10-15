//! Object paths and opaque evaluated-property sets for C-owned report collectors.
use super::*;

/// # Safety
/// Report and segments are live and rooted by C. Keyword is a library UTF-8
/// segment; flags omit the instance (1), include a schema name (2), and export
/// child annotations (4). C owns the returned seed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_object_report_child(
    report: *const Report,
    instance: Value,
    keyword: *const u8,
    len: usize,
    child: Value,
    flags: i32,
) -> *mut Report {
    let mut seed = unsafe { &*report }.continuation(flags & 4 != 0);
    if !seed.silent {
        if flags & 1 == 0 {
            seed.instance_path.text.push('/');
            seed.instance_path
                .names
                .push((seed.instance_path.text.len(), instance));
        }
        seed.schema_path.push_str("/");
        seed.schema_path.push_str(
            std::str::from_utf8(unsafe { byte_view(keyword, len) }).expect("object keyword"),
        );
        if flags & 2 != 0 {
            seed.schema_path.text.push('/');
            seed.schema_path
                .names
                .push((seed.schema_path.text.len(), child));
        }
    }
    Box::into_raw(Box::new(seed))
}
/// # Safety
/// Report and engine are live and rooted, node owns an Object instruction, and
/// frame is retained by C. Keyword is a library object diagnostic ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_object_report_error(
    report: *const Report,
    engine: *const Engine,
    node: usize,
    instance: Value,
    keyword: i32,
    frame: Value,
) -> *mut Report {
    let keyword = match keyword {
        0 => "type",
        1 => "maxProperties",
        2 => "minProperties",
        3 => "required",
        4 => "dependencies",
        5 => "dependentRequired",
        _ => unreachable!(),
    };
    Box::into_raw(Box::new(unsafe { &*report }.container_error(
        unsafe { &*engine },
        node,
        instance,
        keyword,
        frame,
        true,
    )))
}
/// # Safety
/// Report is exclusively borrowed, C roots set in immutable completed roots,
/// and count is the size of that immutable Ruby Set. The collector guards mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_object_report_finish(
    report: *mut Report,
    valid: i32,
    set: Value,
    count: usize,
) {
    let report = unsafe { &mut *report };
    report.container_prior = None;
    let mut evaluation = Tracked::new(if valid != 0 { Valid } else { Invalid });
    if valid != 0 {
        evaluation.set_properties(set, count);
    } else {
        report.failed = true;
    }
    report.evaluation = Some(evaluation);
}
/// # Safety
/// Report/engine are live and rooted. C owns the returned immutable snapshot,
/// marks it while using it and frees it with sn_property_locations_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_object_report_properties(
    report: *const Report,
    engine: *const Engine,
    prior: i32,
) -> *mut tracking::PropertyLocations {
    let report = unsafe { &*report };
    let evaluation = if prior != 0 {
        &report.container_prior
    } else {
        &report.evaluation
    };
    let locations = evaluation.as_ref().map_or_else(
        || tracking::PropertyLocations {
            set: None,
            keys: vec![],
        },
        |evaluation| tracking::PropertyLocations::new(unsafe { &*engine }, evaluation),
    );
    Box::into_raw(Box::new(locations))
}
/// # Safety
/// Locations is a live immutable C-owned snapshot and count is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_property_locations_set(
    locations: *const tracking::PropertyLocations,
    count: *mut usize,
) -> Value {
    let locations = unsafe { &*locations };
    unsafe {
        *count = locations.keys.len();
    }
    locations.set.unwrap_or_else(|| unsafe { sn_nil() })
}
/// # Safety
/// Locations is live and index is in bounds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_property_locations_key(
    locations: *const tracking::PropertyLocations,
    index: usize,
) -> Value {
    unsafe { &*locations }.keys[index]
}
/// # Safety
/// Locations is live and immutable, called from C's GC mark callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_property_locations_mark(locations: *const tracking::PropertyLocations) {
    unsafe { &*locations }.mark();
}
/// # Safety
/// Locations is live and immutable, called from C's memory size callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_property_locations_size(
    locations: *const tracking::PropertyLocations,
) -> usize {
    std::mem::size_of::<tracking::PropertyLocations>() + unsafe { &*locations }.memory_usage()
}
/// # Safety
/// Locations is an owned snapshot, freed exactly once by its C TypedData holder.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_property_locations_free(locations: *mut tracking::PropertyLocations) {
    drop(unsafe { Box::from_raw(locations) });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn silent_child_failure_marks_the_live_collection_without_reserving_an_error() {
        let mut report = Report {
            silent: true,
            ..Report::default()
        };
        unsafe {
            sn_report_child_validity(&mut report, 1);
        }
        assert!(!report.failed);
        unsafe {
            sn_report_child_validity(&mut report, 0);
        }
        assert!(report.failed);
        assert_eq!(report.attempts, 0);
        assert!(report.errors.is_empty());
    }

    #[test]
    fn child_adoption_exports_child_properties_without_overwriting_parent_locations() {
        let mut parent = Report::default().container_continuation(true, &Tracked::new(Valid));
        parent.evaluation.as_mut().unwrap().set_properties(11, 2);
        let mut completed = parent.continuation(true);
        let mut child = Tracked::new(Valid);
        child.set_properties(17, 3);
        completed.evaluation = Some(child);
        let child = parent.adopt(completed);
        assert_eq!(child.properties_set(), Some(17));
        assert_eq!(child.property_count(), 3);
        assert_eq!(
            parent.evaluation.as_ref().unwrap().properties_set(),
            Some(11)
        );
        assert_eq!(parent.evaluation.as_ref().unwrap().property_count(), 2);
        let empty = Tracked::new(Valid);
        assert_eq!(empty.properties_set(), None);
        assert_eq!(empty.property_count(), 0);
    }
}

/// # Safety
/// Report is the idle current collection and C guards this exclusive mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_report_child_validity(report: *mut Report, valid: i32) {
    unsafe { &mut *report }.failed |= valid == 0;
}
