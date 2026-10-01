#include "schemurai_native.h"

/* Compiler: Ruby schema nodes are consumed at this boundary. The resulting
 * programs snapshot operands and retain only compiled child programs. */
static VALUE snapshot(VALUE value) {
  if (RB_TYPE_P(value, T_STRING))
    return rb_str_new_frozen(value);
  if (RB_TYPE_P(value, T_ARRAY)) {
    long n = RARRAY_LEN(value);
    VALUE copy = rb_ary_new_capa(n);
    for (long i = 0; i < n; i++)
      rb_ary_push(copy, snapshot(rb_ary_entry(value, i)));
    return rb_obj_freeze(copy);
  }
  if (RB_TYPE_P(value, T_HASH)) {
    VALUE keys = rb_funcall(value, id_keys, 0), copy = rb_hash_new();
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE key = rb_ary_entry(keys, i);
      rb_hash_aset(copy, snapshot(key), snapshot(rb_hash_aref(value, key)));
    }
    return rb_obj_freeze(copy);
  }
  return value;
}

VALUE compiler_compile(VALUE self, VALUE node);

static uint32_t compile_type_bit(VALUE name) {
  Check_Type(name, T_STRING);
  if (rb_str_equal(name, STATIC_STRING(NULL_TYPE)))
    return TYPE_NULL;
  if (rb_str_equal(name, STATIC_STRING(BOOLEAN_TYPE)))
    return TYPE_BOOLEAN;
  if (rb_str_equal(name, STATIC_STRING(OBJECT_TYPE)))
    return TYPE_OBJECT;
  if (rb_str_equal(name, STATIC_STRING(ARRAY_TYPE)))
    return TYPE_ARRAY;
  if (rb_str_equal(name, STATIC_STRING(NUMBER_TYPE)))
    return TYPE_NUMBER;
  if (rb_str_equal(name, STATIC_STRING(INTEGER_TYPE)))
    return TYPE_INTEGER;
  if (rb_str_equal(name, STATIC_STRING(STRING_TYPE)))
    return TYPE_STRING;
  rb_raise(rb_eKeyError, "unknown schema type");
}

static uint8_t compile_type_opcode(VALUE name) {
  switch (compile_type_bit(name)) {
  case TYPE_NULL:
    return OP_TYPE_NULL;
  case TYPE_BOOLEAN:
    return OP_TYPE_BOOLEAN;
  case TYPE_OBJECT:
    return OP_TYPE_OBJECT;
  case TYPE_ARRAY:
    return OP_TYPE_ARRAY;
  case TYPE_NUMBER:
    return OP_TYPE_NUMBER;
  case TYPE_INTEGER:
    return OP_TYPE_INTEGER;
  default:
    return OP_TYPE_STRING;
  }
}

static VALUE compile_child(VALUE self, VALUE node, VALUE parent) {
  VALUE child = compiler_compile(self, node);
  program_t *c, *p;
  TypedData_Get_Struct(child, program_t, &program_type, c);
  TypedData_Get_Struct(parent, program_t, &program_type, p);
  if (c->flags & FLAG_DYNAMIC_SCOPE)
    p->flags |= FLAG_DYNAMIC_SCOPE;
  return child;
}

static VALUE compile_reference(VALUE reference) {
  Check_Type(reference, T_STRING);
  VALUE rule = rule_new(RULE_REFERENCE);
  rule_t *r;
  TypedData_Get_Struct(rule, rule_t, &rule_type, r);
  VALUE value = snapshot(reference);
  RB_OBJ_WRITE(rule, &r->as.reference.value, value);
  const char *ptr = RSTRING_PTR(value), *hash = memchr(ptr, '#', (size_t)RSTRING_LEN(value));
  VALUE fragment =
      hash ? rb_str_substr(value, (long)(hash - ptr + 1), RSTRING_LEN(value) - (long)(hash - ptr + 1)) : Qnil;
  RB_OBJ_WRITE(rule, &r->as.reference.fragment, NIL_P(fragment) ? Qnil : rb_str_new_frozen(fragment));
  return rb_obj_freeze(rule);
}

static VALUE compile_map(VALUE self, VALUE node, VALUE parent, VALUE schema, VALUE keyword) {
  VALUE result = rb_hash_new();
  if (!hkey(schema, keyword))
    return rb_obj_freeze(result);
  VALUE source = hget(schema, keyword);
  Check_Type(source, T_HASH);
  VALUE keys = rb_funcall(source, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i);
    rb_hash_aset(result, snapshot(key), compile_child(self, node_child(node, keyword, key, true), parent));
  }
  return rb_obj_freeze(result);
}

