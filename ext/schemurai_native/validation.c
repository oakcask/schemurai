#include "schemurai_native.h"

static VALUE pointer(VALUE path, VALUE final, bool has_final) {
  VALUE result = rb_str_buf_new(0);
  long n = RARRAY_LEN(path) + (has_final ? 1 : 0);
  for (long i = 0; i < n; i++) {
    VALUE segment = i < RARRAY_LEN(path) ? rb_ary_entry(path, i) : final;
    VALUE string = rb_funcall(segment, id_to_s, 0);
    string = rb_funcall(string, id_gsub, 2, STATIC_STRING(TILDE), STATIC_STRING(ESCAPED_TILDE));
    string = rb_funcall(string, id_gsub, 2, STATIC_STRING(SLASH), STATIC_STRING(ESCAPED_SLASH));
    rb_str_cat_cstr(result, "/");
    rb_str_append(result, string);
  }
  return result;
}

/* Detailed diagnostics use the same native programs, adding only public Ruby
 * ValidationError objects at the API boundary. */
static VALUE error_message(ID method, int argc, VALUE *a) {
  return rb_funcallv(mErrorMessage, method, argc, a);
}
static void add_error(evaluator_t *e, VALUE keyword, VALUE message, bool append_keyword) {
  VALUE kwargs = rb_hash_new();
  rb_hash_aset(kwargs, sym_keyword, keyword);
  rb_hash_aset(kwargs, sym_instance_path, pointer(e->instance_path, Qnil, false));
  rb_hash_aset(kwargs, sym_schema_path, pointer(e->schema_path, keyword, append_keyword));
  rb_hash_aset(kwargs, sym_message, message);
  VALUE argv[] = {kwargs};
  rb_ary_push(e->errors, rb_class_new_instance_kw(1, argv, cValidationError, RB_PASS_KEYWORDS));
  e->error_count++;
}
static void add_message0(evaluator_t *e, VALUE keyword, ID method) {
  add_error(e, keyword, error_message(method, 0, NULL), true);
}
static evaluation_t evaluate_detail(evaluator_t *e, VALUE program, VALUE instance);
static evaluation_t detail_at(evaluator_t *e, VALUE program, VALUE instance, VALUE instance_segment, bool has_instance,
                              VALUE schema_segment, VALUE child_segment, bool has_child) {
  if (has_instance)
    rb_ary_push(e->instance_path, instance_segment);
  rb_ary_push(e->schema_path, schema_segment);
  if (has_child)
    rb_ary_push(e->schema_path, child_segment);
  evaluation_t out = evaluate_detail(e, program, instance);
  if (has_child)
    rb_ary_pop(e->schema_path);
  rb_ary_pop(e->schema_path);
  if (has_instance)
    rb_ary_pop(e->instance_path);
  return out;
}
static evaluation_t detail_reference(evaluator_t *e, VALUE source, VALUE target, VALUE instance, VALUE keyword) {
  if (!active_enter(e, source, instance))
    return evaluation(true);
  evaluation_t out = detail_at(e, target, instance, Qnil, false, keyword, Qnil, false);
  active_leave(e, source, instance);
  return out;
}

