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
        "fn depth(_: usize) {} fn bad(tag: ruby::FixnumTag) { depth(tag); }",
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
