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
extern int sn_valid(const void *, const void *, size_t, VALUE);
extern size_t sn_node_index(const void *, VALUE);
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
extern size_t sn_pointer_parts(const void *);
extern void sn_pointer_part(const void *, size_t, const unsigned char **, size_t *, VALUE *);
extern void sn_pointer_result(const void *, VALUE);
typedef struct {
    const unsigned char *keyword;
    size_t keyword_len;
    int opcode;
    VALUE operand, instance;
    size_t detail;
} message_arguments;
extern void sn_message_arguments(const void *, message_arguments *);
extern void sn_message_result(const void *, VALUE);
typedef struct { VALUE ordinal, rules, instance; } number_arguments;
extern void sn_number_arguments(const void *, number_arguments *);
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
    if (status < 0) {
        sn_free(h->engine);
        h->engine = NULL;
        h->roots = NULL;
        if (status == SN_STATUS_EXCEPTION) rb_exc_raise(error);
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
typedef struct { VALUE owner, regexps, pointers, messages, numbers, number_state, limited_number_state; void *caches; size_t root; st_table *matches, *number_frames; } runner_holder;
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
    rb_gc_mark(r->regexps);
    rb_gc_mark(r->pointers);
    rb_gc_mark(r->messages);
    rb_gc_mark(r->numbers);
    rb_gc_mark(r->number_state);
    rb_gc_mark(r->limited_number_state);
    if (r->caches) sn_caches_mark(r->caches);
    if (r->matches) st_foreach(r->matches, mark_operation, 0);
}
static void runner_release(void *ptr) {
    runner_holder *h = ptr;
    if (h->caches) sn_caches_free(h->caches);
    if (h->number_frames) st_free_table(h->number_frames);
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
    if (h->number_frames) bytes += st_memsize(h->number_frames);
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
    r->regexps = Qnil;
    r->pointers = Qnil;
    r->messages = Qnil;
    r->numbers = Qnil;
    r->number_state = Qnil;
    r->limited_number_state = Qnil;
    r->root = index;
    r->caches = NULL;
    r->matches = NULL;
    r->number_frames = NULL;
    r->number_frames = st_init_numtable();
    r->matches = st_init_numtable();
    r->caches = sn_caches_new();
    sn_caches_runtime(r->caches, r->matches);
    RB_GC_GUARD(self);
    return object;
}
typedef struct { size_t max_errors; uint32_t enabled; double timeout; } native_limits;
typedef struct { uint32_t kind; size_t attempted; } native_outcome;
extern int sn_valid_with_limits(const void *, const void *, size_t, VALUE, const native_limits *, native_outcome *);
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
    return SN_TYPE_UNSUPPORTED; /* Out-of-domain objects are handled by the Ruby VM. */
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

struct access { VALUE object; const char *name; };
static VALUE get_field(VALUE arg) {
    struct access *a = (struct access *)arg;
    return rb_funcall(a->object, rb_intern_const(a->name), 0);
}
/* Rust supplies a fixed, NUL-terminated field name from a static byte string. */
int sn_field(VALUE object, const char *name, VALUE *value) {
    struct access a = {object, name};
    int state = 0;
    *value = rb_protect(get_field, (VALUE)&a, &state);
    if (state) { *value = rb_errinfo(); rb_set_errinfo(Qnil); }
    return state;
}
static struct { ID id; const char *symbol; int opcode; } opcodes[] = {
#define SN_OPCODE(name, symbol, value) {0, #symbol, SN_OP_##name},
#define SN_CONSTANT(name, value)
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
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
extern void *sn_diagnose(const void *, const void *, size_t, VALUE, int *);
extern void *sn_diagnose_with_limits(const void *, const void *, size_t, VALUE, int *, const native_limits *, native_outcome *);
extern size_t sn_report_len(const void *);
extern size_t sn_report_size(const void *);
extern void sn_report_record(const void *, size_t, diagnostic_record *);
extern void sn_report_mark(const void *);
extern void sn_report_free(void *);
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
} evaluation_call;