static void check_number_detail(evaluator_t *e, rule_t *r, VALUE value) {
  VALUE actual = (r->mask & NUM_MULTIPLE_OF) ? decimal(value) : value;
  VALUE keys[] = {STATIC_STRING(MAXIMUM), STATIC_STRING(MINIMUM), STATIC_STRING(EXCLUSIVE_MAXIMUM),
                  STATIC_STRING(EXCLUSIVE_MINIMUM)};
  VALUE limits[] = {r->as.number.maximum, r->as.number.minimum, r->as.number.exclusive_maximum,
                    r->as.number.exclusive_minimum};
  for (int i = 0; i < 4; i++)
    if (r->mask & (1u << i)) {
      int comparison = compare_values(actual, limits[i]);
      bool invalid = (i == 0 && comparison > 0) || (i == 1 && comparison < 0) || (i == 2 && comparison >= 0) ||
                     (i == 3 && comparison <= 0);
      if (invalid) {
        VALUE a[] = {keys[i], limits[i]};
        add_error(e, keys[i], error_message(id_error_numeric_limit, 2, a), true);
      }
    }
  if (r->mask & NUM_MULTIPLE_OF) {
    VALUE divisor = r->as.number.multiple_decimal;
    bool ok = RTEST(rb_funcall(divisor, id_positive_p, 0)) &&
              RTEST(rb_funcall(rb_funcall(decimal(value), id_remainder, 1, divisor), id_zero_p, 0));
    if (!ok) {
      VALUE a[] = {r->as.number.multiple_of};
      add_error(e, STATIC_STRING(MULTIPLE_OF), error_message(id_error_multiple_of, 1, a), true);
    }
  }
}
static void check_type_detail(evaluator_t *e, VALUE expected, VALUE value, bool valid) {
  if (valid)
    return;
  VALUE a[] = {expected, value};
  add_error(e, STATIC_STRING(TYPE), error_message(id_error_type, 2, a), true);
}
static void check_string_detail(evaluator_t *e, rule_t *r, VALUE value) {
  long len = NUM2LONG(rb_funcall(value, id_length, 0));
  if (!NIL_P(r->as.string.max_length) && len > NUM2LONG(r->as.string.max_length)) {
    VALUE a[] = {STATIC_STRING(MAX_LENGTH), r->as.string.max_length, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MAX_LENGTH), error_message(id_error_size, 3, a), true);
  }
  if (!NIL_P(r->as.string.min_length) && len < NUM2LONG(r->as.string.min_length)) {
    VALUE a[] = {STATIC_STRING(MIN_LENGTH), r->as.string.min_length, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MIN_LENGTH), error_message(id_error_size, 3, a), true);
  }
  if (!NIL_P(r->as.string.pattern)) {
    int state = 0;
    VALUE regexp =
        rb_protect(protected_func,
                   (VALUE) & (struct protected_call){mNativeSupport, id_regexp, 1, {r->as.string.pattern}}, &state);
    if (state) {
      VALUE error = rb_errinfo();
      if (!RTEST(rb_obj_is_kind_of(error, rb_eRegexpError)))
        rb_jump_tag(state);
      rb_set_errinfo(Qnil);
      VALUE a[] = {r->as.string.pattern};
      add_error(e, STATIC_STRING(PATTERN), error_message(id_error_invalid_pattern, 1, a), true);
    } else if (!RTEST(rb_funcall(regexp, id_match_p, 1, value))) {
      VALUE a[] = {r->as.string.pattern};
      add_error(e, STATIC_STRING(PATTERN), error_message(id_error_pattern, 1, a), true);
    }
  }
  if (!NIL_P(r->as.string.format) && (e->format || r->as.string.format_assertion) &&
      !RTEST(rb_funcall(r->as.string.format, id_call, 1, value))) {
    VALUE a[] = {rb_funcall(r->as.string.format, id_name, 0)};
    add_error(e, STATIC_STRING(FORMAT), error_message(id_error_format, 1, a), true);
  }
  if (e->content && (r->as.string.decode_base64 || r->as.string.parse_json) &&
      !RTEST(rb_funcall(mNativeSupport, id_valid_content_p, 3, value, r->as.string.decode_base64 ? Qtrue : Qfalse,
                        r->as.string.parse_json ? Qtrue : Qfalse))) {
    if (r->as.string.decode_base64)
      add_message0(e, STATIC_STRING(CONTENT_ENCODING), id_error_content_encoding);
    else
      add_message0(e, STATIC_STRING(CONTENT_MEDIA_TYPE), id_error_content_media_type);
  }
}

