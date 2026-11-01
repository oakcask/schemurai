//! Exercise the compiler's rejection paths, independent of libruby.
use std::io::Write;
use std::process::{Command, Stdio};

fn check(name: &str, body: &str, error: Option<&str>) {
    let output_path = std::env::temp_dir().join(format!(
        "schemurai-contract-{}-{name}.rmeta",
        std::process::id()
    ));
    let source = format!(
        "#![allow(dead_code, unused_imports)]\n\
         #[path = \"src/ruby.rs\"] mod ruby;\n\
         #[path = \"src/ruby_trace.rs\"] mod ruby_trace;\n\
         use ruby::Value;\n{body}\nfn main() {{}}"
    );
    let mut child = Command::new("rustc")
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args([
            "--edition=2024",
            "--crate-name",
            "ruby_contract",
            "--emit=metadata",
            "-o",
        ])
        .arg(&output_path)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run rustc");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(source.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    let _ = std::fs::remove_file(output_path);
    let diagnostic = String::from_utf8_lossy(&output.stderr);
    if let Some(error) = error {
        assert!(!output.status.success(), "{name} unexpectedly compiled");
        assert!(diagnostic.contains(error), "{name}: {diagnostic}");
    } else {
        assert!(output.status.success(), "{name}: {diagnostic}");
    }
}

#[test]
fn integer_tags_cannot_be_confused_with_depths() {
    check(
        "tag_is_not_depth",
        "fn depth(_: usize) {} unsafe fn bad() { depth(unsafe { ruby::sn_fixnum_flag() }); }",
        Some("E0308"),
    );
    check(
        "depth_is_not_tag",
        "fn bad(value: Value, depth: usize) { value.has_fixnum_tag(depth); }",
        Some("E0308"),
    );
    check(
        "typed_tag",
        "fn classify(value: Value, tag: ruby::FixnumTag) -> bool { value.has_fixnum_tag(tag) }",
        None,
    );
}

#[test]
fn handles_reject_integer_and_thread_boundaries() {
    check("integer", "fn bad(x: usize) -> Value { x }", Some("E0308"));
    check(
        "forged",
        "fn bad() -> Value { Value { bits: 1, affinity: Default::default() } }",
        Some("E0451"),
    );
    check(
        "send",
        "fn send<T: Send>() {} fn bad() { send::<Value>(); }",
        Some("E0277"),
    );
    check(
        "sync",
        "fn sync<T: Sync>() {} fn bad() { sync::<Value>(); }",
        Some("E0277"),
    );
    check(
        "nested_send",
        "fn send<T: Send>() {} fn bad() { send::<Vec<Value>>(); }",
        Some("E0277"),
    );
}

#[test]
fn traversal_rejects_unclassified_fields_and_hidden_handles() {
    check(
        "valid",
        r#"
        struct Snapshot { values: Vec<Value>, count: usize }
        ruby_trace::trace_fields!(Snapshot { values ; count });
    "#,
        None,
    );
    check(
        "added",
        r#"
        struct Snapshot { values: Vec<Value>, pub extra: Option<Value>, count: usize }
        ruby_trace::trace_fields!(Snapshot { values ; count });
    "#,
        Some("field"),
    );
    check(
        "hidden",
        r#"
        struct Snapshot { values: Vec<Value>, count: Option<Vec<Value>> }
        ruby_trace::trace_fields!(Snapshot { values ; count });
    "#,
        Some("NativeOnly"),
    );
    check(
        "native_added",
        r#"
        struct Native { count: usize, pub hidden: Value }
        ruby_trace::native_fields!(Native { count });
    "#,
        Some("field"),
    );
    check(
        "native_changed",
        r#"
        struct Native { count: Value }
        ruby_trace::native_fields!(Native { count });
    "#,
        Some("NativeOnly"),
    );
}

#[test]
fn ruby_views_cannot_escape_or_overlap_an_allocating_adapter() {
    check(
        "loan_valid",
        r#"
        fn use_view(vm: &ruby::Ruby, data: *const u8) -> usize {
            unsafe { vm.bytes(data, 1) }.len()
        }
    "#,
        None,
    );
    check(
        "loan_escape",
        r#"
        fn bad(data: *const u8) -> &'static [u8] {
            let vm = unsafe { ruby::Ruby::enter() };
            unsafe { vm.bytes(data, 1) }
        }
    "#,
        Some("E0515"),
    );
    check(
        "array_loan_escape",
        r#"
        fn bad(data: *const Value) -> &'static [Value] {
            let vm = unsafe { ruby::Ruby::enter() };
            unsafe { vm.values(data, 1) }
        }
    "#,
        Some("E0515"),
    );
    check(
        "loan_and_callback",
        r#"
        fn bad(vm: &mut ruby::Ruby, value: Value, data: *const u8) -> u8 {
            let bytes = unsafe { vm.bytes(data, 1) };
            let mut output = Value::default();
            unsafe { vm.sn_pairs(value, &mut output) };
            bytes[0]
        }
    "#,
        Some("E0502"),
    );
    check(
        "array_and_callback",
        r#"
        fn bad(vm: &mut ruby::Ruby, value: Value, data: *const Value) -> Value {
            let values = unsafe { vm.values(data, 1) };
            let mut output = Value::default();
            unsafe { vm.sn_pairs(value, &mut output) };
            values[0]
        }
    "#,
        Some("E0502"),
    );
    check(
        "evaluation_cannot_call_ruby",
        r#"
        fn bad(vm: &ruby::Ruby, value: Value) {
            let mut output = Value::default();
            unsafe { vm.sn_pairs(value, &mut output) };
        }
    "#,
        Some("E0596"),
    );
    check(
        "private_allocator",
        r#"
        fn bad(value: Value) {
            let mut output = Value::default();
            unsafe { ruby::sn_pairs(value, &mut output) };
        }
    "#,
        Some("E0603"),
    );
    check(
        "buffer_loan_escape",
        r#"
        fn bad() -> &'static [Value] {
            let buffer = std::mem::MaybeUninit::<[Value; 2]>::uninit();
            unsafe { ruby::initialized_values(&buffer, 0) }
        }
    "#,
        Some("E0515"),
    );
    check(
        "vm_clone",
        "fn clone<T: Clone>() {} fn bad() { clone::<ruby::Ruby>(); }",
        Some("E0277"),
    );
    check(
        "vm_send",
        "fn send<T: Send>() {} fn bad() { send::<ruby::Ruby>(); }",
        Some("E0277"),
    );
    check(
        "vm_sync",
        "fn sync<T: Sync>() {} fn bad() { sync::<ruby::Ruby>(); }",
        Some("E0277"),
    );
}

#[test]
fn owned_root_snapshots_are_immutable_and_ractor_affine() {
    check(
        "snapshot_private",
        "fn bad(snapshot: &mut ruby_trace::RootSnapshot) { snapshot.values = Box::new([]); }",
        Some("E0616"),
    );
    check(
        "snapshot_send",
        "fn send<T: Send>() {} fn bad() { send::<ruby_trace::RootSnapshot>(); }",
        Some("E0277"),
    );
    check(
        "snapshot_sync",
        "fn sync<T: Sync>() {} fn bad() { sync::<ruby_trace::RootSnapshot>(); }",
        Some("E0277"),
    );
    check(
        "snapshot_clone",
        "fn clone<T: Clone>() {} fn bad() { clone::<ruby_trace::RootSnapshot>(); }",
        Some("E0277"),
    );
}
