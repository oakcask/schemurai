#include "schemurai_native.h"

VALUE mSchemurai, mVM, mInternal, mErrorMessage, mNativeSupport;
VALUE cProgram, cCompiler, cEvaluator, cRule, cResult, cValidationError, cRubyEvaluator;
VALUE eResolutionError;
VALUE sym_content, sym_format, sym_vm;
VALUE sym_keyword, sym_instance_path, sym_schema_path, sym_message;
ID id_schema, id_dialect, id_keyword_mask, id_format, id_child, id_resource;
ID id_nodes, id_resolve, id_dynamic_anchor, id_root, id_ref_siblings_p;
ID id_format_assertion_p, id_key_p, id_call, id_finite_p;
ID id_to_i, id_to_s, id_remainder, id_zero_p, id_positive_p, id_name;
ID id_regexp, id_valid_content_p, id_valid_p;
ID id_keys, id_include_p, id_compare_by_identity, id_compare, id_length;
ID id_match_p, id_gsub, id_message, id_validate;
ID id_complex, id_rational;
ID id_error_any_of, id_error_const, id_error_contains, id_error_content_encoding;
ID id_error_content_media_type, id_error_dependent_required, id_error_enum;
ID id_error_false_schema, id_error_format, id_error_invalid_pattern;
ID id_error_multiple_of, id_error_not, id_error_numeric_limit;
ID id_error_one_of, id_error_pattern, id_error_required, id_error_size;
ID id_error_type, id_error_unique_items;

VALUE static_strings[STATIC_STRING_COUNT];

static void program_mark(void *ptr) {
  program_t *p = ptr;
  rb_gc_mark_movable(p->node);
  rb_gc_mark_movable(p->resource);
  rb_gc_mark_movable(p->dynamic_anchor);
  for (size_t i = 0; i < p->length; i++)
    rb_gc_mark_movable(p->instructions[i].operand);
}
static void program_compact(void *ptr) {
  program_t *p = ptr;
  p->node = rb_gc_location(p->node);
  p->resource = rb_gc_location(p->resource);
  p->dynamic_anchor = rb_gc_location(p->dynamic_anchor);
  for (size_t i = 0; i < p->length; i++)
    p->instructions[i].operand = rb_gc_location(p->instructions[i].operand);
}
static void program_free(void *ptr) {
  program_t *p = ptr;
  xfree(p->instructions);
  xfree(p);
}
static size_t program_size(const void *ptr) {
  const program_t *p = ptr;
  return sizeof(*p) + p->capacity * sizeof(instruction_t);
}
const rb_data_type_t program_type = {"Schemurai::VM::Program",
                                     {program_mark, program_free, program_size, program_compact, {0}},
                                     0,
                                     0,
                                     RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED |
                                         RUBY_TYPED_FROZEN_SHAREABLE};

enum rule_value_action { RULE_VALUE_INITIALIZE, RULE_VALUE_MARK, RULE_VALUE_COMPACT };

static void rule_value(VALUE *value, enum rule_value_action action) {
  if (action == RULE_VALUE_INITIALIZE)
    *value = Qnil;
  else if (action == RULE_VALUE_MARK)
    rb_gc_mark_movable(*value);
  else
    *value = rb_gc_location(*value);
}