static VALUE compile_number(VALUE schema) {
  VALUE obj = rule_new(RULE_NUMBER);
  rule_t *r;
  TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  VALUE keys[] = {STATIC_STRING(MAXIMUM), STATIC_STRING(MINIMUM), STATIC_STRING(EXCLUSIVE_MAXIMUM),
                  STATIC_STRING(EXCLUSIVE_MINIMUM), STATIC_STRING(MULTIPLE_OF)};
  VALUE *limits[] = {&r->as.number.maximum, &r->as.number.minimum, &r->as.number.exclusive_maximum,
                     &r->as.number.exclusive_minimum, &r->as.number.multiple_of};
  for (int i = 0; i < 5; i++)
    if (hkey(schema, keys[i])) {
      r->mask |= 1u << i;
      RB_OBJ_WRITE(obj, limits[i], hget(schema, keys[i]));
    }
  if (r->mask & NUM_MULTIPLE_OF)
    RB_OBJ_WRITE(obj, &r->as.number.multiple_decimal, decimal(r->as.number.multiple_of));
  return rb_obj_freeze(obj);
}

static VALUE compile_string(VALUE node, VALUE schema) {
  VALUE obj = rule_new(RULE_STRING);
  rule_t *r;
  TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  RB_OBJ_WRITE(obj, &r->as.string.max_length, hget(schema, STATIC_STRING(MAX_LENGTH)));
  RB_OBJ_WRITE(obj, &r->as.string.min_length, hget(schema, STATIC_STRING(MIN_LENGTH)));
  RB_OBJ_WRITE(obj, &r->as.string.pattern, snapshot(hget(schema, STATIC_STRING(PATTERN))));
  RB_OBJ_WRITE(obj, &r->as.string.format, rb_funcall(node, id_format, 0));
  VALUE dialect = rb_funcall(node, id_dialect, 0);
  r->as.string.format_assertion = RTEST(rb_funcall(dialect, id_format_assertion_p, 0));
  VALUE encoding = hget(schema, STATIC_STRING(CONTENT_ENCODING));
  VALUE media_type = hget(schema, STATIC_STRING(CONTENT_MEDIA_TYPE));
  r->as.string.decode_base64 = RB_TYPE_P(encoding, T_STRING) && rb_str_equal(encoding, STATIC_STRING(BASE64));
  r->as.string.parse_json =
      RB_TYPE_P(media_type, T_STRING) && rb_str_equal(media_type, STATIC_STRING(APPLICATION_JSON));
  return rb_obj_freeze(obj);
}

static VALUE compile_program_list(VALUE self, VALUE node, VALUE parent, VALUE source, VALUE keyword) {
  Check_Type(source, T_ARRAY);
  long n = RARRAY_LEN(source);
  VALUE list = rb_ary_new_capa(n);
  for (long i = 0; i < n; i++)
    rb_ary_push(list, compile_child(self, node_child(node, keyword, LONG2NUM(i), true), parent));
  return rb_obj_freeze(list);
}