static evaluation_t check_array_detail(evaluator_t *e, rule_t *r, VALUE value, evaluation_t prior) {
  evaluation_t out = evaluation(true);
  long before = e->error_count, len = RARRAY_LEN(value);
  if (!NIL_P(r->as.array.max_items) && len > NUM2LONG(r->as.array.max_items)) {
    VALUE a[] = {STATIC_STRING(MAX_ITEMS), r->as.array.max_items, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MAX_ITEMS), error_message(id_error_size, 3, a), true);
  }
  if (!NIL_P(r->as.array.min_items) && len < NUM2LONG(r->as.array.min_items)) {
    VALUE a[] = {STATIC_STRING(MIN_ITEMS), r->as.array.min_items, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MIN_ITEMS), error_message(id_error_size, 3, a), true);
  }
  if (r->as.array.unique && !unique_items(e, value))
    add_message0(e, STATIC_STRING(UNIQUE_ITEMS), id_error_unique_items);
  if (!NIL_P(r->as.array.prefix_items))
    for (long i = 0; i < RARRAY_LEN(r->as.array.prefix_items) && i < len; i++) {
      detail_at(e, rb_ary_entry(r->as.array.prefix_items, i), rb_ary_entry(value, i), LONG2NUM(i), true,
                STATIC_STRING(PREFIX_ITEMS), LONG2NUM(i), true);
      add_unique(&out.items, LONG2NUM(i));
    }
  if (r->as.array.items_list) {
    long n = RARRAY_LEN(r->as.array.items);
    for (long i = 0; i < n && i < len; i++) {
      detail_at(e, rb_ary_entry(r->as.array.items, i), rb_ary_entry(value, i), LONG2NUM(i), true, STATIC_STRING(ITEMS),
                LONG2NUM(i), true);
      add_unique(&out.items, LONG2NUM(i));
    }
    if (!NIL_P(r->as.array.additional))
      for (long i = n; i < len; i++) {
        detail_at(e, r->as.array.additional, rb_ary_entry(value, i), LONG2NUM(i), true, STATIC_STRING(ADDITIONAL_ITEMS),
                  Qnil, false);
        add_unique(&out.items, LONG2NUM(i));
      }
  } else if (!NIL_P(r->as.array.items)) {
    long start = NIL_P(r->as.array.prefix_items) ? 0 : RARRAY_LEN(r->as.array.prefix_items);
    for (long i = start; i < len; i++) {
      detail_at(e, r->as.array.items, rb_ary_entry(value, i), LONG2NUM(i), true, STATIC_STRING(ITEMS), Qnil, false);
      add_unique(&out.items, LONG2NUM(i));
    }
  }
  if (!NIL_P(r->as.array.contains)) {
    VALUE matched = Qnil;
    long count = 0;
    for (long i = 0; i < len; i++)
      if (evaluate_program(e, r->as.array.contains, rb_ary_entry(value, i)).valid) {
        count++;
        add_unique(&matched, LONG2NUM(i));
      }
    if (count < NUM2LONG(r->as.array.min_contains) || compare_values(LONG2NUM(count), r->as.array.max_contains) > 0) {
      VALUE a[] = {LONG2NUM(count), r->as.array.min_contains, r->as.array.max_contains};
      add_error(e, STATIC_STRING(CONTAINS), error_message(id_error_contains, 3, a), true);
    }
    merge_locations(&out.items, matched);
  }
  if (!NIL_P(r->as.array.unevaluated))
    for (long i = 0; i < len; i++) {
      VALUE index = LONG2NUM(i);
      if (has_location(prior.items, index) || has_location(out.items, index))
        continue;
      detail_at(e, r->as.array.unevaluated, rb_ary_entry(value, i), index, true, STATIC_STRING(UNEVALUATED_ITEMS), Qnil,
                false);
      add_unique(&out.items, index);
    }
  out.valid = e->error_count == before;
  return out;
}

