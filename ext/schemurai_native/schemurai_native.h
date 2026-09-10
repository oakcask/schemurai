#ifndef SCHEMURAI_NATIVE_H
#define SCHEMURAI_NATIVE_H

#include "ruby.h"
#include "ruby/encoding.h"
#include <math.h>
#include <stdint.h>
#include <string.h>

enum opcode {
  OP_BOOLEAN,
  OP_REF,
  OP_RECURSIVE_REF,
  OP_DYNAMIC_REF,
  OP_TYPE_NULL,
  OP_TYPE_BOOLEAN,
  OP_TYPE_OBJECT,
  OP_TYPE_ARRAY,
  OP_TYPE_NUMBER,
  OP_TYPE_INTEGER,
  OP_TYPE_STRING,
  OP_TYPES,
  OP_ENUM,
  OP_CONST,
  OP_ALL_OF,
  OP_ANY_OF,
  OP_ONE_OF,
  OP_NOT,
  OP_CONDITIONAL,
  OP_NUMBER,
  OP_STRING,
  OP_ARRAY,
  OP_OBJECT,
  OP_TYPED_NUMBER,
  OP_TYPED_INTEGER,
  OP_TYPED_STRING,
  OP_TYPED_ARRAY,
  OP_TYPED_OBJECT
};

/* Immutable compiler output. Programs own a native instruction vector and
 * each operand uses the rule layout appropriate for its opcode. */
enum rule_kind { RULE_REFERENCE, RULE_TYPES, RULE_CONDITIONAL, RULE_NUMBER, RULE_STRING, RULE_ARRAY, RULE_OBJECT };

enum {
  FLAG_EVALUATION = 1,
  FLAG_DYNAMIC_SCOPE = 2,
  TYPE_NULL = 1,
  TYPE_BOOLEAN = 2,
  TYPE_OBJECT = 4,
  TYPE_ARRAY = 8,
  TYPE_NUMBER = 16,
  TYPE_INTEGER = 32,
  TYPE_STRING = 64,
  NUM_MAXIMUM = 1,
  NUM_MINIMUM = 2,
  NUM_EXCLUSIVE_MAXIMUM = 4,
  NUM_EXCLUSIVE_MINIMUM = 8,
  NUM_MULTIPLE_OF = 16
};

typedef struct {
  uint8_t opcode;
  VALUE operand;
} instruction_t;

typedef struct {
  VALUE node;
  VALUE resource;
  VALUE dynamic_anchor;
  instruction_t *instructions;
  size_t length;
  size_t capacity;
  uint8_t flags;
  bool recursive_anchor;
} program_t;

typedef struct {
  uint8_t kind;
  uint32_t mask;
  union {
    struct {
      VALUE value, fragment;
    } reference;
    struct {
      VALUE names;
    } types;
    struct {
      VALUE condition, then_branch, else_branch;
    } conditional;
    struct {
      VALUE maximum, minimum, exclusive_maximum, exclusive_minimum, multiple_of, multiple_decimal;
    } number;
    struct {
      VALUE max_length, min_length, pattern, format;
      bool format_assertion, decode_base64, parse_json;
    } string;
    struct {
      VALUE max_items, min_items, prefix_items, items;
      VALUE additional, contains, min_contains, max_contains, unevaluated;
      bool unique, items_list;
    } array;
    struct {
      VALUE max_properties, min_properties, required, properties, patterns, pattern_names;
      VALUE additional, property_names, dependencies, dependent_required;
      VALUE dependent_schemas, unevaluated;
    } object;
  } as;
} rule_t;
typedef struct {
  VALUE graph;
  VALUE programs;
} compiler_t;
#define CACHED_SCOPE_LIMIT 8
#define CACHED_SCOPE_ENTRY_LIMIT 64
typedef struct {
  VALUE rule, target, resources[CACHED_SCOPE_LIMIT];
  uint8_t length;
} scope_cache_entry_t;
typedef struct {
  VALUE graph, compiler, root;
  VALUE regexps, resolved, dynamic_scope, active;
  VALUE instance_path, schema_path, errors;
  scope_cache_entry_t *scope_cache;
  size_t scope_cache_length, scope_cache_capacity;
  bool content, format, unsupported_instance;
  long error_count;
} evaluator_t;

struct evaluator_call {
  VALUE self, instance;
  evaluator_t *e;
};

typedef struct {
  bool valid;
  VALUE properties, items;
} evaluation_t;

static inline evaluation_t evaluation(bool valid) {
  evaluation_t result = {valid, Qnil, Qnil};
  return result;
}

static inline bool has_location(VALUE list, VALUE item) {
  if (NIL_P(list))
    return false;
  return RB_TYPE_P(list, T_HASH) ? rb_hash_lookup2(list, item, Qundef) != Qundef : RTEST(rb_equal(list, item));
}

