#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/ractor.h>
#include <ruby/st.h>
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include "protocol.h"

static ID id_resolve, id_schemurai, id_resolution_error;
static ID id_root, id_compile, id_graph, id_dynamic_anchor, id_dynamic_anchor_names, id_dynamic_anchor_count;
static ID identity_methods[5];
/* Classification only requests metadata while Rust is active. Ruby method
 * lookup, which can create callable entries, runs after that evaluation exits. */
static _Thread_local const void *active_caches;
extern int sn_identity_kind(const void *, VALUE);
/* Runtime cursors fit the positive Fixnum range, checked by Rust. */
VALUE sn_runtime_ordinal(size_t ordinal) {
    return ((VALUE)ordinal << 1) | RUBY_FIXNUM_FLAG;
}

/* The C layer adapts CRuby APIs to Rust's opaque VALUEs. */
#ifdef HAVE_RB_HASH_STLIKE_FOREACH
/* Exported internal API; extconf checks the symbol and provides a public-API
 * fallback. Its callback below only reads handles under the GVL. */
extern int rb_hash_stlike_foreach(VALUE, st_foreach_callback_func *, st_data_t);
#endif
typedef struct { void *engine; const void *roots; VALUE program; int compiling; } holder;
extern void *sn_new(void);
extern int sn_compile(void *, VALUE, VALUE, int, int, int, VALUE *);
extern int sn_valid(const void *, const void *, size_t, VALUE, size_t);
extern size_t sn_node_index(const void *, VALUE);
extern int sn_callback_kind(const void *, size_t, int *);
extern int sn_reference_context(const void *);
extern void sn_scopes_inherit(const void *, VALUE, VALUE, VALUE, int);
extern size_t sn_references_len(const void *, int);
extern VALUE sn_references_at(const void *, size_t, int);
extern void sn_reference_pair(void *, VALUE, VALUE);
extern int sn_scopes_enabled(const void *);
extern size_t sn_scopes_len(const void *);
extern VALUE sn_scopes_at(const void *, size_t);
extern void sn_scopes_accept(const void *, VALUE);
extern size_t sn_scopes_unwind(const void *);

extern size_t sn_root_index(const void *);
extern int sn_has_unresolved_references(const void *);
extern size_t sn_root_count(const void *);
extern VALUE sn_root_at(const void *, size_t);
extern void *sn_caches_new(void);
extern void sn_caches_free(void *);
extern size_t sn_caches_size(const void *);
extern void sn_caches_runtime(const void *, const void *);
extern int sn_caches_pending(const void *, VALUE *, VALUE *, int *);
extern void sn_caches_mark(const void *);
extern void sn_caches_begin(const void *);
extern void sn_caches_observe(const void *);
extern int sn_caches_take_reorder(const void *);
extern int sn_caches_rescue_regexp(const void *);
extern int sn_caches_frame_error(const void *);
extern size_t sn_pointer_parts(const void *);
extern void sn_pointer_part(const void *, size_t, const unsigned char **, size_t *, VALUE *);
extern void sn_pointer_result(const void *, VALUE);
typedef struct {
    const unsigned char *keyword;
    size_t keyword_len;
    int opcode;
    VALUE operand, instance;
    size_t detail;
    VALUE frame;
} message_arguments;
extern void sn_message_arguments(const void *, message_arguments *);
extern void sn_message_result(const void *, VALUE);
typedef struct { VALUE rules, instance; size_t child; int required, scalar_kind, scalar_flags; } contains_arguments;
extern void sn_contains_arguments(const void *, contains_arguments *);
extern void sn_caches_child(const void *, const void *, int, int);
extern int sn_caches_is_scalar(const void *);
extern int sn_caches_deadline_expired(const void *);
typedef struct { VALUE ordinal, rules, instance; } scalar_arguments;
extern void sn_scalar_arguments(const void *, scalar_arguments *);
extern void sn_free(void *);
extern const void *sn_roots(const void *);
extern void sn_roots_mark(const void *);
extern size_t sn_roots_size(const void *);
extern size_t sn_engine_header_size(void);
extern size_t sn_size(const void *);

static void mark(void *ptr) {
    holder *h = ptr;
    rb_gc_mark(h->program);
    if (h->roots) sn_roots_mark(h->roots);
}
static void release(void *ptr) {
    holder *h = ptr;
    if (h->engine) sn_free(h->engine);
    xfree(h);
}
static size_t size(const void *ptr) {
    const holder *h = ptr;
    return sizeof(*h) + (h->roots ? sn_roots_size(h->roots) : 0)
        + (h->engine ? (h->compiling ? sn_engine_header_size() : sn_size(h->engine)) : 0);
}
static const rb_data_type_t engine_type = {
    "Schemurai::Native::Program", {mark, release, size, NULL, {NULL}},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};
static VALUE allocate(VALUE klass) {
    holder *h;
    VALUE obj = TypedData_Make_Struct(klass, holder, &engine_type, h);
    h->engine = NULL;
    h->roots = NULL;
    h->compiling = 0;
    h->program = Qnil;
    return obj;
}
static VALUE initialize(VALUE self, VALUE program, VALUE compiler, VALUE format, VALUE content) {
    rb_check_frozen(self);
    holder *h;
    TypedData_Get_Struct(self, holder, &engine_type, h);
    if (h->engine) rb_raise(rb_eRuntimeError, "native program is already initialized");
    h->program = program;
    h->engine = sn_new();
    h->roots = sn_roots(h->engine);
    h->compiling = 1;
    VALUE error = Qnil;
    int status = sn_compile(h->engine, program, compiler, RTEST(format), RTEST(content),
        RB_TYPE_P(program, T_ARRAY), &error);
    h->compiling = 0;
    if (status != SN_VERDICT_VALID) {
        sn_free(h->engine);
        h->engine = NULL;
        h->roots = NULL;
        if (status == SN_STATUS_EXCEPTION) rb_exc_raise(error);
        if (status == SN_VERDICT_UNSUPPORTED) rb_raise(rb_eRuntimeError, "native compiler encountered an unsupported instruction or operand");
        rb_raise(rb_eRuntimeError, "native compiler panicked");
    }
    return self;
}
static void check_evaluation_status(int status, const char *panic_message) {
    const char *decimal = NULL;
    switch (status) {
        case SN_STATUS_DECIMAL_NAN: decimal = "NaN"; break;
        case SN_STATUS_DECIMAL_POSITIVE_INFINITY: decimal = "Infinity"; break;
        case SN_STATUS_DECIMAL_NEGATIVE_INFINITY: decimal = "-Infinity"; break;
    }
    if (decimal) rb_raise(rb_eArgError, "invalid value for convert(): \"%s\"", decimal);
    if (status == SN_STATUS_STACK_ERROR) rb_raise(rb_eSysStackError, "stack level too deep");
    if (status < 0) rb_raise(rb_eRuntimeError, "%s", panic_message);
}
static VALUE evaluate_runner(VALUE, VALUE, VALUE, int);
static VALUE build_runner(VALUE, size_t);
/* Search caches and root selection belong to the owning validator. The Ruby
 * owner keeps the shared engine and all its GC roots alive. */
typedef struct { size_t max_errors; uint32_t enabled; double timeout; } native_limits;
typedef struct {
    VALUE owner, parent, active_budget, callback_scope, child_callbacks;
    VALUE scope_state, active_scope_state;
    VALUE report_seed, report_results, error_frame, report_sink;
    VALUE report_state, active_report_state;
    VALUE ref_state, vm_active, active_ref_state, active_vm_state;
    int continuation, scalar_mode, report_sink_done;
    VALUE regexps, limited_regexps, pointers, messages, frames;
    VALUE number_state, limited_number_state, string_state, limited_string_state;
    void *caches;
    size_t root;
    int busy, callback_context, scope_owner, closed_limited;
    int callback_kind, callback_flags;
    native_limits active_limits;
    st_table *matches, *frame_indices;
} runner_holder;
static int mark_match(st_data_t key, st_data_t value, st_data_t context) {
    rb_gc_mark((VALUE)key);
    return ST_CONTINUE;
}
static int mark_pattern_matches(st_data_t key, st_data_t value, st_data_t context) {
    rb_gc_mark((VALUE)key);
    st_foreach((st_table *)value, mark_match, 0);
    return ST_CONTINUE;
}
static int release_matches(st_data_t key, st_data_t value, st_data_t context) {
    st_free_table((st_table *)value);
    return ST_CONTINUE;
}
static int mark_operation(st_data_t key, st_data_t value, st_data_t context) {
    st_foreach((st_table *)value, mark_pattern_matches, 0);
    return ST_CONTINUE;
}
static int release_operation(st_data_t key, st_data_t value, st_data_t context) {
    st_foreach((st_table *)value, release_matches, 0);
    st_free_table((st_table *)value);
    return ST_CONTINUE;
}
static void runner_mark(void *ptr) {
    runner_holder *r = ptr;
    rb_gc_mark(r->owner);
    rb_gc_mark(r->parent);
    rb_gc_mark(r->active_budget);
    rb_gc_mark(r->callback_scope);
    rb_gc_mark(r->child_callbacks);
    rb_gc_mark(r->report_state);
    rb_gc_mark(r->active_report_state);
    rb_gc_mark(r->report_sink);
    rb_gc_mark(r->report_seed);
    rb_gc_mark(r->error_frame);
    rb_gc_mark(r->report_results);
    rb_gc_mark(r->scope_state);
    rb_gc_mark(r->active_scope_state);
    rb_gc_mark(r->ref_state);
    rb_gc_mark(r->vm_active);
    rb_gc_mark(r->active_ref_state);
    rb_gc_mark(r->active_vm_state);
    rb_gc_mark(r->regexps);
    rb_gc_mark(r->limited_regexps);
    rb_gc_mark(r->pointers);
    rb_gc_mark(r->messages);
    rb_gc_mark(r->frames);
    rb_gc_mark(r->number_state);
    rb_gc_mark(r->string_state);
    rb_gc_mark(r->limited_string_state);
    rb_gc_mark(r->limited_number_state);
    if (r->caches) sn_caches_mark(r->caches);
    if (r->matches) st_foreach(r->matches, mark_operation, 0);
}
static void runner_release(void *ptr) {
    runner_holder *h = ptr;
    if (h->caches) sn_caches_free(h->caches);
    if (h->frame_indices) st_free_table(h->frame_indices);
    if (h->matches) {
        st_foreach(h->matches, release_operation, 0);
        st_free_table(h->matches);
    }
    xfree(h);
}
static int match_size(st_data_t key, st_data_t value, st_data_t context) {
    *(size_t *)context += st_memsize((st_table *)value);
    return ST_CONTINUE;
}
static int operation_size(st_data_t key, st_data_t value, st_data_t context) {
    *(size_t *)context += st_memsize((st_table *)value);
    st_foreach((st_table *)value, match_size, context);
    return ST_CONTINUE;
}
static size_t runner_size(const void *ptr) {
    const runner_holder *h = ptr;
    size_t bytes = sizeof(*h) + (h->caches ? sn_caches_size(h->caches) : 0);
    if (h->frame_indices) bytes += st_memsize(h->frame_indices);
    if (h->matches) {
        bytes += st_memsize(h->matches);
        st_foreach(h->matches, operation_size, (st_data_t)&bytes);
    }
    return bytes;
}
/* Numeric-key lookups only: Rust calls this while borrowing instance storage.
 * Table mutations, Ruby calls and allocations happen after Rust returns. */
int sn_cached_runtime(const void *matches, int operation, VALUE source, VALUE instance) {
    st_data_t sources, bucket, result;
    if (st_lookup((st_table *)matches, (st_data_t)operation, &sources)
        && st_lookup((st_table *)sources, (st_data_t)source, &bucket)
        && st_lookup((st_table *)bucket, (st_data_t)instance, &result)) return (int)result;
    return SN_VERDICT_UNSUPPORTED;
}
static const rb_data_type_t runner_type = {
    "Schemurai::Native::Runner", {runner_mark, runner_release, runner_size, NULL, {NULL}},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};
/* Share evaluator caches, never runtime observations or borrowed views.
 * Reentrant independent bounded validations own their limited state. */
static void copy_states(runner_holder *target, const runner_holder *source, int limited, int merge) {
#define COPY_STATE(field) if (!merge || !NIL_P(source->field)) target->field = source->field
    COPY_STATE(regexps);
    COPY_STATE(number_state);
    COPY_STATE(string_state);
    if (limited) {
        COPY_STATE(limited_regexps);
        COPY_STATE(limited_number_state);
        COPY_STATE(limited_string_state);
    }
#undef COPY_STATE
}
static void publish_states(runner_holder *runner) {
    if (!NIL_P(runner->parent)) {
        runner_holder *parent;
        TypedData_Get_Struct(runner->parent, runner_holder, &runner_type, parent);
        copy_states(parent, runner, runner->callback_context, 1);
        publish_states(parent);
    }
}
static holder *ready_program(VALUE self) {
    holder *h;
    TypedData_Get_Struct(self, holder, &engine_type, h);
    if (!h->engine) rb_raise(rb_eRuntimeError, "uninitialized native program");
    if (h->compiling) rb_raise(rb_eRuntimeError, "native program is still compiling");
    return h;
}
static VALUE has_unresolved_references(VALUE self) {
    return sn_has_unresolved_references(ready_program(self)->engine) ? Qtrue : Qfalse;
}
static VALUE make_shareable(VALUE self) {
    holder *h = ready_program(self);
    /* TypedData's hidden references must be shareable too. Freeze temporary
     * compilation arrays as well as the VM programs/graph they retain. */
    size_t count = sn_root_count(h->roots);
    for (size_t i = 0; i < count; i++) rb_ractor_make_shareable(sn_root_at(h->roots, i));
    rb_ractor_make_shareable(h->program);
    return rb_ractor_make_shareable(self);
}
static VALUE runner(VALUE self, VALUE root) {
    holder *h = ready_program(self);
    size_t index = sn_node_index(h->engine, root);
    if (index == SIZE_MAX) rb_raise(rb_eArgError, "root was not compiled in this native program");
    return build_runner(self, index);
}
static VALUE build_runner(VALUE self, size_t index) {
    VALUE klass = rb_const_get(rb_obj_class(self), rb_intern_const("Runner"));
    runner_holder *r;
    VALUE object = TypedData_Make_Struct(klass, runner_holder, &runner_type, r);
    r->owner = self;
    r->parent = Qnil;
    r->active_budget = Qnil;
    r->callback_scope = Qnil;
    r->child_callbacks = Qnil;
    r->report_seed = r->report_results = r->error_frame = r->report_sink = Qnil;
    r->report_state = r->active_report_state = Qnil;
    r->scope_state = Qnil;
    r->active_scope_state = Qnil;
    r->ref_state = r->vm_active = r->active_ref_state = r->active_vm_state = Qnil;
    r->scope_owner = 0;
    r->closed_limited = 0;
    r->callback_kind = SN_CALLBACK_RUNTIME;
    r->callback_flags = 0;
    r->active_limits = (native_limits){0};
    r->busy = 0;
    r->callback_context = 0;
    r->continuation = r->scalar_mode = r->report_sink_done = 0;
    r->regexps = Qnil;
    r->limited_regexps = Qnil;
    r->pointers = Qnil;
    r->messages = Qnil;
    r->frames = Qnil;
    r->number_state = Qnil;
    r->string_state = Qnil;
    r->limited_string_state = Qnil;
    r->limited_number_state = Qnil;
    r->root = index;
    r->caches = NULL;
    r->matches = NULL;
    r->frame_indices = NULL;
    RB_GC_GUARD(self);
    return object;
}
/* Child factories and direct Boolean/type callbacks do not evaluate. Keep
 * their observation state absent until an execution or invocation scope needs it. */
