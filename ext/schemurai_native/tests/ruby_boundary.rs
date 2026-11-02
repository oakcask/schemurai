//! AST guardrails around the compiler-enforced VALUE and tracing contracts.
use std::path::Path;
use syn::visit::{self, Visit};

struct Boundary<'a> {
    file: &'a str,
    function: String,
    engine_impl: bool,
    compiling: bool,
    c_entry: bool,
    errors: Vec<String>,
}
impl Boundary<'_> {
    fn reject(&mut self, reason: &str) {
        self.errors.push(format!("{}: {reason}", self.file));
    }
}
fn protected(name: &str) -> bool {
    include_str!("../protected.def").lines().any(|line| {
        line.strip_prefix("SN_PROTECTED(")
            .and_then(|entry| entry.split_once(", "))
            .is_some_and(|(adapter, _)| adapter == name)
    })
}
fn mutable_receiver(signature: &syn::Signature) -> bool {
    signature
        .receiver()
        .is_some_and(|receiver| receiver.reference.is_some() && receiver.mutability.is_some())
}
fn test_only(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        attr.path().is_ident("cfg")
            && attr
                .parse_args::<syn::Path>()
                .is_ok_and(|path| path.is_ident("test"))
    })
}
impl<'ast> Visit<'ast> for Boundary<'_> {
    fn visit_item_mod(&mut self, item: &'ast syn::ItemMod) {
        if !test_only(&item.attrs) {
            visit::visit_item_mod(self, item);
        }
    }
    fn visit_item_fn(&mut self, item: &'ast syn::ItemFn) {
        if test_only(&item.attrs) {
            return;
        }
        let previous = std::mem::replace(&mut self.function, item.sig.ident.to_string());
        let c_entry = item.sig.unsafety.is_some()
            && item
                .sig
                .abi
                .as_ref()
                .and_then(|abi| abi.name.as_ref())
                .is_some_and(|name| name.value() == "C");
        let previous_entry = std::mem::replace(&mut self.c_entry, c_entry);
        visit::visit_item_fn(self, item);
        self.function = previous;
        self.c_entry = previous_entry;
    }
    fn visit_item_foreign_mod(&mut self, item: &'ast syn::ItemForeignMod) {
        if self.file != "ruby.rs" {
            self.reject("foreign declarations belong in ruby.rs");
        }
        visit::visit_item_foreign_mod(self, item);
    }
    fn visit_foreign_item_fn(&mut self, item: &'ast syn::ForeignItemFn) {
        if item.attrs.iter().any(|attr| !attr.path().is_ident("doc")) {
            self.reject("foreign adapter aliases/conditional attributes require boundary review");
        }
        if protected(&item.sig.ident.to_string()) && !matches!(item.vis, syn::Visibility::Inherited)
        {
            self.reject("raw protected adapters must remain private");
        }
        visit::visit_foreign_item_fn(self, item);
    }
    fn visit_item_type(&mut self, item: &'ast syn::ItemType) {
        if item.ident == "Value" {
            self.reject("VALUE must remain the opaque ruby::Value type");
        }
        visit::visit_item_type(self, item);
    }
    fn visit_item_impl(&mut self, item: &'ast syn::ItemImpl) {
        if let Some((_, path, _)) = &item.trait_ {
            let name = path.segments.last().unwrap().ident.to_string();
            if item.unsafety.is_some() && matches!(name.as_str(), "Send" | "Sync") {
                self.reject("do not bypass Ractor affinity with unsafe Send/Sync");
            }
            if matches!(name.as_str(), "Trace" | "NativeOnly") && self.file != "ruby_trace.rs" {
                // These implementations either match every enum variant, fully
                // destructure a tuple, or describe a concrete foreign type.
                // New aggregates must use the field-complete macros.
                let ty = match item.self_ty.as_ref() {
                    syn::Type::Path(ty) => ty.path.segments.last().unwrap().ident.to_string(),
                    _ => String::new(),
                };
                let allowed = matches!(
                    (self.file, name.as_str(), ty.as_str()),
                    ("lib.rs", "NativeOnly", "Verdict")
                        | ("content.rs", "NativeOnly", "Scratch")
                        | ("tracking.rs", "NativeOnly", "PropertyWords")
                        | ("tracking.rs", "Trace", "JsonKey")
                        | ("pointer.rs", "Trace", "Rendered")
                        | ("runtime.rs", "NativeOnly", "Cache")
                        | ("runtime/scopes.rs", "Trace", "Key")
                );
                if !allowed {
                    self.reject("use field-complete tracing/native macros for new types");
                }
            }
        }
        let engine_impl = matches!(item.self_ty.as_ref(), syn::Type::Path(ty)
            if ty.path.is_ident("Engine"));
        let previous = std::mem::replace(&mut self.engine_impl, engine_impl);
        visit::visit_item_impl(self, item);
        self.engine_impl = previous;
    }
    fn visit_impl_item_fn(&mut self, item: &'ast syn::ImplItemFn) {
        if self.file == "ruby.rs"
            && protected(&item.sig.ident.to_string())
            && (item.sig.unsafety.is_none() || !mutable_receiver(&item.sig))
        {
            self.reject("protected Ruby adapters require unsafe mutable token access");
        }
        let mutable_engine = self.engine_impl && mutable_receiver(&item.sig);
        let previous = std::mem::replace(&mut self.compiling, mutable_engine);
        visit::visit_impl_item_fn(self, item);
        self.compiling = previous;
    }
    fn visit_path(&mut self, path: &'ast syn::Path) {
        if let Some(segment) = path.segments.last() {
            let name = segment.ident.to_string();
            if name == "enter"
                && path.segments.iter().any(|segment| segment.ident == "Ruby")
                && self.file != "ruby.rs"
                && !(self.c_entry
                    && matches!(
                        (self.file, self.function.as_str()),
                        ("lib.rs", "sn_compile" | "sn_valid" | "sn_valid_with_limits")
                            | ("diagnostics.rs", "sn_diagnose" | "sn_diagnose_with_limits")
                            | ("diagnostics/array.rs", "sn_array_report_child")
                            | ("diagnostics/object.rs", "sn_object_report_child")
                    ))
            {
                self.reject("VM tokens may only be created at audited C entrypoints");
            }
            if name == "from_raw_parts" && self.file != "ruby.rs" {
                self.reject("raw slices must borrow a VM token or initialized Rust buffer");
            }
            if matches!(
                name.as_str(),
                "sn_compile"
                    | "sn_valid"
                    | "sn_valid_with_limits"
                    | "sn_diagnose"
                    | "sn_diagnose_with_limits"
                    | "sn_array_report_child"
                    | "sn_object_report_child"
            ) {
                self.reject("native invocation entrypoints must not be reentered from Rust");
            }
            if protected(&name) && self.file != "ruby.rs" && !self.compiling {
                self.reject(
                    "allocating Ruby adapters require exclusive compilation access to Engine",
                );
            }
            if name == "sn_pin" && !matches!(self.file, "ruby.rs" | "ruby_trace.rs") {
                self.reject("GC marking must use the Trace boundary");
            }
            if matches!(name.as_str(), "transmute" | "transmute_copy" | "zeroed") {
                self.reject("raw bit reconstruction can bypass VALUE affinity and rooting");
            }
        }
        visit::visit_path(self, path);
    }
    fn visit_expr_method_call(&mut self, expr: &'ast syn::ExprMethodCall) {
        if protected(&expr.method.to_string()) && self.file != "ruby.rs" && !self.compiling {
            self.reject("allocating Ruby adapters require exclusive compilation access to Engine");
        }
        if expr.method == "mark"
            && !matches!(
                self.function.as_str(),
                "sn_roots_mark"
                    | "sn_root_snapshot_mark"
                    | "sn_report_mark"
                    | "sn_property_locations_mark"
                    | "sn_caches_mark"
            )
        {
            self.reject("mark is only permitted in TypedData GC entrypoints");
        }
        visit::visit_expr_method_call(self, expr);
    }
    fn visit_macro(&mut self, item: &'ast syn::Macro) {
        if item.path.is_ident("thread_local") {
            self.reject("Rust thread-local VALUE state is not Ractor-local state");
        }
        if item
            .path
            .segments
            .last()
            .is_some_and(|s| s.ident == "trace_runner_fields")
            && !matches!(
                self.file,
                "runtime.rs" | "runtime/scopes.rs" | "runtime/reports.rs" | "runtime/properties.rs"
            )
        {
            self.reject("borrow-conflict fallback requires an audited C runner owner");
        }
        visit::visit_macro(self, item);
    }
}
fn inspect(file: &str, source: &str) -> Vec<String> {
    let ast = syn::parse_file(source).expect("parse Rust source for VALUE boundary checks");
    let mut checker = Boundary {
        file,
        function: String::new(),
        engine_impl: false,
        compiling: false,
        c_entry: false,
        errors: vec![],
    };
    checker.visit_file(&ast);
    checker.errors
}
fn check_directory(root: &Path, directory: &Path) {
    for entry in std::fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            check_directory(root, &path);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            let errors = inspect(&relative, &std::fs::read_to_string(&path).unwrap());
            assert!(errors.is_empty(), "{}", errors.join("\n"));
        }
    }
}
#[test]
fn production_sources_keep_the_ruby_boundary_closed() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    check_directory(&root, &root);
}
#[test]
fn rejects_bypasses_without_matching_comments_or_test_fixtures() {
    for (source, message) in [
        ("unsafe impl Send for Handle {}", "Send/Sync"),
        ("unsafe impl Sync for Handle {}", "Send/Sync"),
        (
            "unsafe extern \"C\" { fn adapter(); }",
            "foreign declarations",
        ),
        ("type Value = usize;", "opaque"),
        (
            "fn eval() { let vm = unsafe { ruby::Ruby::enter() }; }",
            "VM tokens",
        ),
        (
            "fn sn_valid() { let vm = unsafe { Ruby::enter() }; }",
            "VM tokens",
        ),
        ("fn eval() { unsafe { sn_valid(); } }", "reentered"),
        (
            "fn eval() { unsafe { std::slice::from_raw_parts(data, len); } }",
            "raw slices",
        ),
        (
            "impl Execution { fn eval(&mut self) { vm.sn_pairs(value, &mut out); } }",
            "exclusive compilation",
        ),
        (
            "impl Engine { fn eval(&self) { sn_field(); } }",
            "exclusive compilation",
        ),
        (
            "impl Execution { fn eval(&mut self) { sn_resolve(); } }",
            "exclusive compilation",
        ),
        ("fn f() { unsafe { sn_pin(value); } }", "Trace boundary"),
        (
            "fn f() { unsafe { std::mem::transmute(value); } }",
            "reconstruction",
        ),
        ("fn f() { value.mark(); }", "TypedData"),
        ("thread_local! { static V: Value = value; }", "thread-local"),
        ("impl NativeOnly for Hidden {}", "field-complete"),
        (
            "ruby_trace::trace_runner_fields!(Hidden { ; ; ; });",
            "audited C runner",
        ),
    ] {
        let errors = inspect("example.rs", source);
        assert!(
            errors.iter().any(|error| error.contains(message)),
            "{source}: {errors:?}"
        );
    }
    assert!(
        inspect(
            "example.rs",
            "// unsafe impl Send for Value {}\n#[cfg(test)] mod tests { type Value = usize; }"
        )
        .is_empty()
    );
}

#[test]
fn protected_imports_and_receivers_cannot_weaken_the_vm_token() {
    for source in [
        "impl Ruby { unsafe fn sn_resolution_error(&self) {} }",
        "impl Ruby { fn sn_resolution_error(&mut self) {} }",
        "unsafe extern \"C\" { pub(super) fn sn_resolution_error(); }",
        "unsafe extern \"C\" { #[link_name = \"rb_ary_new\"] fn sn_leaf(); }",
    ] {
        assert!(!inspect("ruby.rs", source).is_empty(), "{source}");
    }
    assert!(
        inspect(
            "ruby.rs",
            "impl Ruby { unsafe fn sn_resolution_error(&mut self) {} }"
        )
        .is_empty()
    );
}