static inline bool number_p(VALUE value) {
  return RB_INTEGER_TYPE_P(value) || RB_TYPE_P(value, T_FLOAT);
}

static inline bool integer_p(VALUE value) {
  if (RB_INTEGER_TYPE_P(value))
    return true;
  if (!RB_TYPE_P(value, T_FLOAT))
    return false;
  double number = RFLOAT_VALUE(value);
  return isfinite(number) && trunc(number) == number;
}

struct protected_call {
  VALUE receiver;
  ID method;
  int argc;
  VALUE argv[3];
};

void add_unique(VALUE *list, VALUE value);
void merge_locations(VALUE *target, VALUE source);
void merge_evaluation(evaluation_t *target, evaluation_t source);
uint32_t instance_type(VALUE value, bool integer);
bool json_equal(evaluator_t *e, VALUE left, VALUE right);
bool unique_items(evaluator_t *e, VALUE value);
VALUE protected_func(VALUE arg);
VALUE regexp_for(evaluator_t *e, VALUE pattern);
bool active_enter(evaluator_t *e, VALUE source, VALUE instance);
void active_leave(evaluator_t *e, VALUE source, VALUE instance);
VALUE safe_target(evaluator_t *e, VALUE source, VALUE rule, uint8_t opcode, int *state);
bool supported_value(VALUE value);
evaluation_t evaluate_program_mode(evaluator_t *e, VALUE program, VALUE instance, bool collect);
VALUE ruby_evaluator(evaluator_t *e);
VALUE evaluator_cleanup(VALUE arg);

#define PROGRAM_PTR(value) ((program_t *)RTYPEDDATA_DATA(value))
#define RULE_PTR(value) ((rule_t *)RTYPEDDATA_DATA(value))

extern VALUE mSchemurai, mVM, mInternal, mErrorMessage, mNativeSupport;
extern VALUE cProgram, cCompiler, cEvaluator, cRule, cResult, cValidationError, cRubyEvaluator;
extern VALUE eResolutionError;
extern VALUE sym_content, sym_format, sym_vm;
extern VALUE sym_keyword, sym_instance_path, sym_schema_path, sym_message;
extern ID id_schema, id_dialect, id_keyword_mask, id_format, id_child, id_resource;
extern ID id_nodes, id_resolve, id_dynamic_anchor, id_root, id_ref_siblings_p;
extern ID id_format_assertion_p, id_key_p, id_call, id_finite_p;
extern ID id_to_i, id_to_s, id_remainder, id_zero_p, id_positive_p, id_name;
extern ID id_regexp, id_valid_content_p, id_valid_p;
extern ID id_keys, id_include_p, id_compare_by_identity, id_compare, id_length;
extern ID id_match_p, id_gsub, id_message, id_validate;
extern ID id_complex, id_rational;
extern ID id_error_any_of, id_error_const, id_error_contains, id_error_content_encoding;
extern ID id_error_content_media_type, id_error_dependent_required, id_error_enum;
extern ID id_error_false_schema, id_error_format, id_error_invalid_pattern;
extern ID id_error_multiple_of, id_error_not, id_error_numeric_limit;
extern ID id_error_one_of, id_error_pattern, id_error_required, id_error_size;
extern ID id_error_type, id_error_unique_items;

static inline VALUE hget(VALUE hash, VALUE key) {
  return rb_hash_aref(hash, key);
}

static inline bool hkey(VALUE hash, VALUE key) {
  return rb_hash_lookup2(hash, key, Qundef) != Qundef;
}

static inline VALUE node_child(VALUE node, VALUE keyword, VALUE segment, bool has_segment) {
  return has_segment ? rb_funcall(node, id_child, 2, keyword, segment) : rb_funcall(node, id_child, 1, keyword);
}

static inline int compare_values(VALUE left, VALUE right) {
  return rb_cmpint(rb_funcall(left, id_compare, 1, right), left, right);
}

static inline evaluation_t evaluate_program(evaluator_t *e, VALUE program, VALUE instance) {
  return evaluate_program_mode(e, program, instance, false);
}