static VALUE compile_array(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_ARRAY);
  rule_t *r;
  TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.array.items_list = false;
  RB_OBJ_WRITE(obj, &r->as.array.max_items, hget(schema, STATIC_STRING(MAX_ITEMS)));
  RB_OBJ_WRITE(obj, &r->as.array.min_items, hget(schema, STATIC_STRING(MIN_ITEMS)));
  r->as.array.unique = RTEST(hget(schema, STATIC_STRING(UNIQUE_ITEMS)));
  VALUE prefix = hget(schema, STATIC_STRING(PREFIX_ITEMS));
  if (RB_TYPE_P(prefix, T_ARRAY))
    RB_OBJ_WRITE(obj, &r->as.array.prefix_items,
                 compile_program_list(self, node, parent, prefix, STATIC_STRING(PREFIX_ITEMS)));
  VALUE items = hget(schema, STATIC_STRING(ITEMS));
  if (RB_TYPE_P(items, T_ARRAY)) {
    RB_OBJ_WRITE(obj, &r->as.array.items, compile_program_list(self, node, parent, items, STATIC_STRING(ITEMS)));
    r->as.array.items_list = true;
  } else if (!NIL_P(items))
    RB_OBJ_WRITE(obj, &r->as.array.items,
                 compile_child(self, node_child(node, STATIC_STRING(ITEMS), Qnil, false), parent));
  if (hkey(schema, STATIC_STRING(ADDITIONAL_ITEMS)))
    RB_OBJ_WRITE(obj, &r->as.array.additional,
                 compile_child(self, node_child(node, STATIC_STRING(ADDITIONAL_ITEMS), Qnil, false), parent));
  if (hkey(schema, STATIC_STRING(CONTAINS)))
    RB_OBJ_WRITE(obj, &r->as.array.contains,
                 compile_child(self, node_child(node, STATIC_STRING(CONTAINS), Qnil, false), parent));
  RB_OBJ_WRITE(obj, &r->as.array.min_contains,
               hkey(schema, STATIC_STRING(MIN_CONTAINS)) ? hget(schema, STATIC_STRING(MIN_CONTAINS)) : INT2NUM(1));
  RB_OBJ_WRITE(obj, &r->as.array.max_contains,
               hkey(schema, STATIC_STRING(MAX_CONTAINS)) ? hget(schema, STATIC_STRING(MAX_CONTAINS))
                                                         : DBL2NUM(HUGE_VAL));
  if (hkey(schema, STATIC_STRING(UNEVALUATED_ITEMS))) {
    RB_OBJ_WRITE(obj, &r->as.array.unevaluated,
                 compile_child(self, node_child(node, STATIC_STRING(UNEVALUATED_ITEMS), Qnil, false), parent));
    program_t *p;
    TypedData_Get_Struct(parent, program_t, &program_type, p);
    p->flags |= FLAG_EVALUATION;
  }
  return rb_obj_freeze(obj);
}

static VALUE compile_dependencies(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  if (!hkey(schema, STATIC_STRING(DEPENDENCIES)))
    return Qnil;
  VALUE source = hget(schema, STATIC_STRING(DEPENDENCIES));
  Check_Type(source, T_HASH);
  if (RHASH_EMPTY_P(source))
    return Qnil;
  VALUE out = rb_hash_new(), keys = rb_funcall(source, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i), value = rb_hash_aref(source, key);
    VALUE compiled = RB_TYPE_P(value, T_ARRAY)
                         ? snapshot(value)
                         : compile_child(self, node_child(node, STATIC_STRING(DEPENDENCIES), key, true), parent);
    rb_hash_aset(out, snapshot(key), compiled);
  }
  return rb_obj_freeze(out);
}

static VALUE compile_dependent_required(VALUE schema) {
  if (!hkey(schema, STATIC_STRING(DEPENDENT_REQUIRED)))
    return Qnil;
  VALUE source = hget(schema, STATIC_STRING(DEPENDENT_REQUIRED));
  Check_Type(source, T_HASH);
  VALUE keys = rb_funcall(source, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++)
    Check_Type(rb_hash_aref(source, rb_ary_entry(keys, i)), T_ARRAY);
  return RHASH_EMPTY_P(source) ? Qnil : snapshot(source);
}

static VALUE compile_object(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_OBJECT);
  rule_t *r;
  TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  RB_OBJ_WRITE(obj, &r->as.object.max_properties, hget(schema, STATIC_STRING(MAX_PROPERTIES)));
  RB_OBJ_WRITE(obj, &r->as.object.min_properties, hget(schema, STATIC_STRING(MIN_PROPERTIES)));
  VALUE required = hget(schema, STATIC_STRING(REQUIRED));
  if (!NIL_P(required))
    Check_Type(required, T_ARRAY);
  RB_OBJ_WRITE(obj, &r->as.object.required, snapshot(required));
  RB_OBJ_WRITE(obj, &r->as.object.properties, compile_map(self, node, parent, schema, STATIC_STRING(PROPERTIES)));
  VALUE map = compile_map(self, node, parent, schema, STATIC_STRING(PATTERN_PROPERTIES));
  RB_OBJ_WRITE(obj, &r->as.object.patterns, RHASH_EMPTY_P(map) ? Qnil : map);
  RB_OBJ_WRITE(obj, &r->as.object.pattern_names,
               NIL_P(r->as.object.patterns) ? Qnil : rb_obj_freeze(rb_funcall(r->as.object.patterns, id_keys, 0)));
  if (hkey(schema, STATIC_STRING(ADDITIONAL_PROPERTIES)))
    RB_OBJ_WRITE(obj, &r->as.object.additional,
                 compile_child(self, node_child(node, STATIC_STRING(ADDITIONAL_PROPERTIES), Qnil, false), parent));
  if (hkey(schema, STATIC_STRING(PROPERTY_NAMES)))
    RB_OBJ_WRITE(obj, &r->as.object.property_names,
                 compile_child(self, node_child(node, STATIC_STRING(PROPERTY_NAMES), Qnil, false), parent));
  RB_OBJ_WRITE(obj, &r->as.object.dependencies, compile_dependencies(self, node, parent, schema));
  RB_OBJ_WRITE(obj, &r->as.object.dependent_required, compile_dependent_required(schema));
  map = compile_map(self, node, parent, schema, STATIC_STRING(DEPENDENT_SCHEMAS));
  RB_OBJ_WRITE(obj, &r->as.object.dependent_schemas, RHASH_EMPTY_P(map) ? Qnil : map);
  if (hkey(schema, STATIC_STRING(UNEVALUATED_PROPERTIES))) {
    RB_OBJ_WRITE(obj, &r->as.object.unevaluated,
                 compile_child(self, node_child(node, STATIC_STRING(UNEVALUATED_PROPERTIES), Qnil, false), parent));
    program_t *p;
    TypedData_Get_Struct(parent, program_t, &program_type, p);
    p->flags |= FLAG_EVALUATION;
  }
  return rb_obj_freeze(obj);
}

