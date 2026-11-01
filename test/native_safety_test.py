"""Negative cases compile C, including macros, before exercising the checker."""
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

from script.native_safety import check


PREAMBLE = """
typedef unsigned long VALUE;
enum { RUBY_Qnil = 4, ST_CONTINUE = 0,
       RUBY_TYPED_FREE_IMMEDIATELY = 1, RUBY_TYPED_FROZEN_SHAREABLE = 256 };
extern VALUE rb_protect(VALUE (*)(VALUE), VALUE, int *);
extern VALUE rb_errinfo(void);
extern void rb_set_errinfo(VALUE);
extern void rb_gc_mark(VALUE);
extern VALUE rb_ary_new(void);
static int protected_result(VALUE (*callback)(VALUE), VALUE argument, VALUE *result) {
    int state = 0;
    *result = rb_protect(callback, argument, &state);
    if (state) { *result = rb_errinfo(); rb_set_errinfo(RUBY_Qnil); }
    return state;
}
void sn_pin(VALUE value) { rb_gc_mark(value); }
"""
ADAPTERS = "\n".join(
    f"static VALUE {callback}(VALUE value) {{ return value; }}\n"
    f"int {name}(VALUE input, VALUE *output) {{ return protected_result({callback}, input, output); }}"
    for name, callback in check.PROTECTED.items()
)
TYPE_DATA = """
typedef struct {
    const char *name;
    struct { void (*mark)(void *); void (*free)(void *); unsigned long (*size)(const void *);
             void (*compact)(void *); void *reserved[1]; } functions;
    const void *parent; void *data; VALUE flags;
} rb_data_type_t;
"""
SPEC = ("sample_type", "sample_mark", "sample_free", "sample_size", set(), {})