static evaluation_t check_object_detail(evaluator_t *e, rule_t *r, VALUE value, evaluation_t prior) {
  evaluation_t out = evaluation(true);
  long before = e->error_count, len = RHASH_SIZE(value);
  if (!NIL_P(r->as.object.max_properties) && len > NUM2LONG(r->as.object.max_properties)) {
    VALUE a[] = {STATIC_STRING(MAX_PROPERTIES), r->as.object.max_properties, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MAX_PROPERTIES), error_message(id_error_size, 3, a), true);
  }
  if (!NIL_P(r->as.object.min_properties) && len < NUM2LONG(r->as.object.min_properties)) {
    VALUE a[] = {STATIC_STRING(MIN_PROPERTIES), r->as.object.min_properties, LONG2NUM(len)};
    add_error(e, STATIC_STRING(MIN_PROPERTIES), error_message(id_error_size, 3, a), true);
  }
  if (!NIL_P(r->as.object.required))
    for (long i = 0; i < RARRAY_LEN(r->as.object.required); i++) {
      VALUE name = rb_ary_entry(r->as.object.required, i);
      if (!RTEST(rb_funcall(value, id_key_p, 1, name))) {
        VALUE a[] = {name};
        add_error(e, STATIC_STRING(REQUIRED), error_message(id_error_required, 1, a), true);
      }
    }
  VALUE keys = rb_funcall(value, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++)
    if (CLASS_OF(rb_ary_entry(keys, i)) != rb_cString) {
      e->unsupported_instance = true;
      return evaluation(false);
    }
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE name = rb_ary_entry(keys, i), item = rb_hash_aref(value, name);
    bool matched = false;
    VALUE child = rb_hash_lookup2(r->as.object.properties, name, Qundef);
    if (child != Qundef) {
      matched = true;
      detail_at(e, child, item, name, true, STATIC_STRING(PROPERTIES), name, true);
      add_unique(&out.properties, name);
    }
    if (!NIL_P(r->as.object.pattern_names)) {
      for (long j = 0; j < RARRAY_LEN(r->as.object.pattern_names); j++) {
        VALUE pattern = rb_ary_entry(r->as.object.pattern_names, j);
        if (RTEST(rb_funcall(regexp_for(e, pattern), id_match_p, 1, name))) {
          matched = true;
          detail_at(e, rb_hash_aref(r->as.object.patterns, pattern), item, name, true,
                    STATIC_STRING(PATTERN_PROPERTIES), pattern, true);
          add_unique(&out.properties, name);
        }
      }
    }
    if (!matched && !NIL_P(r->as.object.additional)) {
      detail_at(e, r->as.object.additional, item, name, true, STATIC_STRING(ADDITIONAL_PROPERTIES), Qnil, false);
      add_unique(&out.properties, name);
    }
  }
  if (!NIL_P(r->as.object.property_names))
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE name = rb_ary_entry(keys, i);
      detail_at(e, r->as.object.property_names, name, name, true, STATIC_STRING(PROPERTY_NAMES), Qnil, false);
    }
  if (!NIL_P(r->as.object.dependencies)) {
    VALUE names = rb_funcall(r->as.object.dependencies, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(names); i++) {
      VALUE name = rb_ary_entry(names, i);
      if (!RTEST(rb_funcall(value, id_key_p, 1, name)))
        continue;
      VALUE dep = rb_hash_aref(r->as.object.dependencies, name);
      if (RB_TYPE_P(dep, T_ARRAY)) {
        for (long j = 0; j < RARRAY_LEN(dep); j++) {
          VALUE req = rb_ary_entry(dep, j);
          if (!RTEST(rb_funcall(value, id_key_p, 1, req))) {
            VALUE a[] = {name, req};
            add_error(e, STATIC_STRING(DEPENDENCIES), error_message(id_error_dependent_required, 2, a), true);
          }
        }
      } else {
        evaluation_t x = detail_at(e, dep, value, Qnil, false, STATIC_STRING(DEPENDENCIES), name, true);
        if (x.valid)
          merge_locations(&out.properties, x.properties);
      }
    }
  }
  if (!NIL_P(r->as.object.dependent_required)) {
    VALUE names = rb_funcall(r->as.object.dependent_required, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(names); i++) {
      VALUE name = rb_ary_entry(names, i);
      if (!RTEST(rb_funcall(value, id_key_p, 1, name)))
        continue;
      VALUE reqs = rb_hash_aref(r->as.object.dependent_required, name);
      for (long j = 0; j < RARRAY_LEN(reqs); j++) {
        VALUE req = rb_ary_entry(reqs, j);
        if (!RTEST(rb_funcall(value, id_key_p, 1, req))) {
          VALUE a[] = {name, req};
          add_error(e, STATIC_STRING(DEPENDENT_REQUIRED), error_message(id_error_dependent_required, 2, a), true);
        }
      }
    }
  }
  if (!NIL_P(r->as.object.dependent_schemas)) {
    VALUE names = rb_funcall(r->as.object.dependent_schemas, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(names); i++) {
      VALUE name = rb_ary_entry(names, i);
      if (!RTEST(rb_funcall(value, id_key_p, 1, name)))
        continue;
      evaluation_t x = detail_at(e, rb_hash_aref(r->as.object.dependent_schemas, name), value, Qnil, false,
                                 STATIC_STRING(DEPENDENT_SCHEMAS), name, true);
      if (x.valid)
        merge_locations(&out.properties, x.properties);
    }
  }
  if (!NIL_P(r->as.object.unevaluated))
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE name = rb_ary_entry(keys, i);
      if (has_location(prior.properties, name) || has_location(out.properties, name))
        continue;
      detail_at(e, r->as.object.unevaluated, rb_hash_aref(value, name), name, true,
                STATIC_STRING(UNEVALUATED_PROPERTIES), Qnil, false);
      add_unique(&out.properties, name);
    }
  out.valid = e->error_count == before;
  return out;
}