static VALUE clear_runtime(VALUE context) {
    evaluation_call *call = (evaluation_call *)context;
    st_foreach(call->runner->matches, release_operation, 0);
    st_clear(call->runner->matches);
    call->runner->pointers = Qnil;
    call->runner->messages = Qnil;
    call->runner->numbers = Qnil;
    call->runner->limited_number_state = Qnil;
    st_clear(call->runner->number_frames);
    sn_caches_runtime(call->runner->caches, call->runner->matches);
    sn_caches_begin(call->runner->caches);
    return Qnil;
}
static void evaluate_native(evaluation_call *call) {
    runner_holder *r = call->runner;
    native_outcome outcome = {0};
    native_limits limits = {0};
    if (!NIL_P(call->budget)) limits = read_limits(call->budget);
    const void *previous_caches = active_caches;
    active_caches = r->caches;
    if (call->report) {
        if (NIL_P(call->budget)) {
            call->report->report = sn_diagnose(call->engine->engine, r->caches, r->root,
                call->instance, &call->status);
        } else {
            call->report->report = sn_diagnose_with_limits(call->engine->engine, r->caches, r->root,
                call->instance, &call->status, &limits, &outcome);
        }
    } else if (NIL_P(call->budget)) {
        call->status = sn_valid(call->engine->engine, r->caches, r->root, call->instance);
    } else {
        call->status = sn_valid_with_limits(call->engine->engine, r->caches, r->root,
            call->instance, &limits, &outcome);
    }
    active_caches = previous_caches;
    check_evaluation_status(call->status,
        call->report ? "native diagnostics panicked" : "native evaluator panicked");
    if (!NIL_P(call->budget)) finish_budget(call->budget, &outcome);
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
    VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
    VALUE native = rb_const_get(schemurai, rb_intern_const("Native"));
    VALUE helper = rb_const_get(native, rb_intern_const("Diagnostics"));
    VALUE result = rb_funcall(helper, rb_intern_const("message"), 5, keyword,
        INT2NUM(arguments.opcode), arguments.operand, arguments.instance, SIZET2NUM(arguments.detail));
    RB_GC_GUARD(keyword);
    RB_GC_GUARD(helper);
    return result;
}
static VALUE number_step(runner_holder *runner, int operation, VALUE budget) {
    number_arguments arguments;
    sn_number_arguments(runner->caches, &arguments);
    st_data_t stored;
    VALUE frame;
    if (st_lookup(runner->number_frames, (st_data_t)arguments.ordinal, &stored)) {
        frame = rb_ary_entry(runner->numbers, (long)stored);
    } else {
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE checks = rb_const_get(internal, rb_intern_const("NumberChecks"));
        VALUE *number_state = NIL_P(budget) ? &runner->number_state : &runner->limited_number_state;
        if (NIL_P(*number_state)) {
            VALUE state = rb_const_get(checks, rb_intern_const("State"));
            *number_state = rb_class_new_instance(0, NULL, state);
            if (!NIL_P(budget)) rb_funcall(*number_state, rb_intern_const("budget="), 1, budget);
        }
        VALUE klass = rb_const_get(checks, rb_intern_const("Frame"));
        VALUE args[] = {arguments.rules, arguments.instance, *number_state};
        frame = rb_class_new_instance(3, args, klass);
        if (NIL_P(runner->numbers)) runner->numbers = rb_ary_new();
        size_t index = RARRAY_LEN(runner->numbers);
        rb_ary_push(runner->numbers, frame);
        /* Array indices remain valid if compaction moves a frame. */
        st_insert(runner->number_frames, (st_data_t)arguments.ordinal, (st_data_t)index);
    }
    int selector = operation - SN_RUNTIME_NUMBER;
    int step = selector >> 6;
    VALUE result;
    switch (step) {
        case 0: result = rb_funcall(frame, rb_intern_const("valid?"), 1, INT2FIX(selector & 63)); break;
        case 1: result = rb_funcall(frame, rb_intern_const("numeric?"), 0); break;
        case 2: result = rb_funcall(frame, rb_intern_const("integral?"), 0); break;
        case 3: result = rb_funcall(frame, rb_intern_const("prepare"), 0); break;
        default: result = rb_funcall(frame, rb_intern_const("check"), 1, INT2FIX(1 << (step - 4))); break;
    }
    RB_GC_GUARD(frame);
    return result;
}
typedef struct { evaluation_call *call; VALUE source, instance; int kind; } runtime_call;
static VALUE call_runtime(VALUE context) {
    runtime_call *operation = (runtime_call *)context;
    evaluation_call *call = operation->call;
    VALUE source = operation->source, instance = operation->instance;
    runner_holder *r = call->runner;
    if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
    if (operation->kind >= SN_RUNTIME_NUMBER) {
        VALUE result = number_step(r, operation->kind, operation->call->budget);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind >= SN_RUNTIME_TYPE) {
        int selector = operation->kind - SN_RUNTIME_TYPE;
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE helper = rb_const_get(internal, rb_intern_const("TypeChecks"));
        VALUE result = rb_funcall(helper, rb_intern_const("valid?"), 3, instance,
            INT2FIX(selector >> 1), (selector & 1) ? Qtrue : Qfalse);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind == SN_RUNTIME_DIAGNOSTIC_MESSAGE) {
        VALUE message = build_message(r);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return message;
    }
    if (operation->kind == SN_RUNTIME_REQUIRED_MISSING) {
        VALUE present = rb_funcallv_public(instance, rb_intern_const("key?"), 1, &source);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return RTEST(present) ? Qfalse : Qtrue;
    }
    if (operation->kind >= SN_RUNTIME_NULL_NUMBER) {
        VALUE result = null_numeric(instance, operation->kind);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return result;
    }
    if (operation->kind == SN_RUNTIME_IDENTITY_METHODS) {
        for (size_t index = 0; index < sizeof(identity_methods) / sizeof(*identity_methods); index++)
            if (!rb_method_basic_definition_p(source, identity_methods[index])) return Qfalse;
        return Qtrue;
    }
    if (operation->kind == SN_RUNTIME_POINTER) {
        VALUE pointer = build_pointer(r);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return pointer;
    }
    if (operation->kind == SN_RUNTIME_JSON) {
        VALUE json = rb_const_get(rb_cObject, rb_intern_const("JSON"));
        rb_funcall(json, rb_intern_const("parse"), 1, instance);
        if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
        return Qtrue;
    }
    if (NIL_P(r->regexps)) r->regexps = rb_hash_new();
    VALUE regexp = rb_hash_lookup2(r->regexps, source, Qundef);
    if (regexp == Qundef) {
        VALUE schemurai = rb_const_get(rb_cObject, id_schemurai);
        VALUE internal = rb_const_get(schemurai, rb_intern_const("Internal"));
        VALUE compiler = rb_const_get(internal, rb_intern_const("EcmaRegexp"));
        regexp = rb_funcall(compiler, id_compile, 2, source, call->budget);
        rb_hash_aset(r->regexps, source, regexp);
    }
    VALUE result = rb_funcall(regexp, rb_intern_const("match?"), 1, instance);
    if (!NIL_P(call->budget)) rb_funcall(call->budget, rb_intern_const("check_deadline!"), 0);
    RB_GC_GUARD(regexp);
    return result;
}
static void evaluate_runtime(evaluation_call *call, VALUE source, VALUE instance, int kind) {
    runtime_call operation = {call, source, instance, kind};
    VALUE previous = rb_errinfo();
    int state = 0;
    VALUE result = rb_protect(call_runtime, (VALUE)&operation, &state);
    int verdict;
    if (state) {
        VALUE error = rb_errinfo();
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
 * memo entries and partial reports. Only pure assertion observations are cached.
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
        evaluate_runtime(call, source, instance, operation);
        sn_caches_runtime(call->runner->caches, call->runner->matches);
        evaluate_native(call);
    }
    return Qnil;
}
static VALUE evaluate_runner(VALUE self, VALUE instance, VALUE budget, int diagnostics) {
    runner_holder *r;
    TypedData_Get_Struct(self, runner_holder, &runner_type, r);
    evaluation_call call = {self, instance, budget, r, ready_program(r->owner), NULL, 0};
    report_holder *h = NULL;
    VALUE owner = Qnil;
    if (diagnostics) {
        owner = TypedData_Make_Struct(rb_cObject, report_holder, &report_type, h);
        h->report = NULL;
        call.report = h;
    }
    clear_runtime((VALUE)&call);
    evaluate_native(&call);
    VALUE source = Qnil, requested = Qnil;
    int operation = 0;
    if (call.status == SN_VERDICT_UNSUPPORTED &&
        sn_caches_pending(r->caches, &source, &requested, &operation)) {
        rb_ensure(retry_runtime, (VALUE)&call, clear_runtime, (VALUE)&call);
    }
    if (call.status == SN_VERDICT_UNSUPPORTED || !diagnostics) {
        VALUE result = call.status == SN_VERDICT_UNSUPPORTED ? Qnil : (call.status ? Qtrue : Qfalse);
        RB_GC_GUARD(owner);
        RB_GC_GUARD(instance);
        RB_GC_GUARD(self);
        return result;
    }
    size_t count = sn_report_len(h->report);
    VALUE output = rb_ary_new_capa(count);
    for (size_t index = 0; index < count; index++) {
        if (!NIL_P(budget) && index % 256 == 0) rb_funcall(budget, rb_intern("check_deadline!"), 0);
        diagnostic_record r;
        sn_report_record(h->report, index, &r);
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
    RB_GC_GUARD(owner);
    RB_GC_GUARD(instance);
    RB_GC_GUARD(self);
    return output;
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
    rb_ext_ractor_safe(true);
    VALUE schemurai = rb_define_module("Schemurai");
    VALUE native = rb_define_module_under(schemurai, "Native");
    VALUE protocol = rb_define_module_under(native, "Protocol");
#define SN_OPCODE(name, symbol, value) rb_define_const(protocol, "OP_" #name, INT2NUM(SN_OP_##name));
#define SN_CONSTANT(name, value) rb_define_const(protocol, #name, INT2NUM(SN_##name));
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
    VALUE klass = rb_define_class_under(native, "Program", rb_cObject);
    rb_define_alloc_func(klass, allocate);
    rb_define_method(klass, "initialize", initialize, 4);
    rb_define_method(klass, "valid?", valid, 1);
    rb_define_method(klass, "diagnostics", diagnostics, 1);
    rb_define_method(klass, "make_shareable", make_shareable, 0);
    rb_define_method(klass, "runner", runner, 1);
    rb_define_method(klass, "unresolved_references?", has_unresolved_references, 0);
    VALUE runner_class = rb_define_class_under(klass, "Runner", rb_cObject);
    rb_undef_alloc_func(runner_class);
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