VALUE compiler_initialize(VALUE self, VALUE graph) {
  compiler_t *c;
  TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  RB_OBJ_WRITE(self, &c->graph, graph);
  RB_OBJ_WRITE(self, &c->programs, rb_hash_new());
  rb_funcall(c->programs, id_compare_by_identity, 0);
  return self;
}

static void compile_combiners(VALUE self, VALUE node, VALUE program, VALUE schema) {
  VALUE keys[] = {STATIC_STRING(ALL_OF), STATIC_STRING(ANY_OF), STATIC_STRING(ONE_OF)};
  const uint8_t ops[] = {OP_ALL_OF, OP_ANY_OF, OP_ONE_OF};
  for (int i = 0; i < 3; i++)
    if (hkey(schema, keys[i]))
      emit(program, ops[i], compile_program_list(self, node, program, hget(schema, keys[i]), keys[i]));
  if (hkey(schema, STATIC_STRING(NOT)))
    emit(program, OP_NOT, compile_child(self, node_child(node, STATIC_STRING(NOT), Qnil, false), program));
  if (hkey(schema, STATIC_STRING(IF))) {
    VALUE obj = rule_new(RULE_CONDITIONAL);
    rule_t *r;
    TypedData_Get_Struct(obj, rule_t, &rule_type, r);
    RB_OBJ_WRITE(obj, &r->as.conditional.condition,
                 compile_child(self, node_child(node, STATIC_STRING(IF), Qnil, false), program));
    if (hkey(schema, STATIC_STRING(THEN)))
      RB_OBJ_WRITE(obj, &r->as.conditional.then_branch,
                   compile_child(self, node_child(node, STATIC_STRING(THEN), Qnil, false), program));
    if (hkey(schema, STATIC_STRING(ELSE)))
      RB_OBJ_WRITE(obj, &r->as.conditional.else_branch,
                   compile_child(self, node_child(node, STATIC_STRING(ELSE), Qnil, false), program));
    emit(program, OP_CONDITIONAL, rb_obj_freeze(obj));
  }
}