static void rule_each_value(rule_t *r, enum rule_value_action action) {
#define VISIT(field) rule_value(&r->as.field, action)
  switch (r->kind) {
  case RULE_REFERENCE:
    VISIT(reference.value);
    VISIT(reference.fragment);
    break;
  case RULE_TYPES:
    VISIT(types.names);
    break;
  case RULE_CONDITIONAL:
    VISIT(conditional.condition);
    VISIT(conditional.then_branch);
    VISIT(conditional.else_branch);
    break;
  case RULE_NUMBER:
    VISIT(number.maximum);
    VISIT(number.minimum);
    VISIT(number.exclusive_maximum);
    VISIT(number.exclusive_minimum);
    VISIT(number.multiple_of);
    VISIT(number.multiple_decimal);
    break;
  case RULE_STRING:
    VISIT(string.max_length);
    VISIT(string.min_length);
    VISIT(string.pattern);
    VISIT(string.format);
    break;
  case RULE_ARRAY:
    VISIT(array.max_items);
    VISIT(array.min_items);
    VISIT(array.prefix_items);
    VISIT(array.items);
    VISIT(array.additional);
    VISIT(array.contains);
    VISIT(array.min_contains);
    VISIT(array.max_contains);
    VISIT(array.unevaluated);
    break;
  case RULE_OBJECT:
    VISIT(object.max_properties);
    VISIT(object.min_properties);
    VISIT(object.required);
    VISIT(object.properties);
    VISIT(object.patterns);
    VISIT(object.pattern_names);
    VISIT(object.additional);
    VISIT(object.property_names);
    VISIT(object.dependencies);
    VISIT(object.dependent_required);
    VISIT(object.dependent_schemas);
    VISIT(object.unevaluated);
    break;
  default:
    break;
  }
#undef VISIT
}
static void rule_mark(void *ptr) {
  rule_each_value(ptr, RULE_VALUE_MARK);
}
static void rule_compact(void *ptr) {
  rule_each_value(ptr, RULE_VALUE_COMPACT);
}
static size_t rule_size(const void *ptr) {
  return sizeof(rule_t);
}
const rb_data_type_t rule_type = {"Schemurai::VM::Rule",
                                  {rule_mark, RUBY_TYPED_DEFAULT_FREE, rule_size, rule_compact, {0}},
                                  0,
                                  0,
                                  RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FROZEN_SHAREABLE};

static void compiler_mark(void *ptr) {
  compiler_t *c = ptr;
  rb_gc_mark_movable(c->graph);
  rb_gc_mark_movable(c->programs);
}
static void compiler_compact(void *ptr) {
  compiler_t *c = ptr;
  c->graph = rb_gc_location(c->graph);
  c->programs = rb_gc_location(c->programs);
}
static size_t compiler_size(const void *ptr) {
  return sizeof(compiler_t);
}
const rb_data_type_t compiler_type = {"Schemurai::VM::Compiler",
                                      {compiler_mark, RUBY_TYPED_DEFAULT_FREE, compiler_size, compiler_compact, {0}},
                                      0,
                                      0,
                                      RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED |
                                          RUBY_TYPED_FROZEN_SHAREABLE};

static void evaluator_mark(void *ptr) {
  evaluator_t *e = ptr;
  rb_gc_mark_movable(e->graph);
  rb_gc_mark_movable(e->compiler);
  rb_gc_mark_movable(e->root);
  rb_gc_mark_movable(e->regexps);
  rb_gc_mark_movable(e->resolved);
  rb_gc_mark_movable(e->dynamic_scope);
  rb_gc_mark_movable(e->active);
  rb_gc_mark_movable(e->instance_path);
  rb_gc_mark_movable(e->schema_path);
  rb_gc_mark_movable(e->errors);
  for (size_t i = 0; i < e->scope_cache_length; i++) {
    rb_gc_mark_movable(e->scope_cache[i].rule);
    rb_gc_mark_movable(e->scope_cache[i].target);
    for (uint8_t j = 0; j < e->scope_cache[i].length; j++)
      rb_gc_mark_movable(e->scope_cache[i].resources[j]);
  }
}
static void evaluator_compact(void *ptr) {
  evaluator_t *e = ptr;
  e->graph = rb_gc_location(e->graph);
  e->compiler = rb_gc_location(e->compiler);
  e->root = rb_gc_location(e->root);
  e->regexps = rb_gc_location(e->regexps);
  e->resolved = rb_gc_location(e->resolved);
  e->dynamic_scope = rb_gc_location(e->dynamic_scope);
  e->active = rb_gc_location(e->active);
  e->instance_path = rb_gc_location(e->instance_path);
  e->schema_path = rb_gc_location(e->schema_path);
  e->errors = rb_gc_location(e->errors);
  for (size_t i = 0; i < e->scope_cache_length; i++) {
    e->scope_cache[i].rule = rb_gc_location(e->scope_cache[i].rule);
    e->scope_cache[i].target = rb_gc_location(e->scope_cache[i].target);
    for (uint8_t j = 0; j < e->scope_cache[i].length; j++)
      e->scope_cache[i].resources[j] = rb_gc_location(e->scope_cache[i].resources[j]);
  }
}
static void evaluator_free(void *ptr) {
  evaluator_t *e = ptr;
  xfree(e->scope_cache);
  xfree(e);
}
static size_t evaluator_size(const void *ptr) {
  const evaluator_t *e = ptr;
  return sizeof(*e) + e->scope_cache_capacity * sizeof(scope_cache_entry_t);
}
const rb_data_type_t evaluator_type = {"Schemurai::VM::Evaluator",
                                       {evaluator_mark, evaluator_free, evaluator_size, evaluator_compact, {0}},
                                       0,
                                       0,
                                       RUBY_TYPED_FREE_IMMEDIATELY};