#define STATIC_STRING_LIST(X)                                                                                          \
  X(REF, "$ref")                                                                                                       \
  X(RECURSIVE_REF, "$recursiveRef")                                                                                    \
  X(DYNAMIC_REF, "$dynamicRef")                                                                                        \
  X(RECURSIVE_ANCHOR, "$recursiveAnchor")                                                                              \
  X(DYNAMIC_ANCHOR, "$dynamicAnchor")                                                                                  \
  X(TYPE, "type")                                                                                                      \
  X(NULL_TYPE, "null")                                                                                                 \
  X(BOOLEAN_TYPE, "boolean")                                                                                           \
  X(OBJECT_TYPE, "object")                                                                                             \
  X(ARRAY_TYPE, "array")                                                                                               \
  X(NUMBER_TYPE, "number")                                                                                             \
  X(INTEGER_TYPE, "integer")                                                                                           \
  X(STRING_TYPE, "string")                                                                                             \
  X(ENUM, "enum")                                                                                                      \
  X(CONST, "const")                                                                                                    \
  X(ALL_OF, "allOf")                                                                                                   \
  X(ANY_OF, "anyOf")                                                                                                   \
  X(ONE_OF, "oneOf")                                                                                                   \
  X(NOT, "not")                                                                                                        \
  X(IF, "if")                                                                                                          \
  X(THEN, "then")                                                                                                      \
  X(ELSE, "else")                                                                                                      \
  X(MAXIMUM, "maximum")                                                                                                \
  X(MINIMUM, "minimum")                                                                                                \
  X(EXCLUSIVE_MAXIMUM, "exclusiveMaximum")                                                                             \
  X(EXCLUSIVE_MINIMUM, "exclusiveMinimum")                                                                             \
  X(MULTIPLE_OF, "multipleOf")                                                                                         \
  X(MAX_LENGTH, "maxLength")                                                                                           \
  X(MIN_LENGTH, "minLength")                                                                                           \
  X(PATTERN, "pattern")                                                                                                \
  X(FORMAT, "format")                                                                                                  \
  X(CONTENT_ENCODING, "contentEncoding")                                                                               \
  X(CONTENT_MEDIA_TYPE, "contentMediaType")                                                                            \
  X(BASE64, "base64")                                                                                                  \
  X(APPLICATION_JSON, "application/json")                                                                              \
  X(MAX_ITEMS, "maxItems")                                                                                             \
  X(MIN_ITEMS, "minItems")                                                                                             \
  X(UNIQUE_ITEMS, "uniqueItems")                                                                                       \
  X(PREFIX_ITEMS, "prefixItems")                                                                                       \
  X(ITEMS, "items")                                                                                                    \
  X(ADDITIONAL_ITEMS, "additionalItems")                                                                               \
  X(CONTAINS, "contains")                                                                                              \
  X(MIN_CONTAINS, "minContains")                                                                                       \
  X(MAX_CONTAINS, "maxContains")                                                                                       \
  X(UNEVALUATED_ITEMS, "unevaluatedItems")                                                                             \
  X(MAX_PROPERTIES, "maxProperties")                                                                                   \
  X(MIN_PROPERTIES, "minProperties")                                                                                   \
  X(REQUIRED, "required")                                                                                              \
  X(PROPERTIES, "properties")                                                                                          \
  X(PATTERN_PROPERTIES, "patternProperties")                                                                           \
  X(ADDITIONAL_PROPERTIES, "additionalProperties")                                                                     \
  X(PROPERTY_NAMES, "propertyNames")                                                                                   \
  X(DEPENDENCIES, "dependencies")                                                                                      \
  X(DEPENDENT_REQUIRED, "dependentRequired")                                                                           \
  X(DEPENDENT_SCHEMAS, "dependentSchemas")                                                                             \
  X(UNEVALUATED_PROPERTIES, "unevaluatedProperties")                                                                   \
  X(FALSE_SCHEMA, "falseSchema")                                                                                       \
  X(TILDE, "~")                                                                                                        \
  X(ESCAPED_TILDE, "~0")                                                                                               \
  X(SLASH, "/")                                                                                                        \
  X(ESCAPED_SLASH, "~1")

enum static_string_index {
#define ENUM_STATIC_STRING(name, value) STATIC_STRING_##name,
  STATIC_STRING_LIST(ENUM_STATIC_STRING)
#undef ENUM_STATIC_STRING
      STATIC_STRING_COUNT
};

extern VALUE static_strings[STATIC_STRING_COUNT];
#define STATIC_STRING(name) static_strings[STATIC_STRING_##name]

extern const rb_data_type_t program_type;
extern const rb_data_type_t rule_type;
extern const rb_data_type_t compiler_type;
extern const rb_data_type_t evaluator_type;

VALUE program_alloc(VALUE klass);
VALUE compiler_alloc(VALUE klass);
VALUE evaluator_alloc(VALUE klass);
VALUE rule_new(uint8_t kind);
void emit(VALUE program, uint8_t opcode, VALUE operand);
VALUE decimal(VALUE value);

VALUE compiler_initialize(VALUE self, VALUE graph);
VALUE compiler_compile(VALUE self, VALUE node);
VALUE compiler_compile_all(VALUE self);
VALUE compiler_resolve(VALUE self, VALUE program, VALUE reference);
VALUE compiler_evaluator(int argc, VALUE *argv, VALUE self);
VALUE evaluator_backend(VALUE self);
VALUE evaluator_valid(VALUE self, VALUE instance);
VALUE evaluator_validate(VALUE self, VALUE instance);

#endif