static evaluation_t check_combiner_detail(evaluator_t *e, uint8_t op, VALUE operand, VALUE value) {
  evaluation_t out = evaluation(true);
  if (op == OP_ALL_OF) {
    for (long i = 0; i < RARRAY_LEN(operand); i++)
      merge_evaluation(
          &out, detail_at(e, rb_ary_entry(operand, i), value, Qnil, false, STATIC_STRING(ALL_OF), LONG2NUM(i), true));
  } else if (op == OP_ANY_OF || op == OP_ONE_OF) {
    long matches = 0;
    evaluation_t matched = evaluation(true);
    for (long i = 0; i < RARRAY_LEN(operand); i++) {
      evaluation_t x = evaluate_program_mode(e, rb_ary_entry(operand, i), value, true);
      if (x.valid) {
        matches++;
        merge_evaluation(&matched, x);
      }
    }
    if (op == OP_ANY_OF && matches == 0)
      add_message0(e, STATIC_STRING(ANY_OF), id_error_any_of);
    else if (op == OP_ONE_OF && matches != 1) {
      VALUE a[] = {LONG2NUM(matches)};
      add_error(e, STATIC_STRING(ONE_OF), error_message(id_error_one_of, 1, a), true);
    } else
      merge_evaluation(&out, matched);
  } else if (op == OP_NOT) {
    if (evaluate_program(e, operand, value).valid)
      add_message0(e, STATIC_STRING(NOT), id_error_not);
  } else {
    rule_t *r;
    TypedData_Get_Struct(operand, rule_t, &rule_type, r);
    evaluation_t condition = evaluate_program_mode(e, r->as.conditional.condition, value, true);
    if (condition.valid) {
      merge_evaluation(&out, condition);
      if (!NIL_P(r->as.conditional.then_branch))
        merge_evaluation(
            &out, detail_at(e, r->as.conditional.then_branch, value, Qnil, false, STATIC_STRING(THEN), Qnil, false));
    } else if (!NIL_P(r->as.conditional.else_branch))
      merge_evaluation(
          &out, detail_at(e, r->as.conditional.else_branch, value, Qnil, false, STATIC_STRING(ELSE), Qnil, false));
  }
  return out;
}