VALUE compiler_compile(VALUE self, VALUE node) {
  compiler_t *c;
  TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  VALUE cached = rb_hash_lookup2(c->programs, node, Qundef);
  if (cached != Qundef)
    return cached;
  rb_check_frozen(self);
  VALUE program = program_alloc(cProgram);
  program_t *p;
  TypedData_Get_Struct(program, program_t, &program_type, p);
  RB_OBJ_WRITE(program, &p->node, node);
  p->resource = Qnil;
  p->dynamic_anchor = Qnil;
  VALUE schema = rb_funcall(node, id_schema, 0);
  if (RB_TYPE_P(schema, T_HASH)) {
    p->recursive_anchor = hget(schema, STATIC_STRING(RECURSIVE_ANCHOR)) == Qtrue;
    VALUE anchor = hget(schema, STATIC_STRING(DYNAMIC_ANCHOR));
    if (RB_TYPE_P(anchor, T_STRING))
      RB_OBJ_WRITE(program, &p->dynamic_anchor, rb_str_new_frozen(anchor));
  }
  if (schema == Qtrue || schema == Qfalse)
    emit(program, OP_BOOLEAN, schema);
  else if (RB_TYPE_P(schema, T_HASH)) {
    if (hkey(schema, STATIC_STRING(REF))) {
      p->flags |= FLAG_DYNAMIC_SCOPE;
      emit(program, OP_REF, compile_reference(hget(schema, STATIC_STRING(REF))));
      if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0)))
        goto finish;
    }
    if (hkey(schema, STATIC_STRING(RECURSIVE_REF))) {
      p->flags |= FLAG_DYNAMIC_SCOPE;
      emit(program, OP_RECURSIVE_REF, compile_reference(hget(schema, STATIC_STRING(RECURSIVE_REF))));
    }
    if (hkey(schema, STATIC_STRING(DYNAMIC_REF))) {
      p->flags |= FLAG_DYNAMIC_SCOPE;
      emit(program, OP_DYNAMIC_REF, compile_reference(hget(schema, STATIC_STRING(DYNAMIC_REF))));
    }
    unsigned long mask = NUM2ULONG(rb_funcall(node, id_keyword_mask, 0));
    if ((mask & 1) && hkey(schema, STATIC_STRING(TYPE))) {
      VALUE types = hget(schema, STATIC_STRING(TYPE));
      if (RB_TYPE_P(types, T_ARRAY)) {
        VALUE rule = rule_new(RULE_TYPES);
        rule_t *r;
        TypedData_Get_Struct(rule, rule_t, &rule_type, r);
        for (long i = 0; i < RARRAY_LEN(types); i++)
          r->mask |= compile_type_bit(rb_ary_entry(types, i));
        RB_OBJ_WRITE(rule, &r->as.types.names, snapshot(types));
        emit(program, OP_TYPES, rb_obj_freeze(rule));
      } else {
        emit(program, compile_type_opcode(types), Qnil);
      }
    }
    if (mask & 2) {
      if (hkey(schema, STATIC_STRING(ENUM))) {
        VALUE values = hget(schema, STATIC_STRING(ENUM));
        Check_Type(values, T_ARRAY);
        emit(program, OP_ENUM, snapshot(values));
      }
      if (hkey(schema, STATIC_STRING(CONST)))
        emit(program, OP_CONST, snapshot(hget(schema, STATIC_STRING(CONST))));
    }
    if (mask & 4)
      compile_combiners(self, node, program, schema);
    if (mask & 8)
      emit(program, OP_NUMBER, compile_number(schema));
    if ((mask & 16) || !NIL_P(rb_funcall(node, id_format, 0)))
      emit(program, OP_STRING, compile_string(node, schema));
    if (mask & 32)
      emit(program, OP_ARRAY, compile_array(self, node, program, schema));
    if (mask & 64)
      emit(program, OP_OBJECT, compile_object(self, node, program, schema));
    for (size_t i = 0; i + 1 < p->length; i++) {
      uint8_t a = p->instructions[i].opcode, b = p->instructions[i + 1].opcode, fused = 255;
      if (a == OP_TYPE_OBJECT && b == OP_OBJECT)
        fused = OP_TYPED_OBJECT;
      else if (a == OP_TYPE_ARRAY && b == OP_ARRAY)
        fused = OP_TYPED_ARRAY;
      else if (a == OP_TYPE_STRING && b == OP_STRING)
        fused = OP_TYPED_STRING;
      else if (a == OP_TYPE_NUMBER && b == OP_NUMBER)
        fused = OP_TYPED_NUMBER;
      else if (a == OP_TYPE_INTEGER && b == OP_NUMBER)
        fused = OP_TYPED_INTEGER;
      if (fused != 255) {
        p->instructions[i].opcode = fused;
        RB_OBJ_WRITE(program, &p->instructions[i].operand, p->instructions[i + 1].operand);
        memmove(&p->instructions[i + 1], &p->instructions[i + 2], (p->length - i - 2) * sizeof(instruction_t));
        p->length--;
        break;
      }
    }
  }
finish:
  if (p->flags & FLAG_DYNAMIC_SCOPE)
    RB_OBJ_WRITE(program, &p->resource, rb_funcall(node, id_resource, 0));
  rb_obj_freeze(program);
  rb_hash_aset(c->programs, node, program);
  return program;
}

VALUE compiler_compile_all(VALUE self) {
  compiler_t *c;
  TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  VALUE nodes = rb_funcall(c->graph, id_nodes, 0);
  for (long i = 0; i < RARRAY_LEN(nodes); i++)
    compiler_compile(self, rb_ary_entry(nodes, i));
  return self;
}
VALUE compiler_resolve(VALUE self, VALUE program, VALUE reference) {
  compiler_t *c;
  program_t *p;
  TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  TypedData_Get_Struct(program, program_t, &program_type, p);
  return compiler_compile(self, rb_funcall(c->graph, id_resolve, 2, p->node, reference));
}