class NativeSafetyTest(unittest.TestCase):
    def parse(self, source):
        with tempfile.TemporaryDirectory(prefix="schemurai-c-contract-") as directory:
            path = Path(directory) / "fixture.c"
            path.write_text(PREAMBLE + ADAPTERS + "\n" + source)
            return check.parse_c(path, os.environ.get("CLANG", "clang"))

    def effect(self, source):
        return check.check_effects(self.parse(source), {"sn_leaf"})

    def test_accepts_pure_transitive_adapter(self):
        self.effect("static int helper(void) { return 1; } int sn_leaf(void) { return helper(); }")

    def test_rejects_allocation_directly_transitively_and_in_macros(self):
        for source in [
            "int sn_leaf(void) { rb_ary_new(); return 1; }",
            "static void helper(void) { rb_ary_new(); } int sn_leaf(void) { helper(); return 1; }",
            "#define HIDDEN_EFFECT() rb_ary_new()\nint sn_leaf(void) { HIDDEN_EFFECT(); return 1; }",
        ]:
            with self.subTest(source=source), self.assertRaisesRegex(check.ContractError, "rb_ary_new"):
                self.effect(source)

    def test_rejects_unreviewed_indirect_calls_and_missing_definitions(self):
        with self.assertRaisesRegex(check.ContractError, "indirect"):
            self.effect("int sn_leaf(void) { VALUE (*p)(void) = rb_ary_new; p(); return 1; }")
        with self.assertRaisesRegex(check.ContractError, "indirect"):
            self.effect("static int hash_visit(void) { VALUE (*p)(void) = rb_ary_new; p(); return 1; } int sn_leaf(void) { return hash_visit(); }")
        with self.assertRaisesRegex(check.ContractError, "unknown_leaf"):
            self.effect("extern int unknown_leaf(void); int sn_leaf(void) { return unknown_leaf(); }")

    def test_protected_adapters_cannot_call_ruby_outside_the_barrier(self):
        unit = self.parse("int sn_leaf(void) { return 1; }")
        unit.functions["sn_resolution_error"] = unit.functions["sn_leaf"]
        with self.assertRaisesRegex(check.ContractError, "protected_result"):
            check.check_effects(unit, {"sn_leaf"})
        check.check_barrier(unit)
        broken = copy.deepcopy(unit)
        check.body(broken.functions["protected_result"])["inner"].pop(2)
        with self.assertRaisesRegex(check.ContractError, "capture and clear"):
            check.check_barrier(broken)

    def holder(self, fields="VALUE kept; int count;", pins="rb_gc_mark(h->kept);", flags="RUBY_TYPED_FREE_IMMEDIATELY"):
        return self.parse(TYPE_DATA + f"""
            typedef struct {{ {fields} }} sample;
            static void sample_mark(void *ptr) {{ sample *h = ptr; {pins} }}
            static void sample_free(void *ptr) {{}}
            static unsigned long sample_size(const void *ptr) {{ return sizeof(sample); }}
            static const rb_data_type_t sample_type = {{
                "sample", {{sample_mark, sample_free, sample_size, 0, {{0}}}}, 0, 0, {flags}
            }};
        """)

    def test_added_value_and_pointer_fields_cannot_escape_root_classification(self):
        check.check_holder(self.holder(), "sample", SPEC)
        for fields, message in [
            ("VALUE kept, forgotten; int count;", "pin every VALUE"),
            ("VALUE kept; void *hidden;", "unclassified"),
            ("VALUE kept; VALUE hidden[2];", "unclassified"),
        ]:
            with self.subTest(fields=fields), self.assertRaisesRegex(check.ContractError, message):
                check.check_holder(self.holder(fields=fields), "sample", SPEC)
        with self.assertRaisesRegex(check.ContractError, "pin every VALUE"):
            check.check_holder(self.holder(pins="if (h->count) rb_gc_mark(h->kept);"), "sample", SPEC)

    def test_mutable_typed_data_cannot_gain_shareability(self):
        with self.assertRaisesRegex(check.ContractError, "only frozen Programs"):
            check.check_holder(self.holder(flags="RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE"), "sample", SPEC)

    def test_publication_rejects_missing_roots_wrong_order_and_compiling_programs(self):
        source = TYPE_DATA + """
            typedef struct { void *engine; const void *roots; VALUE program; int compiling; } holder;
            static const rb_data_type_t engine_type = {0};
            extern void *rbimpl_check_typeddata(VALUE, const void *);
            extern void rb_raise(VALUE, const char *);
            extern VALUE rb_eRuntimeError;
            extern unsigned long sn_root_count(const void *);
            extern VALUE sn_root_at(const void *, unsigned long);
            extern VALUE rb_ractor_make_shareable(VALUE);
            static holder *ready_program(VALUE self) {
                holder *h;
                h = rbimpl_check_typeddata(self, &engine_type);
                if (!h->engine) rb_raise(rb_eRuntimeError, "uninitialized");
                if (h->compiling) rb_raise(rb_eRuntimeError, "compiling");
                return h;
            }
            static VALUE make_shareable(VALUE self) {
                holder *h = ready_program(self);
                unsigned long count = sn_root_count(h->roots);
                for (unsigned long i = 0; i < count; i++) rb_ractor_make_shareable(sn_root_at(h->roots, i));
                rb_ractor_make_shareable(h->program);
                return rb_ractor_make_shareable(self);
            }
        """
        check.check_publication(self.parse(source))
        for before, after in [
            ("sn_root_count(h->roots)", "0"),
            ("i < count", "i + 1 < count"),
            ("rb_ractor_make_shareable(h->program);", "rb_ractor_make_shareable(self);"),
            ('if (h->compiling) rb_raise(rb_eRuntimeError, "compiling");', ""),
        ]:
            with self.subTest(before=before), self.assertRaises(check.ContractError):
                check.check_publication(self.parse(source.replace(before, after)))

    def test_results_must_be_rooted_before_rust_publication_in_each_branch(self):
        source = """
            typedef struct { VALUE messages, pointers, report_results; void *caches; } runner;
            typedef struct { void *report; } report_holder;
            typedef struct { VALUE buffer, properties, items; } runtime_locations;
            static int report_type;
            extern void rb_ary_push(VALUE, VALUE);
            extern void sn_message_result(void *, VALUE);
            extern void sn_pointer_result(void *, VALUE);
            extern void sn_properties_result(void *, const runtime_locations *);
            extern void sn_report_accept(void *, const void *);
            extern void *rbimpl_check_typeddata(VALUE, const void *);
            extern runtime_locations read_runtime_locations(VALUE);
            static void root_runtime_locations(VALUE roots, runtime_locations *locations) {
                rb_ary_push(roots, locations->buffer);
                rb_ary_push(roots, locations->properties);
                rb_ary_push(roots, locations->items);
            }
            void evaluate_runtime(runner *r, VALUE result, int kind) {
                if (kind == 0) { rb_ary_push(r->messages, result); sn_message_result(r->caches, result); }
                if (kind == 1) { rb_ary_push(r->pointers, result); sn_pointer_result(r->caches, result); }
            }
            void merge_runtime_properties(runner *r, VALUE result) {
                runtime_locations locations = read_runtime_locations(result);
                root_runtime_locations(r->report_results, &locations);
                sn_properties_result(r->caches, &locations);
            }
            void container_report_runtime(runner *r, VALUE result) {
                rb_ary_push(r->report_results, result);
                report_holder *completed;
                completed = rbimpl_check_typeddata(result, &report_type);
                sn_report_accept(r->caches, completed->report);
            }
            void call_runtime(runner *r, VALUE result) {
                rb_ary_push(r->report_results, result);
                report_holder *completed;
                completed = rbimpl_check_typeddata(result, &report_type);
                sn_report_accept(r->caches, completed->report);
            }
        """
        unit = self.parse(source)
        check.check_result_roots(unit)
        check.check_runtime_location_roots(unit)
        for missing in ["buffer", "properties", "items"]:
            with self.subTest(missing=missing), self.assertRaises(check.ContractError):
                check.check_runtime_location_roots(self.parse(source.replace(
                    f"rb_ary_push(roots, locations->{missing});", "")))
        for broken in [
            source.replace("rb_ary_push(r->messages, result);", ""),
            source.replace("sn_pointer_result(r->caches, result);", "sn_pointer_result(r->caches, r->messages);"),
            source.replace("read_runtime_locations(result)", "read_runtime_locations(r->messages)"),
            source.replace("rbimpl_check_typeddata(result,", "rbimpl_check_typeddata(r->messages,"),
            source.replace("if (kind == 0)", "if ((sn_message_result(r->caches, result), kind == 0))"),
        ]:
            with self.subTest(broken=broken), self.assertRaises(check.ContractError):
                check.check_result_roots(self.parse(broken))

    def test_c_globals_cannot_gain_handles_or_ractor_shared_runtime_state(self):
        source = TYPE_DATA + """
            typedef unsigned long ID;
            static ID id_resolve, id_schemurai, id_resolution_error, id_root, id_compile, id_graph;
            static ID id_dynamic_anchor, id_dynamic_anchor_names, id_dynamic_anchor_count;
            static ID identity_methods[5];
            static _Thread_local const void *active_caches;
            static int utf8_index, ascii_index, binary_index;
            static const rb_data_type_t engine_type, runner_type, report_type, report_collector_type, property_locations_type, construction_guard_type;
            static struct { ID id; const char *symbol; } fields[1];
            static struct { ID id; const char *symbol; int opcode; } opcodes[1];
        """
        check.check_globals(self.parse(source))
        for broken in [
            source + "static VALUE leaked;",
            source.replace("_Thread_local ", ""),
            source.replace("const void *active_caches", "VALUE active_caches"),
            source.replace("ID id; const char *symbol;", "VALUE id; const char *symbol;"),
        ]:
            with self.subTest(broken=broken), self.assertRaises(check.ContractError):
                check.check_globals(self.parse(broken))

    def test_snapshot_lifecycle_rejects_early_free_missing_capture_and_early_release(self):
        source = """
            enum { SN_VERDICT_UNSUPPORTED = 2 };
            typedef struct { void *caches, *root_snapshot; } runner_holder;
            typedef struct { runner_holder *runner; int status; } evaluation_call;
            static const void *active_caches;
            extern void *sn_caches_snapshot(const void *);
            extern void sn_caches_begin(void *);
            extern void sn_root_snapshot_free(void *);
            extern unsigned long sn_root_snapshot_size(const void *);
            extern VALUE rb_eRuntimeError;
            extern void rb_raise(VALUE, const char *);
            extern void publish_scope(runner_holder *);
            static void refresh_root_snapshot(runner_holder *runner) {
                void *next = sn_caches_snapshot(runner->caches);
                if (!next) rb_raise(rb_eRuntimeError, "native root snapshot has an active borrow");
                void *previous = runner->root_snapshot;
                runner->root_snapshot = next;
                sn_root_snapshot_free(previous);
            }
            static void clear_native_caches(runner_holder *runner) {
                sn_caches_begin(runner->caches);
                void *previous = runner->root_snapshot;
                runner->root_snapshot = 0;
                sn_root_snapshot_free(previous);
            }
            static void clear_runtime(runner_holder *runner) { clear_native_caches(runner); }
            static void close_callback_scope(runner_holder *scope) { clear_native_caches(scope); }
            static void evaluate_native(evaluation_call *call) {
                runner_holder *r = call->runner;
                const void *previous_caches = active_caches;
                active_caches = previous_caches;
                if (call->status == SN_VERDICT_UNSUPPORTED) refresh_root_snapshot(r);
                publish_scope(r);
            }
            static void runner_release(void *ptr) {
                runner_holder *h = ptr;
                sn_root_snapshot_free(h->root_snapshot);
            }
            static unsigned long runner_size(const void *ptr) {
                const runner_holder *h = ptr;
                unsigned long bytes = 0;
                if (h->root_snapshot) bytes += sn_root_snapshot_size(h->root_snapshot);
                return bytes;
            }
        """
        check.check_snapshot_protocol(self.parse(source))
        for before, after in [
            ("runner->root_snapshot = next;", "runner->root_snapshot = 0;"),
            ("if (call->status == SN_VERDICT_UNSUPPORTED) refresh_root_snapshot(r);", ""),
            ("sn_caches_begin(runner->caches);", ""),
            ("sn_root_snapshot_free(h->root_snapshot);", "sn_root_snapshot_free(h->caches);"),
            ("if (h->root_snapshot) bytes += sn_root_snapshot_size(h->root_snapshot);", ""),
        ]:
            with self.subTest(before=before), self.assertRaises(check.ContractError):
                check.check_snapshot_protocol(self.parse(source.replace(before, after)))

    def test_construction_guard_blocks_generic_ractor_publication_until_success(self):
        source = TYPE_DATA + """
            enum { SN_VERDICT_VALID = 1 };
            extern VALUE rb_cObject, rb_eRuntimeError;
            extern VALUE rb_data_typed_object_wrap(VALUE, void *, const rb_data_type_t *);
            extern void rb_raise(VALUE, const char *);
            typedef struct { VALUE construction_guard; } holder;
            static const rb_data_type_t construction_guard_type = {
                "Schemurai::Native::ProgramConstruction",
                {0, 0, 0, 0, {0}}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
            };
            static VALUE allocate(VALUE klass) {
                VALUE guard = rb_data_typed_object_wrap(rb_cObject, 0, &construction_guard_type);
                holder *h = (holder *)klass;
                h->construction_guard = guard;
                return klass;
            }
            static VALUE initialize(VALUE self, int status) {
                holder *h = (holder *)self;
                if (status != SN_VERDICT_VALID) {
                    rb_raise(rb_eRuntimeError, "compile failed");
                }
                h->construction_guard = RUBY_Qnil;
                return self;
            }
        """
        check.check_construction_guard(self.parse(source))
        for before, after in [
            ("0, 0, RUBY_TYPED_FREE_IMMEDIATELY", "0, 0, RUBY_TYPED_FROZEN_SHAREABLE"),
            ("h->construction_guard = guard;", ""),
            ("if (status != SN_VERDICT_VALID)", "if (status == SN_VERDICT_VALID)"),
            ('rb_raise(rb_eRuntimeError, "compile failed");', "return self;"),
            ("holder *h = (holder *)self;", "holder *h = (holder *)self; h->construction_guard = RUBY_Qnil;"),
        ]:
            with self.subTest(before=before), self.assertRaises(check.ContractError):
                check.check_construction_guard(self.parse(source.replace(before, after)))

    def test_json_framing_fails_closed(self):
        data = json.dumps({"kind": "TranslationUnitDecl", "inner": [{"kind": "FunctionDecl", "name": "sample"}]}, indent=2) + "\n"
        self.assertEqual(list(check.ast_nodes(io.StringIO(data)))[0]["name"], "sample")
        for text in ["{}", data[:-8], data + "extra"]:
            with self.subTest(text=text), self.assertRaises(check.ContractError):
                list(check.ast_nodes(io.StringIO(text)))

    def test_rust_imports_exclude_comments_and_method_wrappers(self):
        self.assertEqual(check.rust_imports('''
            // unsafe extern "C" { fn sn_fake(); }
            impl Ruby { unsafe fn sn_wrapper() {} }
            unsafe extern "C" { pub(super) fn sn_leaf(value: Value); }
        '''), {"sn_leaf"})
        with self.assertRaises(check.ContractError):
            check.rust_imports("impl Ruby {}")


if __name__ == "__main__":
    unittest.main()