static evaluation_t evaluate_detail(evaluator_t *e, VALUE program, VALUE instance) {
  if (!supported_value(instance)) {
    e->unsupported_instance = true;
    return evaluation(false);
  }
  program_t *p;
  TypedData_Get_Struct(program, program_t, &program_type, p);
  long before = e->error_count;
  evaluation_t out = evaluation(true);
  bool entered = false;
  if (p->flags & FLAG_DYNAMIC_SCOPE) {
    VALUE resource = p->resource;
    if (RARRAY_LEN(e->dynamic_scope) == 0 || rb_ary_entry(e->dynamic_scope, -1) != resource) {
      rb_ary_push(e->dynamic_scope, resource);
      entered = true;
    }
  }
  for (size_t i = 0; i < p->length && !e->unsupported_instance; i++) {
    instruction_t *ins = &p->instructions[i];
    rule_t *r = NULL;
    if (ins->opcode == OP_TYPES || ins->opcode >= OP_CONDITIONAL)
      r = RULE_PTR(ins->operand);
    evaluation_t x;
    switch (ins->opcode) {
    case OP_BOOLEAN:
      if (!RTEST(ins->operand))
        add_error(e, STATIC_STRING(FALSE_SCHEMA), error_message(id_error_false_schema, 0, NULL), false);
      break;
    case OP_REF:
    case OP_RECURSIVE_REF:
    case OP_DYNAMIC_REF: {
      int state = 0;
      VALUE target = safe_target(e, program, ins->operand, ins->opcode, &state);
      VALUE keyword = ins->opcode == OP_REF             ? STATIC_STRING(REF)
                      : ins->opcode == OP_RECURSIVE_REF ? STATIC_STRING(RECURSIVE_REF)
                                                        : STATIC_STRING(DYNAMIC_REF);
      if (state) {
        VALUE error = rb_errinfo();
        if (!RTEST(rb_obj_is_kind_of(error, eResolutionError)))
          rb_jump_tag(state);
        VALUE message = rb_funcall(error, id_message, 0);
        rb_set_errinfo(Qnil);
        add_error(e, keyword, message, false);
      } else {
        x = detail_reference(e, program, target, instance, keyword);
        merge_evaluation(&out, x);
      }
      break;
    }
    case OP_TYPE_NULL:
      check_type_detail(e, STATIC_STRING(NULL_TYPE), instance, NIL_P(instance));
      break;
    case OP_TYPE_BOOLEAN:
      check_type_detail(e, STATIC_STRING(BOOLEAN_TYPE), instance, instance == Qtrue || instance == Qfalse);
      break;
    case OP_TYPE_OBJECT:
      check_type_detail(e, STATIC_STRING(OBJECT_TYPE), instance, RB_TYPE_P(instance, T_HASH));
      break;
    case OP_TYPE_ARRAY:
      check_type_detail(e, STATIC_STRING(ARRAY_TYPE), instance, RB_TYPE_P(instance, T_ARRAY));
      break;
    case OP_TYPE_NUMBER:
      check_type_detail(e, STATIC_STRING(NUMBER_TYPE), instance, number_p(instance));
      break;
    case OP_TYPE_INTEGER:
      check_type_detail(e, STATIC_STRING(INTEGER_TYPE), instance, integer_p(instance));
      break;
    case OP_TYPE_STRING:
      check_type_detail(e, STATIC_STRING(STRING_TYPE), instance, RB_TYPE_P(instance, T_STRING));
      break;
    case OP_TYPES:
      check_type_detail(e, r->as.types.names, instance,
                        (r->mask & instance_type(instance, (r->mask & TYPE_INTEGER) != 0)) != 0);
      break;
    case OP_ENUM: {
      bool ok = false;
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++)
        if (json_equal(e, rb_ary_entry(ins->operand, j), instance)) {
          ok = true;
          break;
        }
      if (!ok)
        add_message0(e, STATIC_STRING(ENUM), id_error_enum);
      break;
    }
    case OP_CONST:
      if (!json_equal(e, ins->operand, instance))
        add_message0(e, STATIC_STRING(CONST), id_error_const);
      break;
    case OP_ALL_OF:
    case OP_ANY_OF:
    case OP_ONE_OF:
    case OP_NOT:
    case OP_CONDITIONAL:
      x = check_combiner_detail(e, ins->opcode, ins->operand, instance);
      merge_evaluation(&out, x);
      break;
    case OP_NUMBER:
      if (number_p(instance))
        check_number_detail(e, r, instance);
      break;
    case OP_STRING:
      if (RB_TYPE_P(instance, T_STRING))
        check_string_detail(e, r, instance);
      break;
    case OP_ARRAY:
      if (RB_TYPE_P(instance, T_ARRAY)) {
        x = check_array_detail(e, r, instance, out);
        merge_evaluation(&out, x);
      }
      break;
    case OP_OBJECT:
      if (RB_TYPE_P(instance, T_HASH)) {
        x = check_object_detail(e, r, instance, out);
        merge_evaluation(&out, x);
      }
      break;
    case OP_TYPED_NUMBER:
      if (number_p(instance))
        check_number_detail(e, r, instance);
      else
        check_type_detail(e, STATIC_STRING(NUMBER_TYPE), instance, false);
      break;
    case OP_TYPED_INTEGER:
      if (number_p(instance)) {
        check_type_detail(e, STATIC_STRING(INTEGER_TYPE), instance, integer_p(instance));
        check_number_detail(e, r, instance);
      } else
        check_type_detail(e, STATIC_STRING(INTEGER_TYPE), instance, false);
      break;
    case OP_TYPED_STRING:
      if (RB_TYPE_P(instance, T_STRING))
        check_string_detail(e, r, instance);
      else
        check_type_detail(e, STATIC_STRING(STRING_TYPE), instance, false);
      break;
    case OP_TYPED_ARRAY:
      if (RB_TYPE_P(instance, T_ARRAY)) {
        x = check_array_detail(e, r, instance, out);
        merge_evaluation(&out, x);
      } else
        check_type_detail(e, STATIC_STRING(ARRAY_TYPE), instance, false);
      break;
    case OP_TYPED_OBJECT:
      if (RB_TYPE_P(instance, T_HASH)) {
        x = check_object_detail(e, r, instance, out);
        merge_evaluation(&out, x);
      } else
        check_type_detail(e, STATIC_STRING(OBJECT_TYPE), instance, false);
      break;
    default:
      rb_bug("unknown VM opcode: %u", ins->opcode);
    }
  }
  if (entered)
    rb_ary_pop(e->dynamic_scope);
  out.valid = e->error_count == before;
  return out;
}
static VALUE evaluator_validate_body(VALUE arg) {
  struct evaluator_call *call = (struct evaluator_call *)arg;
  evaluator_t *e = call->e;
  evaluate_detail(e, e->root, call->instance);
  if (e->unsupported_instance) {
    RB_OBJ_WRITE(call->self, &e->errors, Qnil);
    RB_OBJ_WRITE(call->self, &e->instance_path, Qnil);
    RB_OBJ_WRITE(call->self, &e->schema_path, Qnil);
    return rb_funcall(ruby_evaluator(e), id_validate, 1, call->instance);
  }
  return rb_class_new_instance(1, &e->errors, cResult);
}
VALUE evaluator_validate(VALUE self, VALUE instance) {
  evaluator_t *e;
  TypedData_Get_Struct(self, evaluator_t, &evaluator_type, e);
  RB_OBJ_WRITE(self, &e->errors, rb_ary_new());
  RB_OBJ_WRITE(self, &e->instance_path, rb_ary_new());
  RB_OBJ_WRITE(self, &e->schema_path, rb_ary_new());
  rb_ary_clear(e->dynamic_scope);
  rb_hash_clear(e->active);
  e->error_count = 0;
  e->unsupported_instance = false;
  struct evaluator_call call = {self, instance, e};
  return rb_ensure(evaluator_validate_body, (VALUE)&call, evaluator_cleanup, (VALUE)&call);
}