VALUE program_alloc(VALUE klass) {
  program_t *p;
  return TypedData_Make_Struct(klass, program_t, &program_type, p);
}
VALUE compiler_alloc(VALUE klass) {
  compiler_t *c;
  return TypedData_Make_Struct(klass, compiler_t, &compiler_type, c);
}
VALUE evaluator_alloc(VALUE klass) {
  evaluator_t *e;
  return TypedData_Make_Struct(klass, evaluator_t, &evaluator_type, e);
}

VALUE rule_new(uint8_t kind) {
  rule_t *r;
  VALUE obj = TypedData_Make_Struct(cRule, rule_t, &rule_type, r);
  r->kind = kind;
  r->mask = 0;
  rule_each_value(r, RULE_VALUE_INITIALIZE);
  return obj;
}

void emit(VALUE program, uint8_t opcode, VALUE operand) {
  program_t *p;
  TypedData_Get_Struct(program, program_t, &program_type, p);
  if (p->length == p->capacity) {
    size_t capacity = p->capacity ? p->capacity * 2 : 8;
    REALLOC_N(p->instructions, instruction_t, capacity);
    p->capacity = capacity;
  }
  RB_OBJ_WRITE(program, &p->instructions[p->length].operand, operand);
  p->instructions[p->length].opcode = opcode;
  p->length++;
}