static void prepare_runner(runner_holder *r) {
    if (r->caches) return;
    if (!r->frame_indices) r->frame_indices = st_init_numtable();
    if (!r->matches) r->matches = st_init_numtable();
    r->caches = sn_caches_new();
    sn_caches_runtime(r->caches, r->matches);
}
typedef struct { uint32_t kind; size_t attempted; } native_outcome;
extern int sn_valid_with_limits(const void *, const void *, size_t, VALUE, size_t, const native_limits *, native_outcome *);
static native_limits read_limits(VALUE budget) {
    native_limits limits = {0};
    VALUE cap = rb_funcall(budget, rb_intern("native_max_errors"), 0);
    if (!NIL_P(cap)) { limits.max_errors = NUM2SIZET(cap); limits.enabled |= 1; }
    VALUE duration = rb_funcall(budget, rb_intern("native_duration"), 0);
    if (!NIL_P(duration)) { limits.timeout = NUM2DBL(duration); limits.enabled |= 2; }
    RB_GC_GUARD(cap);
    return limits;
}
static void finish_budget(VALUE budget, const native_outcome *outcome) {
    if (outcome->kind) rb_funcall(budget, rb_intern("raise_native_limit"), 2, UINT2NUM(outcome->kind), SIZET2NUM(outcome->attempted));
}
static VALUE runner_valid_with_budget(VALUE self, VALUE instance, VALUE budget) {
    return evaluate_runner(self, instance, budget, 0);
}
static VALUE runner_valid(VALUE self, VALUE instance) {
    return evaluate_runner(self, instance, Qnil, 0);
}
static VALUE runner_share_scalar_state(VALUE self, VALUE number_state, VALUE regexps, VALUE scopes, VALUE references, VALUE active, VALUE reports) {
    runner_holder *runner;
    TypedData_Get_Struct(self, runner_holder, &runner_type, runner);
    if (runner->busy) rb_raise(rb_eRuntimeError, "cannot replace active scalar state");
    Check_Type(scopes, T_ARRAY);
    runner->scope_state = scopes;
    Check_Type(reports, T_ARRAY);
    runner->report_state = reports;
    Check_Type(references, T_ARRAY);
    Check_Type(active, T_HASH);
    runner->ref_state = references;
    runner->vm_active = active;
    runner->number_state = number_state;
    runner->regexps = regexps;
    runner->string_state = Qnil;
    return self;
}
/* Library-owned identity maps: these callbacks only copy VALUE pairs to Rust.
 * No Ruby allocation, dispatch or mutation occurs while Rust borrows its Vec. */
typedef struct { void *pairs; VALUE program; } reference_walk;
static int reference_instance(VALUE instance, VALUE unused, VALUE context) {
    reference_walk *walk = (reference_walk *)context;
    sn_reference_pair(walk->pairs, walk->program, instance);
    return ST_CONTINUE;
}
static int reference_program(VALUE program, VALUE instances, VALUE context) {
    reference_walk walk = {(void *)context, program};
    rb_hash_foreach(instances, reference_instance, (VALUE)&walk);
    return ST_CONTINUE;
}
void sn_references_read(VALUE active, void *pairs) {
    if (!NIL_P(active)) rb_hash_foreach(active, reference_program, (VALUE)pairs);
}
static VALUE runner_reference_active(VALUE self, VALUE program, VALUE instance) {
    runner_holder *runner;
    TypedData_Get_Struct(self, runner_holder, &runner_type, runner);
    if (NIL_P(runner->ref_state)) return Qfalse;
    for (long i = 0; i < RARRAY_LEN(runner->ref_state); i += 2)
        if (rb_ary_entry(runner->ref_state, i) == program &&
            rb_ary_entry(runner->ref_state, i + 1) == instance) return Qtrue;
    return Qfalse;
}
static VALUE valid(VALUE self, VALUE instance) {
    holder *h = ready_program(self);
    VALUE run = build_runner(self, sn_root_index(h->engine));
    return runner_valid(run, instance);
}
void sn_pin(VALUE value) { rb_gc_mark(value); }
VALUE sn_nil(void) { return Qnil; }
VALUE sn_undefined(void) { return Qundef; }
static int ordinary_key(VALUE key, VALUE value, VALUE context) {
    int *ordinary = (int *)context;
    if (!RB_TYPE_P(key, T_STRING) || CLASS_OF(key) != rb_cString) {
        *ordinary = 0;
        return ST_STOP;
    }
    return ST_CONTINUE;
}
int sn_shallow_kind(VALUE value) {
    if (NIL_P(value)) return SN_TYPE_NULL;
    if (value == Qtrue || value == Qfalse) return SN_TYPE_BOOLEAN;
    if (RB_TYPE_P(value, T_HASH)) {
        if (CLASS_OF(value) != rb_cHash) return SN_TYPE_UNSUPPORTED;
        return SN_TYPE_OBJECT;
    }
    if (RB_TYPE_P(value, T_ARRAY)) return CLASS_OF(value) == rb_cArray ? SN_TYPE_ARRAY : SN_TYPE_UNSUPPORTED;
    if (RB_INTEGER_TYPE_P(value)) return SN_TYPE_NUMBER | SN_TYPE_INTEGER;
    if (RB_TYPE_P(value, T_FLOAT)) {
        double n = RFLOAT_VALUE(value);
        return SN_TYPE_NUMBER | ((isfinite(n) && trunc(n) == n) ? SN_TYPE_INTEGER : 0);
    }
    if (RB_TYPE_P(value, T_STRING)) return CLASS_OF(value) == rb_cString ? SN_TYPE_STRING : SN_TYPE_UNSUPPORTED;
    /* Ordinary Object and Symbol equality is identity. Singleton classes still
     * retain runtime dispatch, including custom equality/hash/type methods. */
    if ((RB_SYMBOL_P(value) && CLASS_OF(value) == rb_cSymbol) || CLASS_OF(value) == rb_cObject)
        return sn_identity_kind(active_caches, CLASS_OF(value));
    return SN_TYPE_UNSUPPORTED; /* Unusual objects request Ruby predicates or value primitives. */
}
int sn_kind(VALUE value) {
    int kind = sn_shallow_kind(value);
    if (kind != SN_TYPE_OBJECT) return kind;
    /* Lookup paths check every key before calling Ruby's hash API. A record
     * walk instead checks keys as it visits them and uses native lookups. */
    int ordinary = 1;
#ifdef HAVE_RB_HASH_STLIKE_FOREACH
    /* This guard only checks classes; it cannot mutate or invoke Ruby. */
    rb_hash_stlike_foreach(value, ordinary_key, (st_data_t)&ordinary);
#else
    rb_hash_foreach(value, ordinary_key, (VALUE)&ordinary);
#endif
    return ordinary ? SN_TYPE_OBJECT : SN_TYPE_UNSUPPORTED;
}
/* Classification and borrowed storage for structural fingerprints. Hash
 * keys are checked by the iterator; no preliminary key walk occurs here.
 * The caller keeps the GVL and must not allocate Ruby objects or call Ruby.
 * Only Array/String initialize data and length; Hash/Boolean initialize
 * length; Float (kind SN_TYPE_NUMBER) initializes number. Other kinds write no outputs. */
int sn_fingerprint_view(VALUE value, const void **data, size_t *length, double *number) {
    if (RB_TYPE_P(value, T_ARRAY)) {
        if (CLASS_OF(value) != rb_cArray) return SN_TYPE_UNSUPPORTED;
        *data = RARRAY_CONST_PTR(value);
        *length = RARRAY_LEN(value);
        return SN_TYPE_ARRAY;
    }
    if (RB_TYPE_P(value, T_STRING)) {
        if (CLASS_OF(value) != rb_cString) return SN_TYPE_UNSUPPORTED;
        *data = RSTRING_PTR(value);
        *length = RSTRING_LEN(value);
        return SN_TYPE_STRING;
    }
    if (RB_TYPE_P(value, T_HASH)) {
        if (CLASS_OF(value) != rb_cHash) return SN_TYPE_UNSUPPORTED;
        *length = RHASH_SIZE(value);
        return SN_TYPE_OBJECT;
    }
    if (RB_TYPE_P(value, T_FLOAT)) {
        *number = RFLOAT_VALUE(value);
        return SN_TYPE_NUMBER;
    }
    int kind = sn_shallow_kind(value);
    if (kind == SN_TYPE_BOOLEAN) {
        *length = value == Qtrue;
    }
    return kind;
}
struct small_hash { VALUE *entries; int count; };
static int small_entry(VALUE key, VALUE value, VALUE context) {
    struct small_hash *h = (struct small_hash *)context;
    if (!RB_TYPE_P(key, T_STRING) || CLASS_OF(key) != rb_cString) {
        h->count = -1;
        return ST_STOP;
    }
    h->entries[2 * h->count] = key;
    h->entries[2 * h->count + 1] = value;
    h->count++;
    return ST_CONTINUE;
}
/* Only opaque borrowed handles go into a fixed stack buffer. No Ruby object,
 * instance tree, string, or number is copied or converted for Rust. */
int sn_small_hash(VALUE value, VALUE *entries) {
    if (RHASH_SIZE(value) > 8) return SN_SMALL_HASH_TOO_LARGE;
    struct small_hash h = {entries, 0};
#ifdef HAVE_RB_HASH_STLIKE_FOREACH
    rb_hash_stlike_foreach(value, small_entry, (st_data_t)&h);
#else
    rb_hash_foreach(value, small_entry, (VALUE)&h);
#endif
    if (h.count < 0) return h.count;
#ifdef SCHEMURAI_AR_HASH_PROOF
    /* Build-time verified CRuby 3.4/4.0 hint: identity Hashes use ST tables.
     * Only the public object flags are read; no private table is dereferenced.
     * Bit 4 tags ordinary semantics, independently of the initialized count. */
    if (!RB_FL_TEST_RAW(value, RUBY_FL_USER3)) return h.count | SN_SMALL_HASH_ORDINARY;
#endif
    return h.count;
}
int sn_true(VALUE value) { return value == Qtrue; }
int sn_truthy(VALUE value) { return RTEST(value); }
VALUE sn_fixnum_flag(void) {
    /* Enable direct immediate decoding only for the header encoding Rust
     * understands. Zero disables its hints and retains the public adapters. */
    if (sizeof(VALUE) <= sizeof(int64_t) && sizeof(VALUE) == sizeof(intptr_t)
        && RUBY_FIXNUM_FLAG == 1 && INT2FIX(0) == 1 && INT2FIX(1) == 3
        && INT2FIX(-1) == (VALUE)-1)
        return RUBY_FIXNUM_FLAG;
    return 0;
}
const VALUE *sn_array_data(VALUE value) { return RARRAY_CONST_PTR(value); }
int sn_fixnum(VALUE value) { return FIXNUM_P(value); }
int64_t sn_integer(VALUE value) { return FIX2LONG(value); }
/* Arithmetic operands only: no Ruby allocation, coercion, or instance tree copy.
 * Callers check INTEGER_TYPE before using this bounded scalar adapter. */
