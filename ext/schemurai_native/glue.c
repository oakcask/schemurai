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
extern size_t sn_root_count(const void *);
extern VALUE sn_root_at(const void *, size_t);
extern void *sn_caches_new(void);
extern void sn_caches_free(void *);
extern size_t sn_caches_size(const void *);
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
static VALUE valid(VALUE self, VALUE instance) {
    holder *h;
    TypedData_Get_Struct(self, holder, &engine_type, h);
    if (!h->engine) rb_raise(rb_eRuntimeError, "uninitialized native program");
    if (h->compiling) rb_raise(rb_eRuntimeError, "native program is still compiling");
    int status = sn_valid(h->engine, NULL, sn_root_index(h->engine), instance);
    RB_GC_GUARD(instance);
    if (status < 0) rb_raise(rb_eRuntimeError, "native evaluator panicked");
    return status == SN_VERDICT_UNSUPPORTED ? Qnil : (status ? Qtrue : Qfalse);
}
/* Search caches and root selection belong to the owning validator. The Ruby
 * owner keeps the shared engine and all its GC roots alive. */
typedef struct { VALUE owner; void *caches; size_t root; } runner_holder;
static void runner_mark(void *ptr) { rb_gc_mark(((runner_holder *)ptr)->owner); }
static void runner_release(void *ptr) {
    runner_holder *h = ptr;
    if (h->caches) sn_caches_free(h->caches);
    xfree(h);
}
static size_t runner_size(const void *ptr) {
    const runner_holder *h = ptr;
    return sizeof(*h) + (h->caches ? sn_caches_size(h->caches) : 0);
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
    VALUE klass = rb_const_get(rb_obj_class(self), rb_intern_const("Runner"));
    runner_holder *r;
    VALUE object = TypedData_Make_Struct(klass, runner_holder, &runner_type, r);
    r->owner = self;
    r->root = index;
    r->caches = sn_caches_new();
    RB_GC_GUARD(self);
    return object;
}
typedef struct { size_t max_errors, max_output_bytes, max_evaluations; uint32_t enabled; } native_limits;
typedef struct { size_t spent; uint32_t kind; size_t attempted; } native_outcome;
extern int sn_valid_with_limits(const void *, const void *, size_t, VALUE, const native_limits *, native_outcome *);
static native_limits read_limits(VALUE budget) {
    VALUE caps = rb_funcall(budget, rb_intern("native_caps"), 0);
    native_limits limits = {0};
    size_t *targets[] = {&limits.max_errors, &limits.max_output_bytes, &limits.max_evaluations};
    for (size_t i = 0; i < 3; i++) {
        VALUE cap = rb_ary_entry(caps, i);
        if (!NIL_P(cap)) { *targets[i] = NUM2SIZET(cap); limits.enabled |= 1u << i; }
    }
    RB_GC_GUARD(caps);
    return limits;
}
static void finish_budget(VALUE budget, const native_outcome *outcome) {
    rb_funcall(budget, rb_intern("evaluations"), 1, SIZET2NUM(outcome->spent));
    if (outcome->kind) rb_funcall(budget, rb_intern("raise_native_limit"), 2, UINT2NUM(outcome->kind), SIZET2NUM(outcome->attempted));
}
static VALUE runner_valid_with_budget(VALUE self, VALUE instance, VALUE budget) {
    runner_holder *r;
    TypedData_Get_Struct(self, runner_holder, &runner_type, r);
    holder *h = ready_program(r->owner);
    native_limits limits = read_limits(budget);
    native_outcome outcome = {0};
    int status = sn_valid_with_limits(h->engine, r->caches, r->root, instance, &limits, &outcome);
    if (status < 0) rb_raise(rb_eRuntimeError, "native evaluator panicked");
    finish_budget(budget, &outcome);
    RB_GC_GUARD(instance);
    RB_GC_GUARD(self);
    return status == SN_VERDICT_UNSUPPORTED ? Qnil : (status ? Qtrue : Qfalse);
}
static VALUE runner_valid(VALUE self, VALUE instance) {
    runner_holder *r;
    TypedData_Get_Struct(self, runner_holder, &runner_type, r);
    holder *h = ready_program(r->owner);
    int status = sn_valid(h->engine, r->caches, r->root, instance);
    RB_GC_GUARD(instance);
    RB_GC_GUARD(self);
    if (status < 0) rb_raise(rb_eRuntimeError, "native evaluator panicked");
    return status == SN_VERDICT_UNSUPPORTED ? Qnil : (status ? Qtrue : Qfalse);
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
    return SN_TYPE_UNSUPPORTED; /* Out-of-domain objects are handled by the Ruby VM. */
}
size_t sn_scalar_bytes(VALUE value) {
    if (RB_TYPE_P(value, T_STRING)) return RSTRING_LEN(value);
    if (RB_TYPE_P(value, T_HASH)) return RHASH_SIZE(value);
    if (RB_INTEGER_TYPE_P(value)) return rb_absint_size(value, NULL);
    return 1;
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
    int opcode;
    VALUE operand, instance;
    size_t detail;
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
static VALUE collect_diagnostics(VALUE self, VALUE instance, holder *engine, const void *caches, size_t root, VALUE budget) {
    report_holder *h;
    VALUE owner = TypedData_Make_Struct(rb_cObject, report_holder, &report_type, h);
    h->report = NULL;
    int status = 0;
    native_outcome outcome = {0};
    if (NIL_P(budget)) {
        h->report = sn_diagnose(engine->engine, caches, root, instance, &status);
    } else {
        native_limits limits = read_limits(budget);
        h->report = sn_diagnose_with_limits(engine->engine, caches, root, instance, &status, &limits, &outcome);
    }
    if (status < 0) rb_raise(rb_eRuntimeError, "native diagnostics panicked");
    if (!NIL_P(budget)) finish_budget(budget, &outcome);
    if (status == SN_VERDICT_UNSUPPORTED) return Qnil;
    size_t count = sn_report_len(h->report);
    VALUE output = rb_ary_new_capa(count);
    for (size_t index = 0; index < count; index++) {
        diagnostic_record r;
        sn_report_record(h->report, index, &r);
        VALUE row = rb_ary_new_capa(7);
        rb_ary_push(output, row);
        rb_ary_push(row, rb_utf8_str_new((const char *)r.keyword, r.keyword_len));
        rb_ary_push(row, rb_utf8_str_new((const char *)r.instance_path, r.instance_len));
        rb_ary_push(row, rb_utf8_str_new((const char *)r.schema_path, r.schema_len));
        rb_ary_push(row, INT2NUM(r.opcode));
        rb_ary_push(row, r.operand);
        rb_ary_push(row, r.instance);
        rb_ary_push(row, SIZET2NUM(r.detail));
    }
    RB_GC_GUARD(owner);
    RB_GC_GUARD(instance);
    RB_GC_GUARD(self);
    return output;
}
static VALUE diagnostics(VALUE self, VALUE instance) {
    holder *h = ready_program(self);
    return collect_diagnostics(self, instance, h, NULL, sn_root_index(h->engine), Qnil);
}
static VALUE runner_diagnostics(VALUE self, VALUE instance) {
    runner_holder *r;
    TypedData_Get_Struct(self, runner_holder, &runner_type, r);
    holder *h = ready_program(r->owner);
    return collect_diagnostics(self, instance, h, r->caches, r->root, Qnil);
}
static VALUE runner_diagnostics_with_budget(VALUE self, VALUE instance, VALUE budget) {
    runner_holder *r;
    TypedData_Get_Struct(self, runner_holder, &runner_type, r);
    holder *h = ready_program(r->owner);
    return collect_diagnostics(self, instance, h, r->caches, r->root, budget);
}
void Init_schemurai_native(void) {
    /* Cache fixed IDs explicitly, independent of compiler-specific macros. */
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
int sn_string_utf8(VALUE value) { return string_utf8(value); }
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