static void initialize_static_strings(void) {
#define INITIALIZE_STATIC_STRING(name, literal)                                                                        \
  do {                                                                                                                 \
    static_strings[STATIC_STRING_##name] = rb_obj_freeze(rb_str_new_static(literal, (long)(sizeof(literal) - 1)));     \
    rb_gc_register_address(&static_strings[STATIC_STRING_##name]);                                                     \
  } while (0);
  STATIC_STRING_LIST(INITIALIZE_STATIC_STRING)
#undef INITIALIZE_STATIC_STRING
}

void Init_schemurai_native(void) {
  rb_ext_ractor_safe(true);
  initialize_static_strings();

  id_schema = rb_intern_const("schema");
  id_dialect = rb_intern_const("dialect");
  id_keyword_mask = rb_intern_const("keyword_mask");
  id_format = rb_intern_const("format");
  id_child = rb_intern_const("child");
  id_resource = rb_intern_const("resource");
  id_nodes = rb_intern_const("nodes");
  id_resolve = rb_intern_const("resolve");
  id_dynamic_anchor = rb_intern_const("dynamic_anchor");
  id_root = rb_intern_const("root");
  id_ref_siblings_p = rb_intern_const("ref_siblings?");
  id_format_assertion_p = rb_intern_const("format_assertion?");
  id_key_p = rb_intern_const("key?");
  id_call = rb_intern_const("call");
  id_finite_p = rb_intern_const("finite?");
  id_to_i = rb_intern_const("to_i");
  id_to_s = rb_intern_const("to_s");
  id_remainder = rb_intern_const("remainder");
  id_zero_p = rb_intern_const("zero?");
  id_positive_p = rb_intern_const("positive?");
  id_name = rb_intern_const("name");
  id_regexp = rb_intern_const("regexp");
  id_valid_content_p = rb_intern_const("valid_content?");
  id_valid_p = rb_intern_const("valid?");
  id_keys = rb_intern_const("keys");
  id_include_p = rb_intern_const("include?");
  id_compare_by_identity = rb_intern_const("compare_by_identity");
  id_compare = rb_intern_const("<=>");
  id_length = rb_intern_const("length");
  id_match_p = rb_intern_const("match?");
  id_gsub = rb_intern_const("gsub");
  id_message = rb_intern_const("message");
  id_validate = rb_intern_const("validate");
  id_complex = rb_intern_const("Complex");
  id_rational = rb_intern_const("Rational");
  id_error_any_of = rb_intern_const("any_of");
  id_error_const = rb_intern_const("const");
  id_error_contains = rb_intern_const("contains");
  id_error_content_encoding = rb_intern_const("content_encoding");
  id_error_content_media_type = rb_intern_const("content_media_type");
  id_error_dependent_required = rb_intern_const("dependent_required");
  id_error_enum = rb_intern_const("enum");
  id_error_false_schema = rb_intern_const("false_schema");
  id_error_format = rb_intern_const("format");
  id_error_invalid_pattern = rb_intern_const("invalid_pattern");
  id_error_multiple_of = rb_intern_const("multiple_of");
  id_error_not = rb_intern_const("not");
  id_error_numeric_limit = rb_intern_const("numeric_limit");
  id_error_one_of = rb_intern_const("one_of");
  id_error_pattern = rb_intern_const("pattern");
  id_error_required = rb_intern_const("required");
  id_error_size = rb_intern_const("size");
  id_error_type = rb_intern_const("type");
  id_error_unique_items = rb_intern_const("unique_items");
  sym_content = ID2SYM(rb_intern_const("content"));
  sym_format = ID2SYM(id_format);
  sym_vm = ID2SYM(rb_intern_const("vm"));
  sym_keyword = ID2SYM(rb_intern_const("keyword"));
  sym_instance_path = ID2SYM(rb_intern_const("instance_path"));
  sym_schema_path = ID2SYM(rb_intern_const("schema_path"));
  sym_message = ID2SYM(id_message);

  mSchemurai = rb_const_get(rb_cObject, rb_intern_const("Schemurai"));
  mInternal = rb_const_get(mSchemurai, rb_intern_const("Internal"));
  mVM = rb_define_module_under(mSchemurai, "VM");
  mErrorMessage = rb_const_get(mInternal, rb_intern_const("ErrorMessage"));
  mNativeSupport = rb_const_get(mVM, rb_intern_const("NativeSupport"));
  cResult = rb_const_get(mSchemurai, rb_intern_const("Result"));
  cValidationError = rb_const_get(mSchemurai, rb_intern_const("ValidationError"));
  cRubyEvaluator = rb_const_get(mInternal, rb_intern_const("Evaluator"));
  eResolutionError = rb_const_get(mSchemurai, rb_intern_const("ResolutionError"));
  rb_gc_register_address(&mSchemurai);
  rb_gc_register_address(&mVM);
  rb_gc_register_address(&mInternal);
  rb_gc_register_address(&mErrorMessage);
  rb_gc_register_address(&mNativeSupport);
  rb_gc_register_address(&cResult);
  rb_gc_register_address(&cValidationError);
  rb_gc_register_address(&cRubyEvaluator);
  rb_gc_register_address(&eResolutionError);
  /* Programs and opcode operands are implementation-only native values.  Their
   * anonymous wrapper classes let Ruby's GC own the native allocations without
   * publishing a Ruby object model for the VM's instruction representation. */
  cRule = rb_class_new(rb_cObject);
  rb_undef_alloc_func(cRule);
  cProgram = rb_class_new(rb_cObject);
  rb_define_alloc_func(cProgram, program_alloc);
  rb_gc_register_address(&cRule);
  rb_gc_register_address(&cProgram);
  cCompiler = rb_define_class_under(mVM, "Compiler", rb_cObject);
  rb_define_alloc_func(cCompiler, compiler_alloc);
  rb_define_method(cCompiler, "initialize", compiler_initialize, 1);
  rb_define_method(cCompiler, "compile_all", compiler_compile_all, 0);
  rb_define_method(cCompiler, "evaluator", compiler_evaluator, -1);
  cEvaluator = rb_define_class_under(mVM, "Evaluator", rb_cObject);
  rb_undef_alloc_func(cEvaluator);
  rb_define_method(cEvaluator, "backend", evaluator_backend, 0);
  rb_define_method(cEvaluator, "valid?", evaluator_valid, 1);
  rb_define_method(cEvaluator, "validate", evaluator_validate, 1);
  rb_gc_register_address(&cCompiler);
  rb_gc_register_address(&cEvaluator);
}
