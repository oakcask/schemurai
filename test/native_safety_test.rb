# frozen_string_literal: true

# Negative cases compile C, including macros, before exercising the checker.
require "rspec"
require "stringio"
require "tmpdir"
require_relative "../script/native_safety/check"

RSpec.describe NativeSafety do
  let(:preamble) do
    <<~C
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
    C
  end

  let(:type_data) do
    <<~C
      typedef struct {
          const char *name;
          struct { void (*mark)(void *); void (*free)(void *); unsigned long (*size)(const void *);
                   void (*compact)(void *); void *reserved[1]; } functions;
          const void *parent; void *data; VALUE flags;
      } rb_data_type_t;
    C
  end

  let(:adapters) do
    NativeSafety::PROTECTED.map do |name, callback|
      "static VALUE #{callback}(VALUE value) { return value; }\n" \
        "int #{name}(VALUE input, VALUE *output) { return protected_result(#{callback}, input, output); }"
    end.join("\n")
  end

  let(:holder_spec) { ["sample_type", "sample_mark", "sample_free", "sample_size", Set.new, {}] }

  def parse(source)
    Dir.mktmpdir("schemurai-c-contract-") do |directory|
      path = File.join(directory, "fixture.c")
      File.write(path, preamble + adapters + "\n" + source)
      NativeSafety.parse_c(path, ENV.fetch("CLANG", "clang"))
    end
  end

  def effect(source)
    NativeSafety.check_effects(parse(source), Set["sn_leaf"])
  end

  it "accepts pure transitive adapter" do
    effect("static int helper(void) { return 1; } int sn_leaf(void) { return helper(); }")
  end

  it "rejects allocation directly transitively and in macros" do
    [
      "int sn_leaf(void) { rb_ary_new(); return 1; }",
      "static void helper(void) { rb_ary_new(); } int sn_leaf(void) { helper(); return 1; }",
      "#define HIDDEN_EFFECT() rb_ary_new()\nint sn_leaf(void) { HIDDEN_EFFECT(); return 1; }"
    ].each do |source|
      expect do
        effect(source)
      end.to raise_error(NativeSafety::ContractError, /rb_ary_new/)
    end
  end

  it "rejects unreviewed indirect calls and missing definitions" do
    expect do
      effect("int sn_leaf(void) { VALUE (*p)(void) = rb_ary_new; p(); return 1; }")
    end.to raise_error(NativeSafety::ContractError, /indirect/)
    expect do
      effect("static int hash_visit(void) { VALUE (*p)(void) = rb_ary_new; p(); return 1; } int sn_leaf(void) { return hash_visit(); }")
    end.to raise_error(NativeSafety::ContractError, /indirect/)
    expect do
      effect("extern int unknown_leaf(void); int sn_leaf(void) { return unknown_leaf(); }")
    end.to raise_error(NativeSafety::ContractError, /unknown_leaf/)
  end

  it "protected adapters cannot call ruby outside the barrier" do
    unit = parse("int sn_leaf(void) { return 1; }")
    unit.functions["sn_resolution_error"] = unit.functions["sn_leaf"]
    expect do
      NativeSafety.check_effects(unit, Set["sn_leaf"])
    end.to raise_error(NativeSafety::ContractError, /protected_result/)
    NativeSafety.check_barrier(unit)
    broken = Marshal.load(Marshal.dump(unit))
    NativeSafety.body(broken.functions["protected_result"])["inner"].delete_at(2)
    expect do
      NativeSafety.check_barrier(broken)
    end.to raise_error(NativeSafety::ContractError, /capture and clear/)
  end

  def holder(fields: "VALUE kept; int count;", pins: "rb_gc_mark(h->kept);", flags: "RUBY_TYPED_FREE_IMMEDIATELY")
    parse(type_data + <<~C)
      typedef struct { #{fields} } sample;
      static void sample_mark(void *ptr) { sample *h = ptr; #{pins} }
      static void sample_free(void *ptr) {}
      static unsigned long sample_size(const void *ptr) { return sizeof(sample); }
      static const rb_data_type_t sample_type = {
          "sample", {sample_mark, sample_free, sample_size, 0, {0}}, 0, 0, #{flags}
      };
    C
  end

  it "added value and pointer fields cannot escape root classification" do
    NativeSafety.check_holder(holder, "sample", holder_spec)
    [
      ["VALUE kept, forgotten; int count;", "pin every VALUE"],
      ["VALUE kept; void *hidden;", "unclassified"],
      ["VALUE kept; VALUE hidden[2];", "unclassified"]
    ].each do |fields, message|
      expect do
        NativeSafety.check_holder(holder(fields: fields), "sample", holder_spec)
      end.to raise_error(NativeSafety::ContractError, Regexp.new(message))
    end
    expect do
      NativeSafety.check_holder(holder(pins: "if (h->count) rb_gc_mark(h->kept);"), "sample", holder_spec)
    end.to raise_error(NativeSafety::ContractError, /pin every VALUE/)
  end

  it "mutable typed data cannot gain shareability" do
    expect do
      NativeSafety.check_holder(holder(flags: "RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE"), "sample", holder_spec)
    end.to raise_error(NativeSafety::ContractError, /only frozen Programs/)
  end

  it "publication rejects missing roots wrong order and compiling programs" do
    source = type_data + <<~C
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

    C
    NativeSafety.check_publication(parse(source))
    [
      ["sn_root_count(h->roots)", "0"],
      ["i < count", "i + 1 < count"],
      ["rb_ractor_make_shareable(h->program);", "rb_ractor_make_shareable(self);"],
      ["if (h->compiling) rb_raise(rb_eRuntimeError, \"compiling\");", ""]
    ].each do |before, after|
      expect do
        NativeSafety.check_publication(parse(source.gsub(before, after)))
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "results must be rooted before rust publication in each branch" do
    source = <<~C
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

    C
    unit = parse(source)
    NativeSafety.check_result_roots(unit)
    NativeSafety.check_runtime_location_roots(unit)
    ["buffer", "properties", "items"].each do |missing|
      expect do
        NativeSafety.check_runtime_location_roots(parse(source.gsub("rb_ary_push(roots, locations->#{missing});", "")))
      end.to raise_error(NativeSafety::ContractError)
    end
    [
      source.gsub("rb_ary_push(r->messages, result);", ""),
      source.gsub("sn_pointer_result(r->caches, result);", "sn_pointer_result(r->caches, r->messages);"),
      source.gsub("read_runtime_locations(result)", "read_runtime_locations(r->messages)"),
      source.gsub("rbimpl_check_typeddata(result,", "rbimpl_check_typeddata(r->messages,"),
      source.gsub("if (kind == 0)", "if ((sn_message_result(r->caches, result), kind == 0))")
    ].each do |broken|
      expect do
        NativeSafety.check_result_roots(parse(broken))
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "c globals cannot gain handles or ractor shared runtime state" do
    source = type_data + <<~C
      typedef unsigned long ID;
      static ID id_resolve, id_schemurai, id_resolution_error, id_root, id_compile, id_graph;
      static ID id_dynamic_anchor, id_dynamic_anchor_names, id_dynamic_anchor_count;
      static ID identity_methods[5];
      static _Thread_local const void *active_caches;
      static int utf8_index, ascii_index, binary_index;
      static const rb_data_type_t engine_type, runner_type, report_type, report_collector_type, property_locations_type, construction_guard_type;
      static struct { ID id; const char *symbol; } fields[1];
      static struct { ID id; const char *symbol; int opcode; } opcodes[1];

    C
    NativeSafety.check_globals(parse(source))
    [
      source + "static VALUE leaked;",
      source.gsub("_Thread_local ", ""),
      source.gsub("const void *active_caches", "VALUE active_caches"),
      source.gsub("ID id; const char *symbol;", "VALUE id; const char *symbol;")
    ].each do |broken|
      expect do
        NativeSafety.check_globals(parse(broken))
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "snapshot lifecycle rejects early free missing capture and early release" do
    source = <<~C
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

    C
    NativeSafety.check_snapshot_protocol(parse(source))
    [
      ["runner->root_snapshot = next;", "runner->root_snapshot = 0;"],
      ["if (call->status == SN_VERDICT_UNSUPPORTED) refresh_root_snapshot(r);", ""],
      ["sn_caches_begin(runner->caches);", ""],
      ["sn_root_snapshot_free(h->root_snapshot);", "sn_root_snapshot_free(h->caches);"],
      ["if (h->root_snapshot) bytes += sn_root_snapshot_size(h->root_snapshot);", ""]
    ].each do |before, after|
      expect do
        NativeSafety.check_snapshot_protocol(parse(source.gsub(before, after)))
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "construction guard blocks generic ractor publication until success" do
    source = type_data + <<~C
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

    C
    NativeSafety.check_construction_guard(parse(source))
    [
      ["0, 0, RUBY_TYPED_FREE_IMMEDIATELY", "0, 0, RUBY_TYPED_FROZEN_SHAREABLE"],
      ["h->construction_guard = guard;", ""],
      ["if (status != SN_VERDICT_VALID)", "if (status == SN_VERDICT_VALID)"],
      ["rb_raise(rb_eRuntimeError, \"compile failed\");", "return self;"],
      ["holder *h = (holder *)self;", "holder *h = (holder *)self; h->construction_guard = RUBY_Qnil;"]
    ].each do |before, after|
      expect do
        NativeSafety.check_construction_guard(parse(source.gsub(before, after)))
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "json framing fails closed" do
    data = JSON.pretty_generate({"kind" => "TranslationUnitDecl", "inner" => [{"kind" => "FunctionDecl", "name" => "sample"}]}) + "\n"
    expect(NativeSafety.ast_nodes(StringIO.new(data)).to_a[0]["name"]).to eq("sample")
    ["{}", data[...-8], data + "extra"].each do |text|
      expect do
        NativeSafety.ast_nodes(StringIO.new(text)).to_a
      end.to raise_error(NativeSafety::ContractError)
    end
  end

  it "rust imports exclude comments and method wrappers" do
    source = <<~RUST
      // unsafe extern "C" { fn sn_fake(); }
      impl Ruby { unsafe fn sn_wrapper() {} }
      unsafe extern "C" { pub(super) fn sn_leaf(value: Value); }
    RUST
    expect(NativeSafety.rust_imports(source)).to eq(Set["sn_leaf"])
    expect do
      NativeSafety.rust_imports("impl Ruby {}")
    end.to raise_error(NativeSafety::ContractError)
  end
end