int sn_integer128(VALUE value, uint64_t *words) {
    return rb_integer_pack(value, words, 2, sizeof(uint64_t), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
}
/* Runtime callers already checked ordinary Integer. Magnitudes above 128 bits
 * lie outside every bounded fraction limit, so bounds need their sign only.
 * Read public metadata instead of exporting truncated magnitude words. */
int sn_integer_bounds128(VALUE value, uint64_t *words) {
    if (FIXNUM_P(value)) {
        int64_t n = FIX2LONG(value);
        words[0] = n < 0 ? 0 - (uint64_t)n : (uint64_t)n;
        words[1] = 0;
        return (n > 0) - (n < 0);
    }
    if (RB_TYPE_P(value, T_BIGNUM) && rb_absint_size(value, NULL) > 16)
        return rb_big_sign(value) ? 2 : -2;
    return sn_integer128(value, words);
}
/* One ordinary-kind check plus Integer metadata or a Float scalar. Return 3 for
 * Float/non-number input. Float initializes floating; Integer initializes words
 * only when the returned sign has absolute value at most one. All paths set kind. */
int sn_number_bounds_view(VALUE value, uint64_t *words, int *kind, double *floating, int required) {
    if (RB_TYPE_P(value, T_FLOAT)) {
        double n = RFLOAT_VALUE(value);
        *floating = n;
        *kind = SN_TYPE_NUMBER;
        /* Integer membership is only needed when the required mask excludes
         * general numbers. Keep NaN/Infinity outside the Integer domain. */
        if ((required & SN_TYPE_INTEGER) && !(required & SN_TYPE_NUMBER) && isfinite(n) && trunc(n) == n)
            *kind |= SN_TYPE_INTEGER;
        return SN_ADAPTER_UNSUPPORTED;
    }
    if (RB_TYPE_P(value, T_BIGNUM)) {
        *kind = SN_TYPE_INTEGRAL_NUMBER;
        if (rb_absint_size(value, NULL) > 16)
            return rb_big_sign(value) ? 2 : -2;
        return sn_integer128(value, words);
    }
    if (FIXNUM_P(value)) {
        *kind = SN_TYPE_INTEGRAL_NUMBER;
        return sn_integer_bounds128(value, words);
    }
    *kind = sn_kind(value);
    return SN_ADAPTER_UNSUPPORTED;
}
/* Restricted to ordinary integers: rb_big_eql compares existing digits and
 * never enters the allocating/coercing integer-versus-Float comparison path. */
int sn_big_equal(VALUE big, VALUE other) { return RTEST(rb_big_eql(big, other)); }
/* Compare only existing Big/Big digits. The Fixnum branch of rb_big_cmp can
 * normalize its left operand, and Float/coercion branches can allocate. */
int sn_big_order(VALUE left, VALUE right) {
    if (!RB_TYPE_P(left, T_BIGNUM) || !RB_TYPE_P(right, T_BIGNUM)) return SN_ADAPTER_UNSUPPORTED;
    return FIX2INT(rb_big_cmp(left, right));
}
/* The bound is an ordinary Integer outside i128. A Fixnum is therefore
 * ordered by the bound's sign. Only Big/Big reaches rb_big_cmp: its Fixnum
 * branch can resize the left operand, and its Float branch allocates. */
int sn_wide_integer_compare(VALUE value, VALUE bound) {
    if (FIXNUM_P(value)) return rb_big_sign(bound) ? -1 : 1;
    return FIX2INT(rb_big_cmp(value, bound));
}
int sn_integer1024(VALUE value, uint64_t *words) {
    return rb_integer_pack(value, words, 16, sizeof(uint64_t), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
}
/* Ordinary Integer scalar operands only. These public adapters neither invoke
 * Ruby methods nor allocate Ruby objects, so borrowed container views stay valid. */
size_t sn_integer_word_count(VALUE value) {
    return rb_absint_numwords(value, 64, NULL);
}
int sn_integer_words(VALUE value, uint64_t *words, size_t count) {
    return rb_integer_pack(value, words, count, sizeof(uint64_t), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
}
int sn_is_bignum(VALUE value) { return RB_TYPE_P(value, T_BIGNUM); }
/* CRuby's rb_hash dispatches T_BIGNUM directly to its digit hash and returns
 * a Fixnum: no Ruby method dispatch or allocation. Never pass other types,
 * whose hash implementation may call Ruby while the array view is borrowed. */
int sn_big_hash(VALUE value, uint64_t *hash) {
    if (!RB_TYPE_P(value, T_BIGNUM)) return 0;
    *hash = (uint64_t)FIX2LONG(rb_hash(value));
    return 1;
}
/* Return low 32-bit magnitude metadata plus sign in bit 32. Bit 33 rejects
 * other kinds before public integer packing. Overflow retains the low word;
 * exact original-handle comparisons and wider retries decide uniqueness. */
uint64_t sn_big_low_word(VALUE value) {
    if (!RB_TYPE_P(value, T_BIGNUM)) return UINT64_C(1) << 33;
    uint32_t low;
    int sign = rb_integer_pack(value, &low, 1, sizeof(low), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
    return (uint64_t)low | ((uint64_t)(sign < 0) << 32);
}
int sn_big_low64_word(VALUE value, uint64_t *word) {
    if (!RB_TYPE_P(value, T_BIGNUM)) return SN_ADAPTER_UNSUPPORTED;
    return rb_integer_pack(value, word, 1, sizeof(uint64_t), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
}
int sn_big256(VALUE value, uint64_t *words) {
    /* 3 means the checked hint did not apply; no coercion or allocation. */
    if (!RB_TYPE_P(value, T_BIGNUM)) return SN_ADAPTER_UNSUPPORTED;
    return rb_integer_pack(value, words, 4, sizeof(uint64_t), 0,
        INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
}
int sn_is_float(VALUE value) { return RB_TYPE_P(value, T_FLOAT); }
int sn_is_rational(VALUE value) { return RB_TYPE_P(value, T_RATIONAL); }
double sn_float(VALUE value) { return RFLOAT_VALUE(value); }
static int utf8_index, ascii_index, binary_index;
static size_t string_length(VALUE value) {
    int encoding = RB_ENCODING_GET(value);
    if (encoding == binary_index
        || ((encoding == utf8_index || encoding == ascii_index)
            && RB_ENC_CODERANGE(value) == RUBY_ENC_CODERANGE_7BIT))
        return RSTRING_LEN(value);
    return rb_str_strlen(value);
}
size_t sn_len(VALUE value) {
    if (RB_TYPE_P(value, T_ARRAY)) return RARRAY_LEN(value);
    if (RB_TYPE_P(value, T_HASH)) return RHASH_SIZE(value);
    return string_length(value);
}
VALUE sn_entry(VALUE array, size_t index) { return rb_ary_entry(array, index); }
VALUE sn_lookup(VALUE hash, VALUE key) { return rb_hash_lookup2(hash, key, Qundef); }
int sn_missing(VALUE value) { return value == Qundef; }
int sn_same(VALUE a, VALUE b) { return a == b; }
int sn_same_class(VALUE a, VALUE b) { return CLASS_OF(a) == CLASS_OF(b); }
int sn_string_equal(VALUE a, VALUE b) { return rb_str_cmp(a, b) == 0; }

static struct { ID id; const char *symbol; } fields[] = {
#define SN_OPCODE(name, symbol, value)
#define SN_CONSTANT(name, value)
#define SN_FIELD(name, symbol, value) [SN_FIELD_##name] = {0, symbol},
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
#undef SN_FIELD
};
struct access { VALUE object; ID name; };
static VALUE get_field(VALUE arg) {
    struct access *a = (struct access *)arg;
    return rb_funcall(a->object, a->name, 0);
}
/* Rust supplies an accessor index from the shared protocol. */
int sn_field(VALUE object, int name, VALUE *value) {
    struct access a = {object, fields[name].id};
    int state = 0;
    *value = rb_protect(get_field, (VALUE)&a, &state);
    if (state) { *value = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
static struct { ID id; const char *symbol; int opcode; } opcodes[] = {
#define SN_OPCODE(name, symbol, value) {0, #symbol, SN_OP_##name},
#define SN_CONSTANT(name, value)
#define SN_FIELD(name, symbol, value)
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
#undef SN_FIELD
};
int sn_opcode(VALUE symbol) {
    ID id = SYM2ID(symbol);
    for (size_t i = 0; i < sizeof(opcodes) / sizeof(opcodes[0]); i++)
        if (id == opcodes[i].id) return opcodes[i].opcode;
    return SN_OPCODE_UNKNOWN;
}
/* Copy only the schema map's entry handles; instances are never copied. */
static int append_pair(VALUE key, VALUE value, VALUE array) {
    rb_ary_push(array, key);
    rb_ary_push(array, value);
    return ST_CONTINUE;
}
static VALUE pairs(VALUE hash) {
    VALUE array = rb_ary_new();
    rb_hash_foreach(hash, append_pair, array);
    return array;
}
int sn_pairs(VALUE hash, VALUE *value) {
    int state = 0;
    *value = rb_protect(pairs, hash, &state);
    if (state) { *value = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
static VALUE key_copy(VALUE key) { return rb_str_dup(key); }
int sn_key_copy(VALUE key, VALUE *value) {
    int state = 0;
    *value = rb_protect(key_copy, key, &state);
    if (state) { *value = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
/* Output records are built only after Rust traversal has returned. The report
 * is owned by TypedData so exceptions and GC cannot leak it or move its VALUEs. */
typedef struct {
    const unsigned char *keyword;
    size_t keyword_len;
    const unsigned char *instance_path;
    size_t instance_len;
    const unsigned char *schema_path;
    size_t schema_len;
    VALUE instance_pointer, schema_pointer;
    int opcode;
    VALUE operand, instance;
    size_t detail;
    VALUE message;
} diagnostic_record;
typedef struct { void *report; } report_holder;
typedef struct { VALUE buffer, properties, items; } runtime_locations;
extern void *sn_diagnose(const void *, const void *, size_t, VALUE, int *);
extern void *sn_diagnose_with_limits(const void *, const void *, size_t, VALUE, int *, const native_limits *, native_outcome *);
extern size_t sn_report_len(const void *);
extern size_t sn_report_size(const void *);
extern void sn_report_record(const void *, size_t, diagnostic_record *);
extern void sn_report_mark(const void *);
extern void sn_report_free(void *);
extern void *sn_report_seed(const void *);
extern void sn_report_inherit(const void *, const void *);
extern void sn_report_accept(const void *, const void *);
static void report_mark(void *ptr) {
    report_holder *h = ptr;
    if (h->report) sn_report_mark(h->report);
}
static void report_release(void *ptr) {
    report_holder *h = ptr;
    if (h->report) sn_report_free(h->report);
    xfree(h);
}
static size_t report_size(const void *ptr) {
    const report_holder *h = ptr;
    return sizeof(*h) + (h->report ? sn_report_size(h->report) : 0);
}
static const rb_data_type_t report_type = {
    "Schemurai::Native::Diagnostics", {report_mark, report_release, report_size, NULL, {NULL}},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};
typedef struct {
    VALUE self, instance, budget;
    runner_holder *runner;
    holder *engine;
    report_holder *report;
    int status;
    native_limits limits;
    int limits_read;
    int diagnostics;
} evaluation_call;

/* Retained Ruby blocks keep their evaluator cache scope. Bounded calls own
 * their caches; unbounded scopes continue sharing the runner's persistent state. */
static void close_callback_scope(runner_holder *runner) {
    if (NIL_P(runner->callback_scope)) return;
    runner_holder *scope;
    TypedData_Get_Struct(runner->callback_scope, runner_holder, &runner_type, scope);
    if (!NIL_P(scope->active_budget)) {
        scope->parent = Qnil;
        scope->closed_limited = 1;
        scope->regexps = Qnil;
        scope->number_state = Qnil;
        scope->string_state = Qnil;
    }
    scope->active_budget = Qnil;
    scope->active_limits = (native_limits){0};
    scope->callback_context = 0;
    sn_caches_begin(scope->caches);
    runner->callback_scope = Qnil;
}
static VALUE clear_runtime(VALUE context) {
    evaluation_call *call = (evaluation_call *)context;
    st_foreach(call->runner->matches, release_operation, 0);
    st_clear(call->runner->matches);
    call->runner->report_results = Qnil;
    call->runner->pointers = Qnil;
    call->runner->messages = Qnil;
    call->runner->frames = Qnil;
    call->runner->limited_number_state = Qnil;
    call->runner->limited_string_state = Qnil;
    call->runner->limited_regexps = Qnil;
    st_clear(call->runner->frame_indices);
    sn_caches_runtime(call->runner->caches, call->runner->matches);
    sn_caches_begin(call->runner->caches);
    return Qnil;
}
/* Rust owns scope snapshots; the Ruby Array is the evaluator's live scope.
 * Publishing happens only after native frames and scope-vector loans unwind. */
static void publish_scope(runner_holder *runner) {
    if (!sn_scopes_enabled(runner->caches)) return;
    size_t count = sn_scopes_len(runner->caches);
    int same = (size_t)RARRAY_LEN(runner->active_scope_state) == count;
    for (size_t i = 0; same && i < count; i++)
        same = rb_ary_entry(runner->active_scope_state, i) == sn_scopes_at(runner->caches, i);
    if (same) return;
    if (!count) { rb_ary_clear(runner->active_scope_state); return; }
    VALUE state = rb_ary_new_capa(count);
    for (size_t i = 0; i < count; i++) rb_ary_push(state, sn_scopes_at(runner->caches, i));
    rb_ary_replace(runner->active_scope_state, state);
    RB_GC_GUARD(state);
}
static void publish_references(runner_holder *runner, int initial) {
    if (!sn_scopes_enabled(runner->caches)) return;
    size_t count = sn_references_len(runner->caches, initial);
    int same = (size_t)RARRAY_LEN(runner->active_ref_state) == count;
    for (size_t i = 0; same && i < count; i++)
        same = rb_ary_entry(runner->active_ref_state, i) == sn_references_at(runner->caches, i, initial);
    if (same) return;
    if (!count) { rb_ary_clear(runner->active_ref_state); return; }
    VALUE state = rb_ary_new_capa(count);
    for (size_t i = 0; i < count; i++) rb_ary_push(state, sn_references_at(runner->caches, i, initial));
    rb_ary_replace(runner->active_ref_state, state);
    RB_GC_GUARD(state);
}
static void evaluate_native(evaluation_call *call) {
    runner_holder *r = call->runner;
    native_outcome outcome = {0};
    if (!NIL_P(call->budget) && !call->limits_read) {
        call->limits = read_limits(call->budget);
        call->limits_read = 1;
    }
    r->active_limits = call->limits;
    const void *previous_caches = active_caches;
    active_caches = r->caches;
    if (call->report) {
        if (NIL_P(call->budget)) {
            call->report->report = sn_diagnose(call->engine->engine, r->caches, r->root,
                call->instance, &call->status);
        } else {
            call->report->report = sn_diagnose_with_limits(call->engine->engine, r->caches, r->root,
                call->instance, &call->status, &call->limits, &outcome);
        }
    } else if (NIL_P(call->budget)) {
        call->status = sn_valid(call->engine->engine, r->caches, r->root, call->instance, 0);
    } else {
        call->status = sn_valid_with_limits(call->engine->engine, r->caches, r->root,
            call->instance, 0, &call->limits, &outcome);
    }
    active_caches = previous_caches;
    publish_scope(r);
    publish_references(r, 0);
    check_evaluation_status(call->status,
        call->report ? "native diagnostics panicked" : "native evaluator panicked");
    if (!NIL_P(call->budget)) finish_budget(call->budget, &outcome);
}
static VALUE callback_scope(evaluation_call *call) {
    runner_holder *runner = call->runner;
    /* Nested callbacks share the original public invocation's budget lifetime.
     * Returning from one child must not close a block its caller retained. */
    if (runner->callback_context) {
        VALUE object = runner->parent;
        while (!NIL_P(object)) {
            runner_holder *scope;
            TypedData_Get_Struct(object, runner_holder, &runner_type, scope);
            if (scope->scope_owner) return object;
            object = scope->parent;
        }
        rb_raise(rb_eRuntimeError, "native callback lost its invocation scope");
    }
    if (NIL_P(runner->callback_scope)) {
        VALUE object = build_runner(runner->owner, runner->root);
        runner_holder *scope;
        TypedData_Get_Struct(object, runner_holder, &runner_type, scope);
        scope->parent = call->self;
        scope->scope_owner = 1;
        scope->scope_state = runner->active_scope_state;
        scope->report_state = runner->active_report_state;
        scope->ref_state = runner->active_ref_state;
        scope->vm_active = runner->active_vm_state;
        scope->callback_context = 1;
        scope->active_budget = call->budget;
        scope->active_limits = call->limits;
        copy_states(scope, runner, 1, 0);
        prepare_runner(scope);
        sn_caches_child(scope->caches, runner->caches, !NIL_P(call->budget), 1);
        runner->callback_scope = object;
    }
    return runner->callback_scope;
}
extern void *sn_report_clone(const void *);
extern void *sn_report_partial(const void *);
extern void *sn_report_callback_seed(const void *);
extern void *sn_report_live(const void *);
extern void sn_report_effect(const void *, const void *);
extern void *sn_callback_report_result(const void *, int);
extern void *sn_report_interrupted(const void *);
extern void *sn_array_report_child(const void *, size_t, const unsigned char *, size_t, size_t, int);
extern void *sn_array_report_error(const void *, const void *, size_t, VALUE, int, VALUE);
extern int sn_array_report_adopt(void *, const void *);
extern void sn_array_report_record(void *, size_t);
extern int sn_array_report_contains(const void *, size_t, int);
extern int sn_report_silent(const void *);
extern void sn_report_child_validity(void *, int);
extern void sn_report_clear_collection(void *, int);
extern void *sn_report_context(int, size_t, VALUE, VALUE);
extern size_t sn_report_context_count(const void *, size_t);
extern int sn_report_context_reset(const void *);
extern int sn_report_verdict(const void *);
extern void sn_array_report_finish(void *, int);
extern void sn_container_report_finish(void *, int, const runtime_locations *);
extern VALUE sn_report_items_set(const void *, int);
extern void sn_caches_reuse_buffers(const void *);
/* Mutable accumulation never spans Ruby calls. While Rust mutates the report,
 * immutable seeds/results retain every Ruby handle for stopped-Ractor GC. */
typedef struct {
    VALUE owner, scope, seed, results, instance, self;
    size_t node;
    void *report;
    int busy;
} report_collector;
static void report_collector_mark(void *ptr) {
    report_collector *c = ptr;
    rb_gc_mark(c->owner); rb_gc_mark(c->scope); rb_gc_mark(c->seed);
    rb_gc_mark(c->results); rb_gc_mark(c->instance);
    if (c->report && !c->busy) sn_report_mark(c->report);
}
static void report_collector_free(void *ptr) {
    report_collector *c = ptr;
    if (c->report) sn_report_free(c->report);
    xfree(c);
}
static size_t report_collector_size(const void *ptr) {
    const report_collector *c = ptr;
    return sizeof(*c) + (c->report && !c->busy ? sn_report_size(c->report) : 0);
}
static const rb_data_type_t report_collector_type = {
    "Schemurai::Native::ReportCollector", {report_collector_mark, report_collector_free, report_collector_size, NULL, {NULL}},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};
static report_collector *get_report_collector(VALUE self) {
    report_collector *c;
    TypedData_Get_Struct(self, report_collector, &report_collector_type, c);
    return c;
}
static VALUE collector_report_object(void) {
    report_holder *h;
    VALUE object = TypedData_Make_Struct(rb_cObject, report_holder, &report_type, h);
    h->report = NULL;
    return object;
}
static VALUE collector_runner(report_collector *c, size_t node, VALUE seed, VALUE error_frame) {
    runner_holder *scope;
    TypedData_Get_Struct(c->scope, runner_holder, &runner_type, scope);
    if (scope->closed_limited) rb_funcall(Qnil, rb_intern_const("checkpoint"), 0);
    if (scope->scope_owner && !NIL_P(scope->parent)) {
        runner_holder *owner;
        TypedData_Get_Struct(scope->parent, runner_holder, &runner_type, owner);
        copy_states(scope, owner, !NIL_P(scope->active_budget), 0);
    }
    VALUE callback = build_runner(c->owner, node);
    runner_holder *r;
    TypedData_Get_Struct(callback, runner_holder, &runner_type, r);
    r->parent = c->scope;
    r->callback_context = r->continuation = r->scalar_mode = 1;
    r->report_seed = seed;
    r->error_frame = error_frame;
    return callback;
}
static VALUE collector_run(report_collector *c, size_t node, VALUE instance, VALUE seed, VALUE error_frame, int mode, VALUE sink) {
    VALUE callback = collector_runner(c, node, seed, error_frame);
    if (!NIL_P(sink)) {
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->report_sink = sink;
    }
    runner_holder *scope;
    TypedData_Get_Struct(c->scope, runner_holder, &runner_type, scope);
    VALUE result = evaluate_runner(callback, instance, scope->active_budget, mode);
    if (NIL_P(result)) rb_raise(rb_eRuntimeError, "native container child lost its coverage proof");
    RB_GC_GUARD(seed); RB_GC_GUARD(error_frame); RB_GC_GUARD(callback);
    return result;
}
static size_t collector_node(report_collector *c, VALUE program) {
    size_t node = sn_node_index(ready_program(c->owner)->engine, program);
    if (node == SIZE_MAX) rb_raise(rb_eRuntimeError, "native container child was not compiled");
    return node;
}
static int collector_adopt(report_collector *c, VALUE result) {
    rb_ary_push(c->results, result);
    report_holder *h;
    TypedData_Get_Struct(result, report_holder, &report_type, h);
    c->busy = 1;
    int verdict = sn_array_report_adopt(c->report, h->report);
    c->busy = 0;
    return verdict;
}
static VALUE collector_evaluate(VALUE self, VALUE program, VALUE instance, VALUE index, VALUE keyword, VALUE child_segment) {
    report_collector *c = get_report_collector(self);
    size_t node = collector_node(c, program);
    if (sn_report_silent(c->report)) return collector_run(c, node, instance, Qnil, Qnil, 0, Qnil);
    size_t at = NUM2SIZET(index), child = NIL_P(child_segment) ? SIZE_MAX : NUM2SIZET(child_segment);
    StringValue(keyword);
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_array_report_child(c->report, at, (const unsigned char *)RSTRING_PTR(keyword), RSTRING_LEN(keyword), child, 0);
    VALUE result = collector_run(c, node, instance, seed_object, Qnil, 2, c->self);
    int verdict = collector_adopt(c, result);
    report_holder *completed;
    TypedData_Get_Struct(result, report_holder, &report_type, completed);
    if (sn_report_context_reset(completed->report) == 1) {
        /* This child seed owns the evaluate_at path scope. Public validity
         * reentry cleared its buffers, so run the original Ruby ensure pops. */
        int pops = NIL_P(child_segment) ? 2 : 3;
        while (pops-- > 0) rb_funcall(Qnil, rb_intern_const("pop"), 0);
    }
    RB_GC_GUARD(self); RB_GC_GUARD(seed_object); RB_GC_GUARD(keyword); RB_GC_GUARD(result);
    return verdict == SN_VERDICT_VALID ? Qtrue : Qfalse;
}
static VALUE collector_trial(VALUE self, VALUE program, VALUE instance) {
    report_collector *c = get_report_collector(self);
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_array_report_child(c->report, 0, NULL, 0, SIZE_MAX, 1);
    VALUE result = collector_run(c, collector_node(c, program), instance, seed_object, Qnil, 2, Qnil);
    report_holder *completed;
    TypedData_Get_Struct(result, report_holder, &report_type, completed);
    int verdict = sn_report_verdict(completed->report);
    RB_GC_GUARD(self); RB_GC_GUARD(seed_object); RB_GC_GUARD(result);
    return verdict == SN_VERDICT_VALID ? Qtrue : Qfalse;
}
static VALUE collector_error(VALUE self, VALUE keyword, VALUE frame) {
    report_collector *c = get_report_collector(self);
    const char *name = StringValueCStr(keyword);
    int kind;
    if (!strcmp(name, "type")) kind = 0;
    else if (!strcmp(name, "maxItems")) kind = 1;
    else if (!strcmp(name, "minItems")) kind = 2;
    else if (!strcmp(name, "uniqueItems")) kind = 3;
    else if (!strcmp(name, "contains")) kind = 4;
    else rb_raise(rb_eArgError, "unknown array diagnostic");
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_array_report_error(c->report, ready_program(c->owner)->engine,
        c->node, c->instance, kind, INT2FIX(0));
    VALUE result = collector_run(c, c->node, c->instance, seed_object, frame, 2, c->self);
    collector_adopt(c, result);
    RB_GC_GUARD(self); RB_GC_GUARD(seed_object); RB_GC_GUARD(result);
    return Qnil;
}
static VALUE collector_record(VALUE self, VALUE index) {
    report_collector *c = get_report_collector(self);
    size_t at = NUM2SIZET(index);
    c->busy = 1;
    sn_array_report_record(c->report, at);
    c->busy = 0;
    return self;
}
static VALUE collector_contains(VALUE self, VALUE index, VALUE prior) {
    report_collector *c = get_report_collector(self);
    VALUE set = sn_report_items_set(c->report, RTEST(prior));
    if (!NIL_P(set)) return rb_funcall(set, rb_intern_const("include?"), 1, index);
    return sn_array_report_contains(c->report, NUM2SIZET(index), RTEST(prior)) ? Qtrue : Qfalse;
}
static VALUE collector_context(report_collector *c) {
    runner_holder *scope;
    TypedData_Get_Struct(c->scope, runner_holder, &runner_type, scope);
    return NIL_P(scope->report_state) ? Qnil : rb_ary_entry(scope->report_state, 0);
}
static VALUE collector_silent(VALUE self) {
    VALUE current = collector_context(get_report_collector(self));
    if (NIL_P(current)) return Qtrue;
    if (rb_typeddata_is_kind_of(current, &report_collector_type))
        return sn_report_silent(get_report_collector(current)->report) ? Qtrue : Qfalse;
    VALUE state = rb_funcall(current, rb_intern_const("native_report_context"), 0);
    return NIL_P(rb_ary_entry(state, 0)) ? Qtrue : Qfalse;
}
static runtime_locations read_runtime_locations(VALUE buffer) {
    runtime_locations locations = {buffer, Qnil, Qnil};
    if (!NIL_P(buffer)) {
        locations.properties = rb_funcall(buffer, rb_intern_const("evaluated_properties"), 0);
        locations.items = rb_funcall(buffer, rb_intern_const("evaluated_items"), 0);
    }
    return locations;
}
static VALUE collector_finish(VALUE self, VALUE valid, VALUE buffer) {
    report_collector *c = get_report_collector(self);
    runtime_locations locations = read_runtime_locations(buffer);
    if (!NIL_P(buffer)) rb_ary_push(c->results, buffer);
    c->busy = 1;
    sn_container_report_finish(c->report, RTEST(valid), &locations);
    c->busy = 0;
    VALUE result = collector_report_object();
    report_holder *h;
    TypedData_Get_Struct(result, report_holder, &report_type, h);
    h->report = sn_report_clone(c->report);
    RB_GC_GUARD(self); RB_GC_GUARD(buffer);
    return result;
}
static VALUE collector_evaluation_buffer(VALUE self) {
    report_collector *c = get_report_collector(self);
    runner_holder *scope;
    TypedData_Get_Struct(c->scope, runner_holder, &runner_type, scope);
    VALUE pool = rb_ary_entry(scope->report_state, 1);
    if (NIL_P(pool)) {
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE klass = rb_const_get(internal, rb_intern_const("EvaluationPool"));
        pool = rb_class_new_instance(0, NULL, klass);
        rb_ary_store(scope->report_state, 1, pool);
    }
    VALUE result = rb_funcall(pool, rb_intern_const("acquire"), 0);
    RB_GC_GUARD(pool); RB_GC_GUARD(self);
    return result;
}
extern void *sn_object_report_child(const void *, VALUE, const unsigned char *, size_t, VALUE, int);
extern void *sn_object_report_error(const void *, const void *, size_t, VALUE, int, VALUE);
extern void *sn_object_report_properties(const void *, const void *, int);
extern VALUE sn_property_locations_set(const void *, size_t *);
extern VALUE sn_property_locations_key(const void *, size_t);
extern void sn_property_locations_mark(const void *);
extern size_t sn_property_locations_size(const void *);
extern void sn_property_locations_free(void *);
typedef struct { void *locations; } property_locations_holder;
static void property_locations_mark(void *ptr) {
    property_locations_holder *h = ptr;
    if (h->locations) sn_property_locations_mark(h->locations);
}
static void property_locations_free(void *ptr) {
    property_locations_holder *h = ptr;
    if (h->locations) sn_property_locations_free(h->locations);
    xfree(h);
}
static size_t property_locations_size(const void *ptr) {
    const property_locations_holder *h = ptr;
    return sizeof(*h) + (h->locations ? sn_property_locations_size(h->locations) : 0);
}
static const rb_data_type_t property_locations_type = {
    "Schemurai::Native::PropertyLocations", {property_locations_mark, property_locations_free, property_locations_size, NULL, {NULL}},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};
static VALUE report_properties(VALUE owner, const void *report, int prior) {
    property_locations_holder *h;
    VALUE object = TypedData_Make_Struct(rb_cObject, property_locations_holder, &property_locations_type, h);
    h->locations = NULL;
    h->locations = sn_object_report_properties(report, ready_program(owner)->engine, prior);
    size_t count;
    VALUE set = sn_property_locations_set(h->locations, &count);
    if (!NIL_P(set) && !count) return set;
    VALUE klass = rb_const_get(rb_cObject, rb_intern_const("Set"));
    VALUE result = rb_class_new_instance(0, NULL, klass);
    for (size_t i = 0; i < count; i++)
        rb_funcall(result, rb_intern_const("add"), 1, sn_property_locations_key(h->locations, i));
    if (!NIL_P(set)) rb_funcall(result, rb_intern_const("merge"), 1, set);
    rb_obj_freeze(result);
    RB_GC_GUARD(object);
    return result;
}
static VALUE collector_properties(VALUE self, VALUE prior) {
    report_collector *c = get_report_collector(self);
    VALUE result = report_properties(c->owner, c->report, RTEST(prior));
    RB_GC_GUARD(self);
    return result;
}
static VALUE compatibility_object_callback(report_collector *, VALUE, VALUE);
static VALUE collector_object_evaluate(VALUE self, VALUE program, VALUE instance, VALUE segment, VALUE keyword, VALUE child, VALUE flags, VALUE annotations) {
    report_collector *c = get_report_collector(self);
    size_t node = collector_node(c, program);
    VALUE current = collector_context(c);
    if (!NIL_P(current) && !rb_typeddata_is_kind_of(current, &report_collector_type)) {
        VALUE args = rb_ary_new_from_args(8, self, program, instance, segment, keyword, child, flags, annotations);
        VALUE result = compatibility_object_callback(c, current, args);
        RB_GC_GUARD(args);
        return result;
    }
    report_collector *target = NIL_P(current) ? NULL : get_report_collector(current);
    if (!RTEST(annotations) && (!target || sn_report_silent(target->report))) {
        VALUE inherited = Qnil;
        if (target) {
            inherited = collector_report_object();
            report_holder *seed;
            TypedData_Get_Struct(inherited, report_holder, &report_type, seed);
            seed->report = sn_report_callback_seed(target->report);
        }
        VALUE result = collector_run(c, node, instance, inherited, Qnil, 0, current);
        if (target && !RTEST(result)) {
            target->busy = 1;
            sn_report_child_validity(target->report, 0);
            target->busy = 0;
        }
        RB_GC_GUARD(inherited); RB_GC_GUARD(current);
        return result;
    }
    StringValue(keyword);
    int bits = NUM2INT(flags) | (RTEST(annotations) ? 4 : 0);
    int paths = target && !sn_report_silent(target->report);
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    VALUE empty_seed = Qnil;
    const void *source;
    if (target) source = target->report;
    else {
        empty_seed = collector_report_object();
        report_holder *empty;
        TypedData_Get_Struct(empty_seed, report_holder, &report_type, empty);
        empty->report = sn_report_context(1, 0, Qnil, Qnil);
        source = empty->report;
    }
    seed->report = sn_object_report_child(source, segment, (const unsigned char *)RSTRING_PTR(keyword), RSTRING_LEN(keyword), child, bits);
    VALUE result = collector_run(c, node, instance, seed_object, Qnil, 2, current);
    report_holder *completed;
    TypedData_Get_Struct(result, report_holder, &report_type, completed);
    int verdict = target ? collector_adopt(target, result) : sn_report_verdict(completed->report);
    if (paths && sn_report_context_reset(completed->report) == 1) {
        int pops = 1 + !!(bits & 2) + !(bits & 1);
        while (pops-- > 0) rb_funcall(Qnil, rb_intern_const("pop"), 0);
    }
    VALUE output = verdict == SN_VERDICT_VALID ? Qtrue : Qfalse;
    if (RTEST(annotations)) {
        VALUE properties = report_properties(c->owner, completed->report, 0);
        output = rb_ary_new_from_args(2, output, properties);
        RB_GC_GUARD(properties);
    }
    RB_GC_GUARD(current); RB_GC_GUARD(empty_seed);
    RB_GC_GUARD(self); RB_GC_GUARD(seed_object); RB_GC_GUARD(result); RB_GC_GUARD(keyword);
    return output;
}
static VALUE collector_object_error(VALUE self, VALUE keyword, VALUE frame) {
    report_collector *c = get_report_collector(self);
    const char *name = StringValueCStr(keyword);
    int kind;
    if (!strcmp(name, "type")) kind = 0;
    else if (!strcmp(name, "maxProperties")) kind = 1;
    else if (!strcmp(name, "minProperties")) kind = 2;
    else if (!strcmp(name, "required")) kind = 3;
    else if (!strcmp(name, "dependencies")) kind = 4;
    else if (!strcmp(name, "dependentRequired")) kind = 5;
    else rb_raise(rb_eArgError, "unknown object diagnostic");
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_object_report_error(c->report, ready_program(c->owner)->engine, c->node, c->instance, kind, INT2FIX(0));
    VALUE result = collector_run(c, c->node, c->instance, seed_object, frame, 2, c->self);
    collector_adopt(c, result);
    RB_GC_GUARD(self); RB_GC_GUARD(seed_object); RB_GC_GUARD(result);
    return Qnil;
}
static VALUE collector_invocation_budget(VALUE self) {
    runner_holder *scope;
    TypedData_Get_Struct(get_report_collector(self)->scope, runner_holder, &runner_type, scope);
    return scope->active_budget;
}
static VALUE collector_regexp_cache(VALUE self) {
    runner_holder *scope;
    TypedData_Get_Struct(get_report_collector(self)->scope, runner_holder, &runner_type, scope);
    VALUE *slot = NIL_P(scope->active_budget) ? &scope->regexps : &scope->limited_regexps;
    if (NIL_P(*slot)) *slot = rb_hash_new();
    publish_states(scope);
    return *slot;
}
typedef struct { VALUE state, collector, previous, frame; int trial, completed; } report_context_call;
static VALUE collect_container_frame(VALUE context) {
    report_context_call *call = (report_context_call *)context;
    VALUE result = rb_funcall(call->frame, rb_intern_const("collect"), 0);
    call->completed = 1;
    return result;
}
static VALUE restore_report_context(VALUE context) {
    report_context_call *call = (report_context_call *)context;
    if (!NIL_P(call->frame) && !call->completed && !NIL_P(call->previous)
        && rb_typeddata_is_kind_of(call->previous, &report_collector_type)) {
        VALUE interrupted = collector_report_object();
        report_holder *partial;
        TypedData_Get_Struct(interrupted, report_holder, &report_type, partial);
        partial->report = sn_report_partial(get_report_collector(call->collector)->report);
        collector_adopt(get_report_collector(call->previous), interrupted);
        RB_GC_GUARD(interrupted);
    }
    if (call->trial || rb_ary_entry(call->state, 0) == call->collector)
        rb_ary_store(call->state, 0, call->previous);
    return Qnil;
}
static VALUE make_report_collector(VALUE owner, VALUE scope, VALUE seed_object, VALUE instance, size_t node) {
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE native = rb_const_get(schemurai, rb_intern_const("Native"));
    VALUE klass = rb_const_get(native, rb_intern_const("ReportCollector"));
    report_collector *c;
    VALUE collector = TypedData_Make_Struct(klass, report_collector, &report_collector_type, c);
    c->self = collector;
    c->owner = owner; c->scope = scope; c->seed = seed_object; c->results = Qnil;
    c->instance = instance; c->node = node; c->report = NULL; c->busy = 0;
    c->results = rb_ary_new();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    c->report = sn_report_clone(seed->report);
    return collector;
}
static VALUE container_report_runtime(evaluation_call *call, int object) {
    runner_holder *r = call->runner;
    contains_arguments arguments;
    sn_contains_arguments(r->caches, &arguments);
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_report_seed(r->caches);
    VALUE collector = make_report_collector(r->owner, callback_scope(call), seed_object, arguments.instance, arguments.child);
    VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
    VALUE checks = rb_const_get(internal, rb_intern_const("ContainerChecks"));
    const char *frame_name = object ? (NIL_P(call->budget) ? "ObjectReportFrame" : "LimitedObjectReportFrame")
        : (NIL_P(call->budget) ? "ArrayReportFrame" : "LimitedArrayReportFrame");
    VALUE frame_class = rb_const_get(checks, rb_intern(frame_name));
    VALUE args[] = {arguments.rules, arguments.instance, call->budget, INT2FIX(arguments.required), collector};
    VALUE frame = rb_class_new_instance(5, args, frame_class);
    report_context_call context = {r->active_report_state, collector, rb_ary_entry(r->active_report_state, 0), frame, sn_report_silent(seed->report), 0};
    rb_ary_store(context.state, 0, collector);
    VALUE result = rb_ensure(collect_container_frame, (VALUE)&context, restore_report_context, (VALUE)&context);
    if (NIL_P(r->report_results)) r->report_results = rb_ary_new();
    rb_ary_push(r->report_results, result);
    report_holder *completed;
    TypedData_Get_Struct(result, report_holder, &report_type, completed);
    sn_report_accept(r->caches, completed->report);
    RB_GC_GUARD(collector); RB_GC_GUARD(frame); RB_GC_GUARD(result);
    return Qtrue;
}

/* Each borrowed native text piece is copied before any Ruby method is called.
 * The owning runner keeps the request and its name handles alive across GC. */
static VALUE build_pointer(runner_holder *runner) {
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
    VALUE helper = rb_const_get(internal, rb_intern_const("JsonPointer"));
    VALUE output = rb_utf8_str_new("", 0);
    size_t count = sn_pointer_parts(runner->caches);
    for (size_t index = 0; index < count; index++) {
        const unsigned char *data;
        size_t length;
        VALUE key;
        sn_pointer_part(runner->caches, index, &data, &length, &key);
        if (length) rb_str_append(output, rb_utf8_str_new((const char *)data, length));
        if (key != Qundef) {
            VALUE escaped = rb_funcall(helper, rb_intern_const("escape"), 1, key);
            rb_str_append(output, escaped);
        }
    }
    RB_GC_GUARD(helper);
    return output;
}
static VALUE null_numeric(VALUE instance, int operation) {
    int selector = operation - SN_RUNTIME_NULL_NUMBER;
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE native = rb_const_get(schemurai, rb_intern_const("Native"));
    VALUE helper = rb_const_get(native, rb_intern_const("NullNumeric"));
    return rb_funcall(helper, rb_intern_const("valid?"), 3, instance,
        INT2FIX(selector >> 1), (selector & 1) ? Qtrue : Qfalse);
}
static VALUE build_message(runner_holder *runner) {
    message_arguments arguments;
    sn_message_arguments(runner->caches, &arguments);
    VALUE keyword = rb_utf8_str_new((const char *)arguments.keyword, arguments.keyword_len);
    if (arguments.frame != Qundef) {
        st_data_t index;
        if (!st_lookup(runner->frame_indices, (st_data_t)arguments.frame, &index)) rb_raise(rb_eRuntimeError, "missing runtime frame");
        VALUE frame = rb_ary_entry(runner->frames, (long)index);
        VALUE result = rb_funcall(frame, rb_intern_const("message"), 2, keyword, arguments.detail ? Qtrue : Qfalse);
        RB_GC_GUARD(frame);
        RB_GC_GUARD(keyword);
        return result;
    }
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE native = rb_const_get(schemurai, rb_intern_const("Native"));
    VALUE helper = rb_const_get(native, rb_intern_const("Diagnostics"));
    VALUE result = rb_funcall(helper, rb_intern_const("message"), 5, keyword,
        INT2NUM(arguments.opcode), arguments.operand, arguments.instance, SIZET2NUM(arguments.detail));
    RB_GC_GUARD(keyword);
    RB_GC_GUARD(helper);
    return result;
}
static VALUE scalar_step(runner_holder *runner, int operation, VALUE budget) {
    int container = operation >= SN_RUNTIME_ARRAY_HEADER;
    int object = operation >= SN_RUNTIME_OBJECT_HEADER;
    int string = !container && operation >= SN_RUNTIME_STRING;
    int base = container ? (object ? SN_RUNTIME_OBJECT_HEADER : SN_RUNTIME_ARRAY_HEADER)
        : (string ? SN_RUNTIME_STRING : SN_RUNTIME_NUMBER);
    int selector = operation - base;
    int flags = selector & (string ? 255 : 63);
    scalar_arguments arguments;
    sn_scalar_arguments(runner->caches, &arguments);
    st_data_t stored;
    VALUE frame;
    if (st_lookup(runner->frame_indices, (st_data_t)arguments.ordinal, &stored)) {
        frame = rb_ary_entry(runner->frames, (long)stored);
    } else {
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE checks = rb_const_get(internal, rb_intern_const(container ? "ContainerChecks" : (string ? "StringChecks" : "NumberChecks")));
        VALUE state = budget;
        if (!container) {
            VALUE *state_slot = string
                ? (NIL_P(budget) ? &runner->string_state : &runner->limited_string_state)
                : (NIL_P(budget) ? &runner->number_state : &runner->limited_number_state);
            if (NIL_P(*state_slot)) {
                VALUE state_class = rb_const_get(checks, rb_intern_const("State"));
                if (string) {
                    VALUE *regexps = NIL_P(budget) ? &runner->regexps : &runner->limited_regexps;
                    if (NIL_P(*regexps)) *regexps = rb_hash_new();
                    VALUE args[] = {*regexps, budget};
                    *state_slot = rb_class_new_instance(2, args, state_class);
                } else {
                    *state_slot = rb_class_new_instance(0, NULL, state_class);
                    if (!NIL_P(budget)) rb_funcall(*state_slot, rb_intern_const("budget="), 1, budget);
                }
            }
            state = *state_slot;
        }
        const char *name = "Frame";
        if (container) name = object ? "ObjectFrame" : (NIL_P(budget) ? "ArrayFrame" : "LimitedArrayFrame");
        VALUE klass = rb_const_get(checks, rb_intern_const(name));
        VALUE args[] = {arguments.rules, arguments.instance, state, INT2FIX(flags)};
        frame = rb_class_new_instance((container || string) ? 4 : 3, args, klass);
        if (NIL_P(runner->frames)) runner->frames = rb_ary_new();
        size_t index = RARRAY_LEN(runner->frames);
        rb_ary_push(runner->frames, frame);
        /* Array indices remain valid if compaction moves a frame. */
        st_insert(runner->frame_indices, (st_data_t)arguments.ordinal, (st_data_t)index);
    }
    publish_states(runner);
    int step = selector >> (string ? 8 : 6);
    VALUE result;
    if (container) {
        switch (step) {
            case 0: result = rb_funcall(frame, rb_intern_const("valid?"), 0); break;
            case 1: result = rb_funcall(frame, rb_intern_const("container?"), 0); break;
            default: result = rb_funcall(frame, rb_intern_const("check"), 1, INT2FIX(step)); break;
        }
    } else if (string) {
        switch (step) {
            case 0: result = rb_funcall(frame, rb_intern_const("valid?"), 0); break;
            case 1: result = rb_funcall(frame, rb_intern_const("string?"), 0); break;
            case 2: result = rb_funcall(frame, rb_intern_const("prepare"), 0); break;
            default:
                result = step >= 8
                    ? rb_funcall(frame, rb_intern_const("invalid_pattern?"), 0)
                    : rb_funcall(frame, rb_intern_const("check"), 1, INT2FIX(step));
                break;
        }
    } else switch (step) {
        case 0: result = rb_funcall(frame, rb_intern_const("valid?"), 1, INT2FIX(selector & 63)); break;
        case 1: result = rb_funcall(frame, rb_intern_const("numeric?"), 0); break;
        case 2: result = rb_funcall(frame, rb_intern_const("integral?"), 0); break;
        case 3: result = rb_funcall(frame, rb_intern_const("prepare"), 0); break;
        default: result = rb_funcall(frame, rb_intern_const("check"), 1, INT2FIX(1 << (step - 4))); break;
    }
    RB_GC_GUARD(frame);
    return result;
}
/* Share Ruby type dispatch with ordinary runtime requests. Boolean and type
 * callbacks have no per-yield observations or scalar cache writes. */
static VALUE type_predicate(VALUE instance, int selector) {
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
    VALUE helper = rb_const_get(internal, rb_intern_const("TypeChecks"));
    return rb_funcall(helper, rb_intern_const("valid?"), 3, instance,
        INT2FIX(selector >> 1), (selector & 1) ? Qtrue : Qfalse);
}
extern VALUE sn_properties_part(const void *, size_t, size_t *, size_t *);
extern VALUE sn_properties_key(const void *, size_t, size_t);
extern size_t sn_properties_item(const void *, size_t, size_t);
extern void sn_properties_result(const void *, const runtime_locations *);
static VALUE merge_runtime_properties(evaluation_call *call) {
    runner_holder *r = call->runner;
    VALUE args[6] = {Qnil, Qnil, Qnil, Qnil, Qnil, Qnil};
    for (size_t side = 0; side < 2; side++) {
        size_t properties, items;
        size_t at = side * 3;
        args[at] = sn_properties_part(r->caches, side, &properties, &items);
        args[at + 1] = rb_ary_new_capa(properties);
        args[at + 2] = rb_ary_new_capa(items);
        for (size_t i = 0; i < properties; i++)
            rb_ary_push(args[at + 1], sn_properties_key(r->caches, side, i));
        for (size_t i = 0; i < items; i++)
            rb_ary_push(args[at + 2], SIZET2NUM(sn_properties_item(r->caches, side, i)));
    }
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
    VALUE checks = rb_const_get(internal, rb_intern_const("ContainerChecks"));
    VALUE helper = rb_const_get(checks, rb_intern_const("Properties"));
    VALUE result = rb_funcallv(helper, rb_intern_const("merge"), 6, args);
    runtime_locations locations = read_runtime_locations(result);
    if (NIL_P(r->report_results)) r->report_results = rb_ary_new();
    rb_ary_push(r->report_results, result);
    sn_properties_result(r->caches, &locations);
    for (size_t i = 0; i < 6; i++) RB_GC_GUARD(args[i]);
    RB_GC_GUARD(result);
    return Qtrue;
}
typedef struct { evaluation_call *call; VALUE source, instance; int kind; } runtime_call;
static VALUE call_runtime(VALUE context) {
    runtime_call *operation = (runtime_call *)context;
    evaluation_call *call = operation->call;
    VALUE source = operation->source, instance = operation->instance;
    runner_holder *r = call->runner;
    /* Staged frames keep Ruby checks at their VM method boundaries. An extra
     * check between assertions or error-rendering steps could overtake a later
     * Ruby exception. The native deadline continues across every retry. */
    int staged = (operation->kind >= SN_RUNTIME_STRING && operation->kind < SN_RUNTIME_EQUAL)
        || operation->kind >= SN_RUNTIME_ARRAY_HEADER || sn_caches_frame_error(r->caches)
        || (r->callback_context && (!r->continuation || r->scalar_mode))
        || operation->kind == SN_RUNTIME_SCALAR_CONTAINS
        || operation->kind == SN_RUNTIME_ARRAY_CHILDREN || operation->kind == SN_RUNTIME_OBJECT_CHILDREN
        || operation->kind == SN_RUNTIME_NATIVE_CHILD || operation->kind == SN_RUNTIME_NATIVE_REPORT
        || operation->kind == SN_RUNTIME_ARRAY_REPORT || operation->kind == SN_RUNTIME_OBJECT_REPORT || operation->kind == SN_RUNTIME_PATH_POP || operation->kind == SN_RUNTIME_PROPERTY_MERGE;
    if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
    if (operation->kind == SN_RUNTIME_PROPERTY_MERGE) return merge_runtime_properties(call);
    if (operation->kind == SN_RUNTIME_PATH_POP) {
        rb_funcall(Qnil, rb_intern_const("pop"), 0);
        return Qtrue;
    }
    if (operation->kind == SN_RUNTIME_CALLBACK_CHECKPOINT) {
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("checkpoint"), 0);
        return Qtrue;
    }
    if (operation->kind == SN_RUNTIME_ARRAY_REPORT || operation->kind == SN_RUNTIME_OBJECT_REPORT)
        return container_report_runtime(call, operation->kind == SN_RUNTIME_OBJECT_REPORT);
    if (operation->kind == SN_RUNTIME_NATIVE_REPORT) {
        contains_arguments arguments;
        sn_contains_arguments(r->caches, &arguments);
        report_holder *seed;
        VALUE seed_object = TypedData_Make_Struct(rb_cObject, report_holder, &report_type, seed);
        seed->report = NULL;
        seed->report = sn_report_seed(r->caches);
        VALUE callback = build_runner(r->owner, arguments.child);
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->parent = callback_scope(call);
        child->callback_context = child->continuation = 1;
        child->scalar_mode = sn_caches_is_scalar(r->caches);
        child->report_seed = seed_object;
        child->report_sink = rb_ary_entry(r->active_report_state, 0);
        VALUE result = evaluate_runner(callback, instance, call->budget, 2);
        if (NIL_P(result)) rb_raise(rb_eRuntimeError, "native report continuation lost its coverage proof");
        if (NIL_P(r->report_results)) r->report_results = rb_ary_new();
        rb_ary_push(r->report_results, result);
        report_holder *completed;
        TypedData_Get_Struct(result, report_holder, &report_type, completed);
        sn_report_accept(r->caches, completed->report);
        RB_GC_GUARD(result);
        RB_GC_GUARD(seed_object);
        RB_GC_GUARD(callback);
        return Qtrue;
    }
    if (operation->kind == SN_RUNTIME_NATIVE_CHILD) {
        contains_arguments arguments;
        sn_contains_arguments(r->caches, &arguments);
        VALUE callback = build_runner(r->owner, arguments.child);
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->parent = callback_scope(call);
        child->callback_context = child->continuation = 1;
        child->scalar_mode = sn_caches_is_scalar(r->caches);
        VALUE result = evaluate_runner(callback, instance, call->budget, 0);
        if (NIL_P(result)) rb_raise(rb_eRuntimeError, "native continuation lost its coverage proof");
        RB_GC_GUARD(callback);
        return result;
    }
    if (operation->kind == SN_RUNTIME_SCALAR_CONTAINS || operation->kind == SN_RUNTIME_ARRAY_CHILDREN
        || operation->kind == SN_RUNTIME_OBJECT_CHILDREN) {
        contains_arguments arguments;
        sn_contains_arguments(r->caches, &arguments);
        VALUE callback = build_runner(r->owner, arguments.child);
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->parent = callback_scope(call);
        child->callback_kind = arguments.scalar_kind;
        child->callback_flags = arguments.scalar_flags;
        child->callback_context = 1;
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE checks = rb_const_get(internal, rb_intern_const("ContainerChecks"));
        const char *frame_name = operation->kind == SN_RUNTIME_SCALAR_CONTAINS
            ? (NIL_P(call->budget) ? "ContainsFrame" : "LimitedContainsFrame")
            : operation->kind == SN_RUNTIME_ARRAY_CHILDREN
                ? (NIL_P(call->budget) ? "ArrayChildrenFrame" : "LimitedArrayChildrenFrame")
                : (NIL_P(call->budget) ? "ObjectChildrenFrame" : "LimitedObjectChildrenFrame");
        VALUE klass = rb_const_get(checks, rb_intern(frame_name));
        VALUE args[] = {arguments.rules, arguments.instance, call->budget, INT2FIX(arguments.required), callback};
        VALUE frame = rb_class_new_instance(5, args, klass);
        VALUE result = rb_funcall(frame, rb_intern_const("valid?"), 0);
        RB_GC_GUARD(callback);
        RB_GC_GUARD(frame);
        return result;
    }
    if (operation->kind >= SN_RUNTIME_ARRAY_HEADER ||
        (operation->kind >= SN_RUNTIME_NUMBER && operation->kind < SN_RUNTIME_EQUAL)) {
        VALUE result = scalar_step(r, operation->kind, operation->call->budget);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind >= SN_RUNTIME_EQUAL) {
        scalar_arguments arguments;
        sn_scalar_arguments(r->caches, &arguments);
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE helper = rb_const_get(internal, rb_intern_const("ValueEquality"));
        VALUE klass = rb_const_get(helper, rb_intern_const(NIL_P(call->budget) ? "Runtime" : "LimitedRuntime"));
        VALUE runtime = rb_class_new_instance(1, &call->budget, klass);
        VALUE result = rb_funcall(runtime, rb_intern_const("evaluate"), 3,
            INT2FIX(operation->kind - SN_RUNTIME_EQUAL), arguments.rules, arguments.instance);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        RB_GC_GUARD(runtime);
        return result;
    }
    if (operation->kind >= SN_RUNTIME_TYPE) {
        VALUE result = type_predicate(instance, operation->kind - SN_RUNTIME_TYPE);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind == SN_RUNTIME_DIAGNOSTIC_MESSAGE) {
        VALUE message = build_message(r);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return message;
    }
    if (operation->kind == SN_RUNTIME_REQUIRED_MISSING) {
        VALUE present = rb_funcallv_public(instance, rb_intern_const("key?"), 1, &source);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return RTEST(present) ? Qfalse : Qtrue;
    }
    if (operation->kind >= SN_RUNTIME_NULL_NUMBER) {
        VALUE result = null_numeric(instance, operation->kind);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind == SN_RUNTIME_IDENTITY_METHODS) {
        for (size_t index = 0; index < sizeof(identity_methods) / sizeof(*identity_methods); index++)
            if (!rb_method_basic_definition_p(source, identity_methods[index])) return Qfalse;
        return Qtrue;
    }
    if (operation->kind == SN_RUNTIME_POINTER) {
        VALUE pointer = build_pointer(r);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return pointer;
    }
    if (operation->kind == SN_RUNTIME_JSON) {
        VALUE json = rb_const_get(rb_cObject, rb_intern_const("JSON"));
        rb_funcall(json, rb_intern_const("parse"), 1, instance);
        if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return Qtrue;
    }
    VALUE *regexps = NIL_P(call->budget) ? &r->regexps : &r->limited_regexps;
    if (NIL_P(*regexps)) *regexps = rb_hash_new();
    VALUE regexp = rb_hash_lookup2(*regexps, source, Qundef);
    if (regexp == Qundef) {
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE compiler = rb_const_get(internal, rb_intern_const("EcmaRegexp"));
        regexp = rb_funcall(compiler, id_compile, 2, source, call->budget);
        rb_hash_aset(*regexps, source, regexp);
    }
    VALUE result = rb_funcall(regexp, rb_intern_const("match?"), 1, instance);
    if (!NIL_P(call->budget) && !staged) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
    RB_GC_GUARD(regexp);
    return result;
}
static void evaluate_runtime(evaluation_call *call, VALUE source, VALUE instance, int kind) {
    runtime_call operation = {call, source, instance, kind};
    VALUE previous = rb_errinfo();
    int state = 0;
    runner_holder *runner = call->runner;
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_report_live(runner->caches);
    report_context_call report_context = {runner->active_report_state, Qnil, Qnil, Qnil, 0, 0};
    if (seed->report) {
        report_context.trial = sn_report_silent(seed->report);
        report_context.collector = make_report_collector(runner->owner, callback_scope(call), seed_object, instance, runner->root);
        report_context.previous = rb_ary_entry(report_context.state, 0);
        rb_ary_store(report_context.state, 0, report_context.collector);
        if (NIL_P(runner->report_results)) runner->report_results = rb_ary_new();
        rb_ary_push(runner->report_results, report_context.collector);
    }
    VALUE result = rb_protect(call_runtime, (VALUE)&operation, &state);
    if (!NIL_P(report_context.collector)) {
        sn_report_effect(runner->caches, get_report_collector(report_context.collector)->report);
        restore_report_context((VALUE)&report_context);
    }
    RB_GC_GUARD(seed_object); RB_GC_GUARD(report_context.collector);
    if (sn_scopes_enabled(call->runner->caches))
        sn_scopes_accept(call->runner->caches, call->runner->active_scope_state);
    int verdict;
    if (state) {
        VALUE error = rb_errinfo();
        if (rb_obj_is_kind_of(error, rb_eRegexpError) && sn_caches_rescue_regexp(call->runner->caches)) {
            rb_set_errinfo(previous);
            RB_GC_GUARD(previous);
            return;
        }
        if (kind == SN_RUNTIME_JSON) {
            VALUE json = rb_const_get(rb_cObject, rb_intern_const("JSON"));
            VALUE parser_error = rb_const_get(json, rb_intern_const("ParserError"));
            if (!rb_obj_is_kind_of(error, rb_eArgError) && !rb_obj_is_kind_of(error, parser_error)) rb_jump_tag(state);
            verdict = SN_VERDICT_INVALID;
        } else {
            if (kind != SN_RUNTIME_REGEXP_ASSERTION || !rb_obj_is_kind_of(error, rb_eRegexpError)) rb_jump_tag(state);
            verdict = SN_REGEXP_INVALID;
        }
        rb_set_errinfo(previous);
    } else {
        verdict = RTEST(result) ? SN_VERDICT_VALID : SN_VERDICT_INVALID;
    }
    runner_holder *r = call->runner;
    if (kind == SN_RUNTIME_DIAGNOSTIC_MESSAGE) {
        /* Keep results rooted even if another Ractor stops Rust while its
         * message table has an active mutable RefCell borrow. */
        if (NIL_P(r->messages)) r->messages = rb_ary_new();
        rb_ary_push(r->messages, result);
        sn_message_result(r->caches, result);
        RB_GC_GUARD(result);
        return;
    }
    if (kind == SN_RUNTIME_POINTER) {
        if (NIL_P(r->pointers)) r->pointers = rb_ary_new();
        rb_ary_push(r->pointers, result);
        sn_pointer_result(r->caches, result);
        RB_GC_GUARD(result);
        return;
    }
    st_data_t sources, bucket;
    if (!st_lookup(r->matches, (st_data_t)kind, &sources)) {
        sources = (st_data_t)st_init_numtable();
        st_insert(r->matches, (st_data_t)kind, sources);
    }
    if (!st_lookup((st_table *)sources, (st_data_t)source, &bucket)) {
        bucket = (st_data_t)st_init_numtable();
        st_insert((st_table *)sources, (st_data_t)source, bucket);
    }
    st_insert((st_table *)bucket, (st_data_t)instance, verdict);
    RB_GC_GUARD(previous);
    RB_GC_GUARD(source);
    RB_GC_GUARD(instance);
}
/* Each retry starts after Rust has returned and dropped all borrowed views,
 * memo entries and partial reports. Reached scalar methods use occurrence keys.
 * The original Ruby deadline survives every pass and runtime operation. */
static VALUE retry_runtime(VALUE context) {
    evaluation_call *call = (evaluation_call *)context;
    VALUE source = Qnil, instance = Qnil;
    int operation = 0;
    /* Reordered fast scans may have requested an operation the VM would never
     * reach. Replay in observable order before invoking any Ruby method. */
    sn_caches_observe(call->runner->caches);
    evaluate_native(call);
    while (call->status == SN_VERDICT_UNSUPPORTED &&
           sn_caches_pending(call->runner->caches, &source, &instance, &operation)) {
        if (sn_caches_take_reorder(call->runner->caches)) {
            sn_caches_observe(call->runner->caches);
            evaluate_native(call);
            continue;
        }
        evaluate_runtime(call, source, instance, operation);
        sn_caches_runtime(call->runner->caches, call->runner->matches);
        evaluate_native(call);
    }
    return Qnil;
}
static VALUE report_rows(const void *report, VALUE budget) {
    size_t count = sn_report_len(report);
    VALUE output = rb_ary_new_capa(count);
    for (size_t index = 0; index < count; index++) {
        if (!NIL_P(budget) && index % 256 == 0) rb_funcall(budget, rb_intern("check_deadline!"), 0);
        diagnostic_record r;
        sn_report_record(report, index, &r);
        VALUE row = rb_ary_new_capa(NIL_P(r.message) ? 7 : 8);
        rb_ary_push(output, row);
        rb_ary_push(row, rb_utf8_str_new((const char *)r.keyword, r.keyword_len));
        rb_ary_push(row, NIL_P(r.instance_pointer) ? rb_utf8_str_new((const char *)r.instance_path, r.instance_len) : rb_str_dup(r.instance_pointer));
        rb_ary_push(row, NIL_P(r.schema_pointer) ? rb_utf8_str_new((const char *)r.schema_path, r.schema_len) : rb_str_dup(r.schema_pointer));
        rb_ary_push(row, INT2NUM(r.opcode));
        rb_ary_push(row, r.operand);
        rb_ary_push(row, r.instance);
        rb_ary_push(row, SIZET2NUM(r.detail));
        if (!NIL_P(r.message)) rb_ary_push(row, rb_str_dup(r.message));
    }
    return output;
}
static VALUE evaluate_runner_body(VALUE context) {
    evaluation_call call = *(evaluation_call *)context;
    VALUE self = call.self, instance = call.instance, budget = call.budget;
    runner_holder *r = call.runner;
    int diagnostics = call.diagnostics;
    report_holder *h = NULL;
    VALUE owner = Qnil;
    if (diagnostics) {
        owner = TypedData_Make_Struct(rb_cObject, report_holder, &report_type, h);
        h->report = NULL;
        call.report = h;
    }
    clear_runtime((VALUE)&call);
    r->active_budget = budget;
    r->report_sink_done = 0;
    if (!NIL_P(r->report_seed)) {
        report_holder *seed;
        TypedData_Get_Struct(r->report_seed, report_holder, &report_type, seed);
        sn_report_inherit(r->caches, seed->report);
    }
    if (!NIL_P(r->error_frame)) {
        r->frames = rb_ary_new_from_args(1, r->error_frame);
        st_insert(r->frame_indices, (st_data_t)INT2FIX(0), 0);
    }
    if (!NIL_P(r->parent)) {
        runner_holder *parent;
        TypedData_Get_Struct(r->parent, runner_holder, &runner_type, parent);
        copy_states(r, parent, r->callback_context, 0);
        if (r->callback_context) {
            call.limits = parent->active_limits;
            call.limits_read = 1;
            sn_caches_child(r->caches, parent->caches, !NIL_P(budget), !r->continuation || r->scalar_mode);
        }
    }
    int scoped = sn_reference_context(call.engine->engine);
    if (r->callback_context) {
        runner_holder *scope;
        VALUE object = callback_scope(&call);
        TypedData_Get_Struct(object, runner_holder, &runner_type, scope);
        if (scoped && NIL_P(scope->scope_state)) scope->scope_state = rb_ary_new();
        r->active_scope_state = scope->scope_state;
        r->active_report_state = scope->report_state;
        if (scoped && NIL_P(scope->ref_state)) scope->ref_state = rb_ary_new();
        r->active_ref_state = scope->ref_state;
        r->active_vm_state = scope->vm_active;
    } else if (NIL_P(budget)) {
        if (NIL_P(r->report_state)) r->report_state = rb_ary_new();
        r->active_report_state = r->report_state;
        VALUE current_report = rb_ary_entry(r->active_report_state, 0);
        if (!NIL_P(current_report)) {
            if (rb_typeddata_is_kind_of(current_report, &report_collector_type)) {
                report_collector *collector = get_report_collector(current_report);
                collector->busy = 1;
                sn_report_clear_collection(collector->report, !diagnostics);
                collector->busy = 0;
            } else {
                rb_funcall(current_report, rb_intern_const("native_clear_collection"), 1, diagnostics ? Qtrue : Qfalse);
            }
        }
        rb_ary_store(r->active_report_state, 0, Qnil);
        VALUE pool = rb_ary_entry(r->active_report_state, 1);
        if (!NIL_P(pool)) rb_funcall(pool, rb_intern_const("reset"), 0);
        if (scoped && NIL_P(r->scope_state)) r->scope_state = rb_ary_new();
        r->active_scope_state = r->scope_state;
        if (scoped && NIL_P(r->ref_state)) r->ref_state = rb_ary_new();
        r->active_ref_state = r->ref_state;
        r->active_vm_state = r->vm_active;
        if (!NIL_P(r->active_scope_state)) rb_ary_clear(r->active_scope_state);
    } else {
        r->active_report_state = rb_ary_new();
        r->active_scope_state = scoped ? rb_ary_new() : Qnil;
        r->active_ref_state = scoped ? rb_ary_new() : Qnil;
        r->active_vm_state = Qnil;
    }
    sn_scopes_inherit(r->caches, r->active_scope_state, r->active_ref_state, r->active_vm_state, scoped);
    VALUE pool = rb_ary_entry(r->active_report_state, 1);
    if (!NIL_P(pool) && RTEST(rb_funcall(pool, rb_intern_const("used?"), 0)))
        sn_caches_reuse_buffers(r->caches);
    evaluate_native(&call);
    VALUE source = Qnil, requested = Qnil;
    int operation = 0;
    if (call.status == SN_VERDICT_UNSUPPORTED &&
        sn_caches_pending(r->caches, &source, &requested, &operation)) {
        retry_runtime((VALUE)&call);
    }
    if (call.status == SN_VERDICT_UNSUPPORTED)
        rb_raise(rb_eRuntimeError, "native execution lost its coverage proof");
    if (!diagnostics) {
        if (call.status != SN_VERDICT_UNSUPPORTED && !NIL_P(r->report_sink)) {
            VALUE completed = collector_report_object();
            report_holder *h;
            TypedData_Get_Struct(completed, report_holder, &report_type, h);
            h->report = sn_callback_report_result(r->caches, call.status);
            collector_adopt(get_report_collector(r->report_sink), completed);
            r->report_sink_done = 1;
            RB_GC_GUARD(completed);
        }
        VALUE result = call.status ? Qtrue : Qfalse;
        RB_GC_GUARD(owner);
        RB_GC_GUARD(instance);
        RB_GC_GUARD(self);
        return result;
    }
    if (diagnostics == 2) {
        r->report_sink_done = 1;
        RB_GC_GUARD(instance);
        RB_GC_GUARD(self);
        return owner;
    }
    if (sn_report_silent(h->report)) {
        RB_GC_GUARD(owner);
        return Qfalse;
    }
    VALUE output = report_rows(h->report, budget);
    RB_GC_GUARD(owner);
    RB_GC_GUARD(instance);
    RB_GC_GUARD(self);
    return output;
}
static VALUE finish_evaluation(VALUE context) {
    evaluation_call *call = (evaluation_call *)context;
    runner_holder *runner = call->runner;
    if (!NIL_P(runner->report_sink) && !runner->report_sink_done) {
        VALUE interrupted = collector_report_object();
        report_holder *partial;
        TypedData_Get_Struct(interrupted, report_holder, &report_type, partial);
        partial->report = sn_report_interrupted(runner->caches);
        if (partial->report) collector_adopt(get_report_collector(runner->report_sink), interrupted);
        RB_GC_GUARD(interrupted);
    }
    publish_references(runner, 1);
    size_t unwind = sn_scopes_unwind(runner->caches);
    while (unwind-- > 0) rb_ary_pop(runner->active_scope_state);
    publish_states(runner);
    close_callback_scope(runner);
    clear_runtime(context);
    runner->active_budget = Qnil;
    runner->active_scope_state = Qnil;
    runner->active_report_state = Qnil;
    runner->active_ref_state = runner->active_vm_state = Qnil;
    runner->active_limits = (native_limits){0};
    runner->busy = 0;
    return Qnil;
}
static VALUE evaluate_runner(VALUE self, VALUE instance, VALUE budget, int diagnostics) {
    runner_holder *runner;
    TypedData_Get_Struct(self, runner_holder, &runner_type, runner);
    prepare_runner(runner);
    if (runner->busy) {
        VALUE nested = build_runner(runner->owner, runner->root);
        runner_holder *child;
        TypedData_Get_Struct(nested, runner_holder, &runner_type, child);
        child->parent = self;
        child->callback_context = runner->callback_context;
        child->continuation = runner->continuation;
        child->scalar_mode = runner->scalar_mode;
        child->report_seed = runner->report_seed;
        child->report_sink = runner->report_sink;
        child->error_frame = runner->error_frame;
        child->scope_state = runner->scope_state;
        child->report_state = runner->report_state;
        child->ref_state = runner->ref_state;
        child->vm_active = runner->vm_active;
        VALUE result = evaluate_runner(nested, instance, budget, diagnostics);
        RB_GC_GUARD(nested);
        return result;
    }
    evaluation_call call = {self, instance, budget, runner, ready_program(runner->owner), NULL, 0, {0}, 0, diagnostics};
    runner->busy = 1;
    VALUE result = rb_ensure(evaluate_runner_body, (VALUE)&call, finish_evaluation, (VALUE)&call);
    RB_GC_GUARD(self);
    return result;
}
typedef struct {
    VALUE target, state, collector, callback, instance, budget, object_args;
    size_t baseline;
} compatibility_report_call;
static VALUE call_compatibility_report(VALUE context) {
    compatibility_report_call *call = (compatibility_report_call *)context;
    rb_ary_store(call->state, 0, call->collector);
    if (!NIL_P(call->object_args)) {
        VALUE args[7];
        for (long i = 0; i < 7; i++) args[i] = rb_ary_entry(call->object_args, i + 1);
        return rb_funcallv(rb_ary_entry(call->object_args, 0), rb_intern_const("evaluate_object"), 7, args);
    }
    return evaluate_runner(call->callback, call->instance, call->budget, 0);
}
static VALUE finish_compatibility_report(VALUE context) {
    compatibility_report_call *call = (compatibility_report_call *)context;
    report_collector *collector = get_report_collector(call->collector);
    VALUE rows = report_rows(collector->report, Qnil);
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE native = rb_const_get(schemurai, rb_intern_const("Native"));
    VALUE diagnostics = rb_const_get(native, rb_intern_const("Diagnostics"));
    VALUE errors = rb_ary_new_capa(RARRAY_LEN(rows));
    for (long i = 0; i < RARRAY_LEN(rows); i++)
        rb_ary_push(errors, rb_funcall(diagnostics, rb_intern_const("error"), 1, rb_ary_entry(rows, i)));
    size_t count = sn_report_context_count(collector->report, call->baseline);
    rb_funcall(call->target, rb_intern_const("native_append_report"), 3, errors, SIZET2NUM(count),
        INT2NUM(sn_report_context_reset(collector->report)));
    RB_GC_GUARD(rows); RB_GC_GUARD(errors);
    return Qnil;
}
static VALUE make_compatibility_collector(VALUE owner, VALUE scope, size_t node, VALUE target, VALUE instance, size_t *baseline) {
    VALUE data = rb_funcall(target, rb_intern_const("native_report_context"), 0);
    *baseline = NUM2SIZET(rb_ary_entry(data, 1));
    VALUE seed_object = collector_report_object();
    report_holder *seed;
    TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
    seed->report = sn_report_context(NIL_P(rb_ary_entry(data, 0)), *baseline,
        rb_ary_entry(data, 2), rb_ary_entry(data, 3));
    VALUE collector = make_report_collector(owner, scope, seed_object, instance, node);
    RB_GC_GUARD(data); RB_GC_GUARD(seed_object);
    return collector;
}
static VALUE compatibility_object_callback(report_collector *c, VALUE target, VALUE args) {
    runner_holder *scope;
    TypedData_Get_Struct(c->scope, runner_holder, &runner_type, scope);
    size_t baseline;
    VALUE collector = make_compatibility_collector(c->owner, c->scope, c->node, target, rb_ary_entry(args, 2), &baseline);
    compatibility_report_call call = {target, scope->report_state, collector, Qnil, Qnil, Qnil, args, baseline};
    VALUE result = rb_ensure(call_compatibility_report, (VALUE)&call, finish_compatibility_report, (VALUE)&call);
    RB_GC_GUARD(collector); RB_GC_GUARD(args);
    return result;
}
static VALUE compatibility_report_callback(runner_holder *recipe, runner_holder *scope, VALUE target, VALUE instance) {
    size_t baseline;
    VALUE collector = make_compatibility_collector(recipe->owner, recipe->parent, recipe->root, target, instance, &baseline);
    VALUE seed_object = get_report_collector(collector)->seed;
    VALUE callback = build_runner(recipe->owner, recipe->root);
    runner_holder *child;
    TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
    child->parent = recipe->parent;
    child->callback_context = 1;
    child->report_seed = seed_object;
    child->report_sink = collector;
    compatibility_report_call call = {target, scope->report_state, collector, callback, instance, scope->active_budget, Qnil, baseline};
    VALUE result = rb_ensure(call_compatibility_report, (VALUE)&call, finish_compatibility_report, (VALUE)&call);
    RB_GC_GUARD(seed_object); RB_GC_GUARD(collector); RB_GC_GUARD(callback);
    return result;
}
/* A recipe can outlive the method that received its block. Each invocation
 * owns observations, while its evaluator's budget/cache scope is shared. */
static VALUE scalar_callback(VALUE self, VALUE instance) {
    runner_holder *recipe, *parent;
    TypedData_Get_Struct(self, runner_holder, &runner_type, recipe);
    if (NIL_P(recipe->parent) || !recipe->callback_context) rb_raise(rb_eRuntimeError, "not a scalar callback");
    TypedData_Get_Struct(recipe->parent, runner_holder, &runner_type, parent);
    /* LimitedEvaluator's retained block reaches its cleared budget first. */
    if (parent->closed_limited) rb_funcall(Qnil, rb_intern_const("checkpoint"), 0);
    if (parent->scope_owner && !NIL_P(parent->parent)) {
        runner_holder *owner;
        TypedData_Get_Struct(parent->parent, runner_holder, &runner_type, owner);
        copy_states(parent, owner, !NIL_P(parent->active_budget), 0);
    }
    VALUE budget = parent->active_budget;
    if (!NIL_P(budget) && recipe->callback_kind != SN_CALLBACK_RUNTIME) {
        /* Direct Boolean/type dispatch has one entry and one instruction. */
        rb_funcall(budget, rb_intern_const("checkpoint"), 0);
        rb_funcall(budget, rb_intern_const("checkpoint"), 0);
    }
    VALUE result;
    VALUE current = NIL_P(parent->report_state) ? Qnil : rb_ary_entry(parent->report_state, 0);
    if (!NIL_P(current) && recipe->callback_kind == SN_CALLBACK_RUNTIME
        && !rb_typeddata_is_kind_of(current, &report_collector_type)) {
        result = compatibility_report_callback(recipe, parent, current, instance);
    } else if (!NIL_P(current) && recipe->callback_kind == SN_CALLBACK_RUNTIME) {
        report_collector *collector = get_report_collector(current);
        VALUE seed_object = collector_report_object();
        report_holder *seed;
        TypedData_Get_Struct(seed_object, report_holder, &report_type, seed);
        seed->report = sn_report_callback_seed(collector->report);
        VALUE callback = build_runner(recipe->owner, recipe->root);
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->parent = recipe->parent;
        child->callback_context = 1;
        child->report_seed = seed_object;
        child->report_sink = current;
        result = evaluate_runner(callback, instance, budget, 0);
        RB_GC_GUARD(current); RB_GC_GUARD(callback); RB_GC_GUARD(seed_object);
    } else switch (recipe->callback_kind) {
        case SN_CALLBACK_BOOLEAN: result = recipe->callback_flags ? Qtrue : Qfalse; break;
        case SN_CALLBACK_TYPE: result = RTEST(type_predicate(instance, recipe->callback_flags)) ? Qtrue : Qfalse; break;
        default: result = evaluate_runner(self, instance, budget, 0); break;
    }
    if (NIL_P(result)) rb_raise(rb_eRuntimeError, "scalar callback lost its native coverage proof");
    if (!NIL_P(budget) && sn_caches_deadline_expired(parent->caches))
        rb_funcall(budget, rb_intern_const("raise_native_limit"), 2, INT2FIX(2), INT2FIX(0));
    RB_GC_GUARD(self);
    return result;
}
/* Ruby selects the child using the original rules and indexed methods. The
 * compiled Program is an opaque identity key, never interpreted in Ruby. */
static VALUE runner_evaluate_child(VALUE self, VALUE program, VALUE instance) {
    runner_holder *factory;
    TypedData_Get_Struct(self, runner_holder, &runner_type, factory);
    if (NIL_P(factory->parent) || !factory->callback_context)
        rb_raise(rb_eRuntimeError, "not a native child factory");
    if (NIL_P(factory->child_callbacks)) factory->child_callbacks = rb_hash_new();
    VALUE callback = rb_hash_lookup2(factory->child_callbacks, program, Qundef);
    if (callback == Qundef) {
        holder *owner = ready_program(factory->owner);
        size_t index = sn_node_index(owner->engine, program);
        if (index == SIZE_MAX) rb_raise(rb_eRuntimeError, "native child was not compiled");
        callback = build_runner(factory->owner, index);
        runner_holder *child;
        TypedData_Get_Struct(callback, runner_holder, &runner_type, child);
        child->parent = factory->parent;
        child->callback_context = 1;
        child->callback_kind = sn_callback_kind(owner->engine, index, &child->callback_flags);
        rb_hash_aset(factory->child_callbacks, program, callback);
    }
    VALUE result = scalar_callback(callback, instance);
    RB_GC_GUARD(self);
    return result;
}
static runner_holder *factory_scope(VALUE self) {
    runner_holder *factory, *scope;
    TypedData_Get_Struct(self, runner_holder, &runner_type, factory);
    if (NIL_P(factory->parent) || !factory->callback_context)
        rb_raise(rb_eRuntimeError, "not a native child factory");
    TypedData_Get_Struct(factory->parent, runner_holder, &runner_type, scope);
    return scope;
}
static VALUE runner_invocation_budget(VALUE self) {
    return factory_scope(self)->active_budget;
}
static VALUE runner_regexp_cache(VALUE self) {
    runner_holder *scope = factory_scope(self);
    VALUE *slot = NIL_P(scope->active_budget) ? &scope->regexps : &scope->limited_regexps;
    if (NIL_P(*slot)) *slot = rb_hash_new();
    publish_states(scope);
    return *slot;
}
static VALUE diagnostics(VALUE self, VALUE instance) {
    holder *h = ready_program(self);
    VALUE run = build_runner(self, sn_root_index(h->engine));
    return evaluate_runner(run, instance, Qnil, 1);
}
static VALUE runner_diagnostics(VALUE self, VALUE instance) {
    return evaluate_runner(self, instance, Qnil, 1);
}
static VALUE runner_diagnostics_with_budget(VALUE self, VALUE instance, VALUE budget) {
    return evaluate_runner(self, instance, budget, 1);
}
void Init_schemurai_native(void) {
    /* Cache fixed IDs explicitly, independent of compiler-specific macros. */
    identity_methods[0] = rb_intern_const("is_a?");
    identity_methods[1] = rb_intern_const("class");
    identity_methods[2] = rb_intern_const("instance_of?");
    identity_methods[3] = rb_intern_const("==");
    identity_methods[4] = rb_intern_const("hash");
    id_resolve = rb_intern_const("resolve");
    id_schemurai = rb_intern_const("Schemurai");
    id_resolution_error = rb_intern_const("ResolutionError");
    id_root = rb_intern_const("root");
    id_compile = rb_intern_const("compile");
    id_graph = rb_intern_const("@graph");
    id_dynamic_anchor = rb_intern_const("dynamic_anchor");
    id_dynamic_anchor_names = rb_intern_const("dynamic_anchor_names");
    id_dynamic_anchor_count = rb_intern_const("@dynamic_anchor_count");
    utf8_index = rb_utf8_encindex();
    ascii_index = rb_usascii_encindex();
    binary_index = rb_ascii8bit_encindex();
    for (size_t i = 0; i < sizeof(opcodes) / sizeof(opcodes[0]); i++)
        opcodes[i].id = rb_intern_const(opcodes[i].symbol);
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++)
        fields[i].id = rb_intern_const(fields[i].symbol);
    rb_ext_ractor_safe(true);
    VALUE schemurai = rb_define_module("Schemurai");
    VALUE native = rb_define_module_under(schemurai, "Native");
    VALUE protocol = rb_define_module_under(native, "Protocol");
#define SN_OPCODE(name, symbol, value) rb_define_const(protocol, "OP_" #name, INT2NUM(SN_OP_##name));
#define SN_CONSTANT(name, value) rb_define_const(protocol, #name, INT2NUM(SN_##name));
#define SN_FIELD(name, symbol, value)
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
#undef SN_FIELD
    VALUE klass = rb_define_class_under(native, "Program", rb_cObject);
    rb_define_alloc_func(klass, allocate);
    rb_define_method(klass, "initialize", initialize, 4);
    rb_define_method(klass, "valid?", valid, 1);
    rb_define_method(klass, "diagnostics", diagnostics, 1);
    rb_define_method(klass, "make_shareable", make_shareable, 0);
    rb_define_method(klass, "runner", runner, 1);
    rb_define_method(klass, "unresolved_references?", has_unresolved_references, 0);
    VALUE collector_class = rb_define_class_under(native, "ReportCollector", rb_cObject);
    rb_undef_alloc_func(collector_class);
    rb_define_method(collector_class, "evaluate", collector_evaluate, 5);
    rb_define_method(collector_class, "trial", collector_trial, 2);
    rb_define_method(collector_class, "error", collector_error, 2);
    rb_define_method(collector_class, "record_item", collector_record, 1);
    rb_define_method(collector_class, "include_item?", collector_contains, 2);
    rb_define_method(collector_class, "silent?", collector_silent, 0);
    rb_define_method(collector_class, "finish", collector_finish, 2);
    rb_define_method(collector_class, "evaluation_buffer", collector_evaluation_buffer, 0);
    rb_define_method(collector_class, "properties", collector_properties, 1);
    rb_define_method(collector_class, "evaluate_object", collector_object_evaluate, 7);
    rb_define_method(collector_class, "object_error", collector_object_error, 2);
    rb_define_method(collector_class, "finish_object", collector_finish, 2);
    rb_define_method(collector_class, "invocation_budget", collector_invocation_budget, 0);
    rb_define_method(collector_class, "regexp_cache", collector_regexp_cache, 0);
    VALUE runner_class = rb_define_class_under(klass, "Runner", rb_cObject);
    rb_undef_alloc_func(runner_class);
    rb_define_method(runner_class, "call", scalar_callback, 1);
    rb_define_method(runner_class, "evaluate_child", runner_evaluate_child, 2);
    rb_define_method(runner_class, "invocation_budget", runner_invocation_budget, 0);
    rb_define_method(runner_class, "regexp_cache", runner_regexp_cache, 0);
    rb_define_method(runner_class, "share_scalar_state", runner_share_scalar_state, 6);
    rb_define_method(runner_class, "reference_active?", runner_reference_active, 2);
    rb_define_method(runner_class, "valid?", runner_valid, 1);
    rb_define_method(runner_class, "valid_with_budget", runner_valid_with_budget, 2);
    rb_define_method(runner_class, "diagnostics", runner_diagnostics, 1);
    rb_define_method(runner_class, "diagnostics_with_budget", runner_diagnostics_with_budget, 2);
}

extern int sn_object_entry(const void *, VALUE, VALUE);
struct iteration { void *context; int result; };
static int visit(VALUE key, VALUE value, VALUE arg) {
    struct iteration *iteration = (struct iteration *)arg;
    iteration->result = sn_object_entry(iteration->context, key, value);
    return iteration->result == SN_VERDICT_VALID ? ST_CONTINUE : ST_STOP;
}
int sn_object_each(VALUE value, void *context) {
    struct iteration iteration = {context, SN_VERDICT_VALID};
    rb_hash_foreach(value, visit, (VALUE)&iteration);
    return iteration.result;
}


/* Only compilation calls back into Ruby. rb_protect catches exceptions before
 * returning to Rust; raising is deferred until Rust returns to initialize. */
struct resolution { VALUE compiler, program, reference; };
static VALUE resolve_reference(VALUE arg) {
    struct resolution *r = (struct resolution *)arg;
    return rb_funcall(r->compiler, id_resolve, 2, r->program, r->reference);
}
int sn_resolve(VALUE compiler, VALUE program, VALUE reference, VALUE *result) {
    struct resolution r = {compiler, program, reference};
    int state = 0;
    *result = rb_protect(resolve_reference, (VALUE)&r, &state);
    if (state) { *result = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
int sn_resolution_error(VALUE error) {
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE klass = rb_const_get(schemurai, id_resolution_error);
    return rb_obj_is_kind_of(error, klass);
}

typedef int (*hash_callback)(void *, VALUE, VALUE);
struct hash_walk { void *context; hash_callback callback; int result; };
static int hash_visit(VALUE key, VALUE value, VALUE arg) {
    struct hash_walk *walk = (struct hash_walk *)arg;
    walk->result = walk->callback(walk->context, key, value);
    return walk->result == SN_VERDICT_VALID ? ST_CONTINUE : ST_STOP;
}
int sn_hash_each(VALUE value, void *context, hash_callback callback) {
    struct hash_walk walk = {context, callback, SN_VERDICT_VALID};
    rb_hash_foreach(value, hash_visit, (VALUE)&walk);
    return walk.result;
}
typedef int (*key_view_callback)(void *, const unsigned char *, size_t, VALUE);
struct key_view_walk { void *context; key_view_callback callback; int result; };
static int key_view_visit(VALUE key, VALUE value, VALUE arg) {
    struct key_view_walk *walk = (struct key_view_walk *)arg;
    if (!RB_TYPE_P(key, T_STRING) || CLASS_OF(key) != rb_cString) {
        walk->result = SN_VERDICT_UNSUPPORTED;
        return ST_STOP;
    }
    /* The Rust callback borrows these original bytes under the GVL and must
     * neither allocate Ruby objects nor call back into Ruby. */
    walk->result = walk->callback(walk->context,
        (const unsigned char *)RSTRING_PTR(key), RSTRING_LEN(key), value);
    return walk->result == SN_VERDICT_VALID ? ST_CONTINUE : ST_STOP;
}
int sn_hash_each_key_view(VALUE value, void *context, key_view_callback callback) {
    struct key_view_walk walk = {context, callback, SN_VERDICT_VALID};
    rb_hash_foreach(value, key_view_visit, (VALUE)&walk);
    return walk.result;
}
const unsigned char *sn_string_data(VALUE value) { return (const unsigned char *)RSTRING_PTR(value); }
size_t sn_string_bytes(VALUE value) { return RSTRING_LEN(value); }
int sn_string_length_guarded(VALUE value, size_t *length) {
    if (!RB_TYPE_P(value, T_STRING) || CLASS_OF(value) != rb_cString)
        return sn_kind(value);
    *length = string_length(value);
    return SN_TYPE_STRING;
}
static void string_raw_view(VALUE value, const unsigned char **data, size_t *length) {
    *data = (const unsigned char *)RSTRING_PTR(value);
    *length = RSTRING_LEN(value);
}
void sn_string_raw_view(VALUE value, const unsigned char **data, size_t *length) {
    string_raw_view(value, data, length);
}
/* The caller has already guarded an exact String under the GVL. */
int sn_record_key_view(VALUE value, const unsigned char **data, size_t *length) {
    string_raw_view(value, data, length);
    return RB_ENCODING_GET(value);
}
int sn_format_item_view(VALUE value, const unsigned char **data, size_t *length) {
    if (RB_TYPE_P(value, T_STRING) && CLASS_OF(value) == rb_cString) {
        string_raw_view(value, data, length);
        return 0;
    }
    return -sn_kind(value);
}
static int string_utf8(VALUE value) {
    /* Public inline alias, with CRuby fallback for extended indices.
     * Callers have already classified this VALUE as a String. */
    int encoding = RB_ENCODING_GET(value);
    return encoding == utf8_index ? SN_ENCODING_UTF8 : (encoding == ascii_index ? SN_ENCODING_ASCII : SN_ENCODING_OTHER);
}
static int string_view(VALUE value, const unsigned char **data, size_t *length) {
    int encoding = string_utf8(value);
    string_raw_view(value, data, length);
    return encoding;
}
int sn_string_view(VALUE value, const unsigned char **data, size_t *length) {
    return string_view(value, data, length);
}
static int pattern_view(VALUE value, const unsigned char **data, size_t *length) {
    int encoding = string_view(value, data, length);
    /* Read CRuby's existing ASCII cache without scanning or changing it. */
    if (encoding && RB_ENC_CODERANGE(value) == RUBY_ENC_CODERANGE_7BIT) return SN_ENCODING_SEVEN_BIT;
    return encoding;
}
int sn_pattern_view(VALUE value, const unsigned char **data, size_t *length) {
    return pattern_view(value, data, length);
}
int sn_pattern_item_view(VALUE value, const unsigned char **data, size_t *length) {
    /* Combine the exact-class guard and byte loan for homogeneous scans.
     * Negative results retain the ordinary classifier for non-string values. */
    if (RB_TYPE_P(value, T_STRING) && CLASS_OF(value) == rb_cString)
        return pattern_view(value, data, length);
    return -sn_kind(value);
}
static int json_encoding(VALUE value) {
    int encoding = RB_ENCODING_GET(value);
    return encoding == ascii_index ? SN_ENCODING_ASCII : ((encoding == utf8_index || encoding == binary_index) ? SN_ENCODING_UTF8 : SN_ENCODING_OTHER);
}
int sn_json_encoding(VALUE value) { return json_encoding(value); }
/* Ordinary String guard, original byte loan and JSON encoding metadata in one
 * call. Only String results (0..2) initialize the pointer and length. */
int sn_json_item_view(VALUE value, const unsigned char **data, size_t *length) {
    if (RB_TYPE_P(value, T_STRING) && CLASS_OF(value) == rb_cString) {
        string_raw_view(value, data, length);
        return json_encoding(value);
    }
    return -sn_kind(value);
}

struct binding { VALUE compiler, resource, name; };
static VALUE resource_program(VALUE arg) {
    struct binding *b = (struct binding *)arg;
    VALUE node = rb_funcall(b->resource, id_root, 0);
    return rb_funcall(b->compiler, id_compile, 1, node);
}
static VALUE anchor_program(VALUE arg) {
    struct binding *b = (struct binding *)arg;
    VALUE graph = rb_ivar_get(b->compiler, id_graph);
    VALUE node = rb_funcall(graph, id_dynamic_anchor, 2, b->resource, b->name);
    return NIL_P(node) ? Qnil : rb_funcall(b->compiler, id_compile, 1, node);
}
/* Anchor counts fit immediate integers: the table cannot exceed memory.
 * Reading metadata invokes no Ruby method or allocation. */
size_t sn_anchor_count(VALUE resource) {
    return (size_t)FIX2LONG(rb_ivar_get(resource, id_dynamic_anchor_count));
}
static VALUE anchor_names(VALUE arg) {
    struct binding *b = (struct binding *)arg;
    VALUE graph = rb_ivar_get(b->compiler, id_graph);
    return rb_funcall(graph, id_dynamic_anchor_names, 1, b->resource);
}
int sn_anchor_names(VALUE compiler, VALUE resource, VALUE *result) {
    struct binding b = {compiler, resource, Qnil};
    int state = 0;
    *result = rb_protect(anchor_names, (VALUE)&b, &state);
    if (state) { *result = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
int sn_resource_program(VALUE compiler, VALUE resource, VALUE *result) {
    struct binding b = {compiler, resource, Qnil};
    int state = 0;
    *result = rb_protect(resource_program, (VALUE)&b, &state);
    if (state) { *result = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
int sn_anchor_program(VALUE compiler, VALUE resource, VALUE name, VALUE *result) {
    struct binding b = {compiler, resource, name};
    int state = 0;
    *result = rb_protect(anchor_program, (VALUE)&b, &state);
    if (state) { *result = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
