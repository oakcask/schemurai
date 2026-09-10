#include "schemurai_native.h"

/* Evaluator core: validity and annotations stay in a small native value type.
 * Ruby hashes are allocated lazily when an applicator records multiple locations. */

void add_unique(VALUE *list, VALUE value) {
  if (NIL_P(*list)) {
    *list = value;
    return;
  }
  if (RB_TYPE_P(*list, T_HASH)) {
    rb_hash_aset(*list, value, Qtrue);
    return;
  }
  if (!RTEST(rb_equal(*list, value))) {
    VALUE set = rb_hash_new();
    rb_hash_aset(set, *list, Qtrue);
    rb_hash_aset(set, value, Qtrue);
    *list = set;
  }
}
static int merge_location(VALUE value, VALUE ignored, VALUE target) {
  add_unique((VALUE *)target, value);
  return ST_CONTINUE;
}
void merge_locations(VALUE *target, VALUE source) {
  if (NIL_P(source))
    return;
  if (!RB_TYPE_P(source, T_HASH)) {
    add_unique(target, source);
    return;
  }
  rb_hash_foreach(source, merge_location, (VALUE)target);
}
void merge_evaluation(evaluation_t *target, evaluation_t source) {
  if (!source.valid) {
    target->valid = false;
    return;
  }
  if (!target->valid)
    return;
  merge_locations(&target->properties, source.properties);
  merge_locations(&target->items, source.items);
}
uint32_t instance_type(VALUE value, bool integer) {
  if (NIL_P(value))
    return TYPE_NULL;
  if (value == Qtrue || value == Qfalse)
    return TYPE_BOOLEAN;
  if (RB_TYPE_P(value, T_HASH))
    return TYPE_OBJECT;
  if (RB_TYPE_P(value, T_ARRAY))
    return TYPE_ARRAY;
  if (RB_TYPE_P(value, T_STRING))
    return TYPE_STRING;
  if (!number_p(value))
    return 0;
  return integer && integer_p(value) ? TYPE_NUMBER | TYPE_INTEGER : TYPE_NUMBER;
}
VALUE decimal(VALUE value) {
  if (RB_INTEGER_TYPE_P(value) || RB_TYPE_P(value, T_RATIONAL))
    return value;
  return rb_funcall(rb_mKernel, id_rational, 1, rb_funcall(value, id_to_s, 0));
}
static bool valid_number(evaluator_t *e, rule_t *r, VALUE value) {
  VALUE actual = (r->mask & NUM_MULTIPLE_OF) ? decimal(value) : value;
  if ((r->mask & NUM_MAXIMUM) && compare_values(actual, r->as.number.maximum) > 0)
    return false;
  if ((r->mask & NUM_MINIMUM) && compare_values(actual, r->as.number.minimum) < 0)
    return false;
  if ((r->mask & NUM_EXCLUSIVE_MAXIMUM) && compare_values(actual, r->as.number.exclusive_maximum) >= 0)
    return false;
  if ((r->mask & NUM_EXCLUSIVE_MINIMUM) && compare_values(actual, r->as.number.exclusive_minimum) <= 0)
    return false;
  if (r->mask & NUM_MULTIPLE_OF) {
    VALUE divisor = r->as.number.multiple_decimal;
    return RTEST(rb_funcall(divisor, id_positive_p, 0)) &&
           RTEST(rb_funcall(rb_funcall(actual, id_remainder, 1, divisor), id_zero_p, 0));
  }
  return true;
}

bool supported_value(VALUE value);
bool json_equal(evaluator_t *e, VALUE left, VALUE right) {
  if (!supported_value(right)) {
    e->unsupported_instance = true;
    return false;
  }
  if (number_p(left))
    return number_p(right) && RTEST(rb_equal(left, right));
  if (CLASS_OF(left) != CLASS_OF(right))
    return false;
  if (RB_TYPE_P(left, T_ARRAY)) {
    if (RARRAY_LEN(left) != RARRAY_LEN(right))
      return false;
    for (long i = 0; i < RARRAY_LEN(left); i++)
      if (!json_equal(e, rb_ary_entry(left, i), rb_ary_entry(right, i)))
        return false;
    return true;
  }
  if (RB_TYPE_P(left, T_HASH)) {
    if (RHASH_SIZE(left) != RHASH_SIZE(right))
      return false;
    VALUE keys = rb_funcall(left, id_keys, 0);
    VALUE right_keys = rb_funcall(right, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(right_keys); i++)
      if (CLASS_OF(rb_ary_entry(right_keys, i)) != rb_cString) {
        e->unsupported_instance = true;
        return false;
      }
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE k = rb_ary_entry(keys, i);
      if (!RTEST(rb_funcall(right, id_key_p, 1, k)) || !json_equal(e, rb_hash_aref(left, k), rb_hash_aref(right, k)))
        return false;
    }
    return true;
  }
  return RTEST(rb_equal(left, right));
}

static VALUE unique_item_key(evaluator_t *e, VALUE value) {
  if (CLASS_OF(value) == rb_cFloat && integer_p(value))
    return rb_funcall(value, id_to_i, 0);
  if (NIL_P(value) || value == Qtrue || value == Qfalse || RB_INTEGER_TYPE_P(value) || CLASS_OF(value) == rb_cFloat ||
      CLASS_OF(value) == rb_cString)
    return value;
  if (CLASS_OF(value) == rb_cArray) {
    long length = RARRAY_LEN(value);
    VALUE key = rb_ary_new_capa(length);
    for (long i = 0; i < length; i++) {
      VALUE item = unique_item_key(e, rb_ary_entry(value, i));
      if (item == Qundef)
        return Qundef;
      rb_ary_push(key, item);
    }
    return key;
  }
  if (CLASS_OF(value) == rb_cHash) {
    VALUE keys = rb_funcall(value, id_keys, 0), key = rb_hash_new();
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE name = rb_ary_entry(keys, i);
      if (CLASS_OF(name) != rb_cString) {
        e->unsupported_instance = true;
        return Qundef;
      }
      VALUE item = unique_item_key(e, rb_hash_aref(value, name));
      if (item == Qundef)
        return Qundef;
      rb_hash_aset(key, name, item);
    }
    return key;
  }
  e->unsupported_instance = true;
  return Qundef;
}

bool unique_items(evaluator_t *e, VALUE value) {
  VALUE seen = rb_hash_new();
  for (long i = 0; i < RARRAY_LEN(value); i++) {
    VALUE item = rb_ary_entry(value, i);
    VALUE key = unique_item_key(e, item);
    if (key == Qundef)
      return false;
    if (rb_hash_lookup2(seen, key, Qundef) != Qundef)
      return false;
    rb_hash_aset(seen, key, Qtrue);
  }
  return true;
}

VALUE protected_func(VALUE arg) {
  struct protected_call *c = (struct protected_call *)arg;
  return rb_funcallv(c->receiver, c->method, c->argc, c->argv);
}
VALUE regexp_for(evaluator_t *e, VALUE pattern) {
  VALUE found = rb_hash_lookup2(e->regexps, pattern, Qundef);
  if (found != Qundef)
    return found;
  VALUE regexp = rb_funcall(mNativeSupport, id_regexp, 1, pattern);
  rb_hash_aset(e->regexps, pattern, regexp);
  return regexp;
}
struct regexp_call {
  evaluator_t *e;
  VALUE pattern, value;
};
static VALUE regexp_match_func(VALUE arg) {
  struct regexp_call *call = (struct regexp_call *)arg;
  VALUE regexp = regexp_for(call->e, call->pattern);
  return rb_funcall(regexp, id_match_p, 1, call->value);
}
static bool regexp_matches(evaluator_t *e, VALUE pattern, VALUE value) {
  struct regexp_call call = {e, pattern, value};
  return RTEST(regexp_match_func((VALUE)&call));
}
static bool valid_string(evaluator_t *e, rule_t *r, VALUE value) {
  long length = rb_str_strlen(value);
  if (!NIL_P(r->as.string.max_length) && length > NUM2LONG(r->as.string.max_length))
    return false;
  if (!NIL_P(r->as.string.min_length) && length < NUM2LONG(r->as.string.min_length))
    return false;
  if (!NIL_P(r->as.string.pattern)) {
    struct regexp_call call = {e, r->as.string.pattern, value};
    int state = 0;
    VALUE matched = rb_protect(regexp_match_func, (VALUE)&call, &state);
    if (state) {
      VALUE error = rb_errinfo();
      if (!RTEST(rb_obj_is_kind_of(error, rb_eRegexpError)))
        rb_jump_tag(state);
      rb_set_errinfo(Qnil);
      return false;
    }
    if (!RTEST(matched))
      return false;
  }
  if (!NIL_P(r->as.string.format) && (e->format || r->as.string.format_assertion) &&
      !RTEST(rb_funcall(r->as.string.format, id_call, 1, value)))
    return false;
  if (e->content && (r->as.string.decode_base64 || r->as.string.parse_json) &&
      !RTEST(rb_funcall(mNativeSupport, id_valid_content_p, 3, value, r->as.string.decode_base64 ? Qtrue : Qfalse,
                        r->as.string.parse_json ? Qtrue : Qfalse)))
    return false;
  return true;
}

evaluation_t evaluate_program_mode(evaluator_t *e, VALUE program, VALUE instance, bool collect);
static int boolean_program(VALUE program) {
  program_t *p = PROGRAM_PTR(program);
  return p->length == 1 && p->instructions[0].opcode == OP_BOOLEAN ? (RTEST(p->instructions[0].operand) ? 1 : 0) : -1;
}
bool active_enter(evaluator_t *e, VALUE source, VALUE instance) {
  VALUE instances = rb_hash_lookup2(e->active, source, Qundef);
  if (instances == Qundef) {
    instances = rb_hash_new();
    rb_funcall(instances, id_compare_by_identity, 0);
    rb_hash_aset(e->active, source, instances);
  }
  if (rb_hash_lookup2(instances, instance, Qundef) != Qundef)
    return false;
  rb_hash_aset(instances, instance, Qtrue);
  return true;
}
void active_leave(evaluator_t *e, VALUE source, VALUE instance) {
  VALUE instances = rb_hash_lookup2(e->active, source, Qundef);
  if (instances != Qundef)
    rb_hash_delete(instances, instance);
}
static VALUE reference_target(evaluator_t *e, VALUE source, VALUE rule_obj) {
  VALUE target = rb_hash_lookup2(e->resolved, rule_obj, Qundef);
  if (target != Qundef)
    return target;
  rule_t *r;
  TypedData_Get_Struct(rule_obj, rule_t, &rule_type, r);
  target = compiler_resolve(e->compiler, source, r->as.reference.value);
  rb_hash_aset(e->resolved, rule_obj, target);
  return target;
}
static VALUE recursive_target(evaluator_t *e, VALUE source, VALUE rule_obj) {
  VALUE target = reference_target(e, source, rule_obj);
  rule_t *r = RULE_PTR(rule_obj);
  program_t *t = PROGRAM_PTR(target);
  if (!RB_TYPE_P(r->as.reference.fragment, T_STRING) || RSTRING_LEN(r->as.reference.fragment) || !t->recursive_anchor)
    return target;
  for (long i = 0; i < RARRAY_LEN(e->dynamic_scope); i++) {
    VALUE resource = rb_ary_entry(e->dynamic_scope, i);
    VALUE candidate = compiler_compile(e->compiler, rb_funcall(resource, id_root, 0));
    program_t *p = PROGRAM_PTR(candidate);
    if (p->recursive_anchor)
      return candidate;
  }
  return target;
}
static VALUE dynamic_target(evaluator_t *e, VALUE source, VALUE rule_obj) {
  VALUE target = reference_target(e, source, rule_obj);
  rule_t *r = RULE_PTR(rule_obj);
  program_t *t = PROGRAM_PTR(target);
  VALUE fragment = r->as.reference.fragment;
  if (NIL_P(fragment) || RSTRING_LEN(fragment) == 0 || RSTRING_PTR(fragment)[0] == '/' ||
      !RB_TYPE_P(t->dynamic_anchor, T_STRING) || !RTEST(rb_str_equal(t->dynamic_anchor, fragment)))
    return target;
  for (long i = 0; i < RARRAY_LEN(e->dynamic_scope); i++) {
    VALUE resource = rb_ary_entry(e->dynamic_scope, i);
    VALUE node = rb_funcall(e->graph, id_dynamic_anchor, 2, resource, fragment);
    if (!NIL_P(node))
      return compiler_compile(e->compiler, node);
  }
  return target;
}
struct target_call {
  evaluator_t *e;
  VALUE source, rule;
  uint8_t opcode;
};
static VALUE target_func(VALUE arg) {
  struct target_call *c = (struct target_call *)arg;
  if (c->opcode == OP_RECURSIVE_REF)
    return recursive_target(c->e, c->source, c->rule);
  if (c->opcode == OP_DYNAMIC_REF)
    return dynamic_target(c->e, c->source, c->rule);
  return reference_target(c->e, c->source, c->rule);
}
static VALUE cached_scope_target(evaluator_t *e, VALUE rule) {
  long length = RARRAY_LEN(e->dynamic_scope);
  if (length > CACHED_SCOPE_LIMIT)
    return Qundef;
  for (size_t i = 0; i < e->scope_cache_length; i++) {
    scope_cache_entry_t *entry = &e->scope_cache[i];
    if (entry->rule != rule || entry->length != length)
      continue;
    long j = 0;
    for (; j < length; j++)
      if (entry->resources[j] != rb_ary_entry(e->dynamic_scope, j))
        break;
    if (j == length)
      return entry->target;
  }
  return Qundef;
}
static void cache_scope_target(evaluator_t *e, VALUE rule, VALUE target) {
  long length = RARRAY_LEN(e->dynamic_scope);
  if (length > CACHED_SCOPE_LIMIT || e->scope_cache_length >= CACHED_SCOPE_ENTRY_LIMIT)
    return;
  if (e->scope_cache_length == e->scope_cache_capacity) {
    size_t capacity = e->scope_cache_capacity ? e->scope_cache_capacity * 2 : 4;
    REALLOC_N(e->scope_cache, scope_cache_entry_t, capacity);
    e->scope_cache_capacity = capacity;
  }
  scope_cache_entry_t *entry = &e->scope_cache[e->scope_cache_length++];
  entry->rule = rule;
  entry->target = target;
  entry->length = (uint8_t)length;
  for (long i = 0; i < length; i++)
    entry->resources[i] = rb_ary_entry(e->dynamic_scope, i);
}
VALUE safe_target(evaluator_t *e, VALUE source, VALUE rule, uint8_t opcode, int *state) {
  struct target_call call = {e, source, rule, opcode};
  VALUE cached = rb_hash_lookup2(e->resolved, rule, Qundef);
  if (cached == Qundef)
    return rb_protect(target_func, (VALUE)&call, state);
  if (opcode == OP_REF)
    return cached;
  VALUE target = cached_scope_target(e, rule);
  if (target != Qundef)
    return target;
  target = target_func((VALUE)&call);
  cache_scope_target(e, rule, target);
  return target;
}
static evaluation_t evaluate_reference(evaluator_t *e, VALUE source, VALUE target, VALUE instance, bool collect) {
  if (!active_enter(e, source, instance))
    return evaluation(true);
  evaluation_t r = evaluate_program_mode(e, target, instance, collect);
  active_leave(e, source, instance);
  return r;
}

static evaluation_t valid_array(evaluator_t *e, rule_t *r, VALUE value, evaluation_t prior, bool collect) {
  evaluation_t out = evaluation(true);
  long len = RARRAY_LEN(value);
  if (!NIL_P(r->as.array.max_items) && len > NUM2LONG(r->as.array.max_items))
    return evaluation(false);
  if (!NIL_P(r->as.array.min_items) && len < NUM2LONG(r->as.array.min_items))
    return evaluation(false);
  if (r->as.array.unique && !unique_items(e, value))
    return evaluation(false);
  if (!NIL_P(r->as.array.prefix_items))
    for (long i = 0; i < RARRAY_LEN(r->as.array.prefix_items) && i < len; i++) {
      evaluation_t x = evaluate_program(e, rb_ary_entry(r->as.array.prefix_items, i), rb_ary_entry(value, i));
      if (!x.valid)
        return evaluation(false);
      if (collect)
        add_unique(&out.items, LONG2NUM(i));
    }
  if (r->as.array.items_list) {
    long n = RARRAY_LEN(r->as.array.items);
    for (long i = 0; i < n && i < len; i++) {
      evaluation_t x = evaluate_program(e, rb_ary_entry(r->as.array.items, i), rb_ary_entry(value, i));
      if (!x.valid)
        return evaluation(false);
      if (collect)
        add_unique(&out.items, LONG2NUM(i));
    }
    if (!NIL_P(r->as.array.additional))
      for (long i = n; i < len; i++) {
        evaluation_t x = evaluate_program(e, r->as.array.additional, rb_ary_entry(value, i));
        if (!x.valid)
          return evaluation(false);
        if (collect)
          add_unique(&out.items, LONG2NUM(i));
      }
  } else if (!NIL_P(r->as.array.items)) {
    long start = NIL_P(r->as.array.prefix_items) ? 0 : RARRAY_LEN(r->as.array.prefix_items);
    for (long i = start; i < len; i++) {
      evaluation_t x = evaluate_program(e, r->as.array.items, rb_ary_entry(value, i));
      if (!x.valid)
        return evaluation(false);
      if (collect)
        add_unique(&out.items, LONG2NUM(i));
    }
  }
  if (!NIL_P(r->as.array.contains)) {
    long matches = 0;
    VALUE matched = Qnil;
    for (long i = 0; i < len; i++)
      if (evaluate_program(e, r->as.array.contains, rb_ary_entry(value, i)).valid) {
        matches++;
        if (collect)
          add_unique(&matched, LONG2NUM(i));
      }
    if (matches < NUM2LONG(r->as.array.min_contains) || compare_values(LONG2NUM(matches), r->as.array.max_contains) > 0)
      return evaluation(false);
    if (collect)
      merge_locations(&out.items, matched);
  }
  if (!NIL_P(r->as.array.unevaluated)) {
    int boolean = boolean_program(r->as.array.unevaluated);
    for (long i = 0; i < len; i++) {
      VALUE index = LONG2NUM(i);
      if (has_location(prior.items, index) || has_location(out.items, index))
        continue;
      if (boolean == 0)
        return evaluation(false);
      if (boolean < 0 && !evaluate_program(e, r->as.array.unevaluated, rb_ary_entry(value, i)).valid)
        return evaluation(false);
      add_unique(&out.items, index);
    }
  }
  return out;
}

static bool required_present(VALUE object, VALUE names) {
  if (NIL_P(names))
    return true;
  for (long i = 0; i < RARRAY_LEN(names); i++)
    if (rb_hash_lookup2(object, rb_ary_entry(names, i), Qundef) == Qundef)
      return false;
  return true;
}
typedef struct {
  evaluator_t *e;
  rule_t *r;
  evaluation_t *out;
  VALUE patterns;
  bool collect, valid;
} object_properties_context_t;
static int valid_object_property(VALUE name, VALUE item, VALUE arg) {
  object_properties_context_t *c = (object_properties_context_t *)arg;
  if (CLASS_OF(name) != rb_cString) {
    c->e->unsupported_instance = true;
    c->valid = false;
    return ST_STOP;
  }
  bool matched = false;
  VALUE child = rb_hash_lookup2(c->r->as.object.properties, name, Qundef);
  if (child != Qundef) {
    matched = true;
    if (!evaluate_program(c->e, child, item).valid) {
      c->valid = false;
      return ST_STOP;
    }
    if (c->collect)
      add_unique(&c->out->properties, name);
  }
  if (!NIL_P(c->patterns))
    for (long j = 0; j < RARRAY_LEN(c->patterns); j++) {
      VALUE pattern = rb_ary_entry(c->patterns, j);
      if (regexp_matches(c->e, pattern, name)) {
        matched = true;
        if (!evaluate_program(c->e, rb_hash_aref(c->r->as.object.patterns, pattern), item).valid) {
          c->valid = false;
          return ST_STOP;
        }
        if (c->collect)
          add_unique(&c->out->properties, name);
      }
    }
  if (!matched && !NIL_P(c->r->as.object.additional)) {
    if (!evaluate_program(c->e, c->r->as.object.additional, item).valid) {
      c->valid = false;
      return ST_STOP;
    }
    if (c->collect)
      add_unique(&c->out->properties, name);
  }
  return ST_CONTINUE;
}
typedef struct {
  evaluator_t *e;
  VALUE program;
  bool valid;
} property_name_context_t;
static int valid_property_name(VALUE name, VALUE item, VALUE arg) {
  property_name_context_t *c = (property_name_context_t *)arg;
  if (CLASS_OF(name) != rb_cString) {
    c->e->unsupported_instance = true;
    c->valid = false;
    return ST_STOP;
  }
  if (!evaluate_program(c->e, c->program, name).valid) {
    c->valid = false;
    return ST_STOP;
  }
  return ST_CONTINUE;
}
typedef struct {
  evaluator_t *e;
  VALUE program;
  evaluation_t prior, *out;
  int boolean;
  bool valid;
} unevaluated_property_context_t;
static int valid_unevaluated_property(VALUE name, VALUE item, VALUE arg) {
  unevaluated_property_context_t *c = (unevaluated_property_context_t *)arg;
  if (CLASS_OF(name) != rb_cString) {
    c->e->unsupported_instance = true;
    c->valid = false;
    return ST_STOP;
  }
  if (has_location(c->prior.properties, name) || has_location(c->out->properties, name))
    return ST_CONTINUE;
  if (c->boolean == 0) {
    c->valid = false;
    return ST_STOP;
  }
  if (c->boolean < 0 && !evaluate_program(c->e, c->program, item).valid) {
    c->valid = false;
    return ST_STOP;
  }
  add_unique(&c->out->properties, name);
  return ST_CONTINUE;
}
static evaluation_t valid_object(evaluator_t *e, rule_t *r, VALUE value, evaluation_t prior, bool collect) {
  evaluation_t out = evaluation(true);
  long len = RHASH_SIZE(value);
  if (!NIL_P(r->as.object.max_properties) && len > NUM2LONG(r->as.object.max_properties))
    return evaluation(false);
  if (!NIL_P(r->as.object.min_properties) && len < NUM2LONG(r->as.object.min_properties))
    return evaluation(false);
  if (!required_present(value, r->as.object.required))
    return evaluation(false);
  if (!RHASH_EMPTY_P(r->as.object.properties) || !NIL_P(r->as.object.patterns) || !NIL_P(r->as.object.additional)) {
    object_properties_context_t properties = {e, r, &out, r->as.object.pattern_names, collect, true};
    rb_hash_foreach(value, valid_object_property, (VALUE)&properties);
    if (!properties.valid)
      return evaluation(false);
  }
  if (!NIL_P(r->as.object.property_names)) {
    property_name_context_t names = {e, r->as.object.property_names, true};
    rb_hash_foreach(value, valid_property_name, (VALUE)&names);
    if (!names.valid)
      return evaluation(false);
  }
  VALUE dep_sets[] = {r->as.object.dependencies, r->as.object.dependent_required};
  for (int d = 0; d < 2; d++)
    if (!NIL_P(dep_sets[d])) {
      VALUE names = rb_funcall(dep_sets[d], id_keys, 0);
      for (long i = 0; i < RARRAY_LEN(names); i++) {
        VALUE name = rb_ary_entry(names, i);
        if (rb_hash_lookup2(value, name, Qundef) == Qundef)
          continue;
        VALUE dep = rb_hash_aref(dep_sets[d], name);
        if (RB_TYPE_P(dep, T_ARRAY)) {
          if (!required_present(value, dep))
            return evaluation(false);
        } else {
          evaluation_t x = evaluate_program_mode(e, dep, value, collect);
          if (!x.valid)
            return evaluation(false);
          if (collect)
            merge_locations(&out.properties, x.properties);
        }
      }
    }
  if (!NIL_P(r->as.object.dependent_schemas)) {
    VALUE names = rb_funcall(r->as.object.dependent_schemas, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(names); i++) {
      VALUE name = rb_ary_entry(names, i);
      if (rb_hash_lookup2(value, name, Qundef) == Qundef)
        continue;
      evaluation_t x = evaluate_program_mode(e, rb_hash_aref(r->as.object.dependent_schemas, name), value, collect);
      if (!x.valid)
        return evaluation(false);
      if (collect)
        merge_locations(&out.properties, x.properties);
    }
  }
  if (!NIL_P(r->as.object.unevaluated)) {
    unevaluated_property_context_t unevaluated = {
        e, r->as.object.unevaluated, prior, &out, boolean_program(r->as.object.unevaluated), true};
    rb_hash_foreach(value, valid_unevaluated_property, (VALUE)&unevaluated);
    if (!unevaluated.valid)
      return evaluation(false);
  }
  return out;
}

bool supported_value(VALUE value) {
  if (NIL_P(value) || value == Qtrue || value == Qfalse || RB_INTEGER_TYPE_P(value))
    return true;
  if (CLASS_OF(value) == rb_cFloat)
    return isfinite(RFLOAT_VALUE(value));
  return CLASS_OF(value) == rb_cString || CLASS_OF(value) == rb_cArray || CLASS_OF(value) == rb_cHash;
}

evaluation_t evaluate_program_mode(evaluator_t *e, VALUE program, VALUE instance, bool collect) {
  program_t *p = PROGRAM_PTR(program);
  if (p->length == 0)
    return evaluation(true);
  if (p->length == 1 && p->instructions[0].opcode == OP_BOOLEAN)
    return evaluation(RTEST(p->instructions[0].operand));
  if (p->length == 1)
    switch (p->instructions[0].opcode) {
    case OP_TYPE_NULL:
      return evaluation(NIL_P(instance));
    case OP_TYPE_BOOLEAN:
      return evaluation(instance == Qtrue || instance == Qfalse);
    case OP_TYPE_OBJECT:
      return evaluation(RB_TYPE_P(instance, T_HASH));
    case OP_TYPE_ARRAY:
      return evaluation(RB_TYPE_P(instance, T_ARRAY));
    case OP_TYPE_STRING:
      return evaluation(RB_TYPE_P(instance, T_STRING));
    default:
      break;
    }
  if (p->length == 1) {
    uint8_t opcode = p->instructions[0].opcode;
    if ((opcode == OP_STRING && !RB_TYPE_P(instance, T_STRING)) ||
        (opcode == OP_ARRAY && !RB_TYPE_P(instance, T_ARRAY)) || (opcode == OP_OBJECT && !RB_TYPE_P(instance, T_HASH)))
      return evaluation(true);
  }
  if (!supported_value(instance)) {
    e->unsupported_instance = true;
    return evaluation(false);
  }
  if (p->length == 1) {
    instruction_t *ins = &p->instructions[0];
    rule_t *r;
    switch (ins->opcode) {
    case OP_TYPE_NULL:
      return evaluation(NIL_P(instance));
    case OP_TYPE_BOOLEAN:
      return evaluation(instance == Qtrue || instance == Qfalse);
    case OP_TYPE_OBJECT:
      return evaluation(RB_TYPE_P(instance, T_HASH));
    case OP_TYPE_ARRAY:
      return evaluation(RB_TYPE_P(instance, T_ARRAY));
    case OP_TYPE_NUMBER:
      return evaluation(number_p(instance));
    case OP_TYPE_INTEGER:
      return evaluation(integer_p(instance));
    case OP_TYPE_STRING:
      return evaluation(RB_TYPE_P(instance, T_STRING));
    case OP_TYPES:
      r = RULE_PTR(ins->operand);
      return evaluation((r->mask & instance_type(instance, (r->mask & TYPE_INTEGER) != 0)) != 0);
    case OP_ENUM:
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++)
        if (json_equal(e, rb_ary_entry(ins->operand, j), instance))
          return evaluation(true);
      return evaluation(false);
    case OP_CONST:
      return evaluation(json_equal(e, ins->operand, instance));
    case OP_NUMBER:
      r = RULE_PTR(ins->operand);
      return evaluation(!number_p(instance) || valid_number(e, r, instance));
    case OP_STRING:
      r = RULE_PTR(ins->operand);
      return evaluation(!RB_TYPE_P(instance, T_STRING) || valid_string(e, r, instance));
    case OP_TYPED_NUMBER:
      r = RULE_PTR(ins->operand);
      return evaluation(number_p(instance) && valid_number(e, r, instance));
    case OP_TYPED_INTEGER:
      r = RULE_PTR(ins->operand);
      return evaluation(integer_p(instance) && valid_number(e, r, instance));
    case OP_TYPED_STRING:
      r = RULE_PTR(ins->operand);
      return evaluation(RB_TYPE_P(instance, T_STRING) && valid_string(e, r, instance));
    default:
      break;
    }
  }
  evaluation_t out = evaluation(true);
  bool entered = false;
  collect = collect || (p->flags & FLAG_EVALUATION);
  if (p->flags & FLAG_DYNAMIC_SCOPE) {
    VALUE resource = p->resource;
    if (RARRAY_LEN(e->dynamic_scope) == 0 || rb_ary_entry(e->dynamic_scope, -1) != resource) {
      rb_ary_push(e->dynamic_scope, resource);
      entered = true;
    }
  }
  for (size_t i = 0; i < p->length && out.valid && !e->unsupported_instance; i++) {
    instruction_t *ins = &p->instructions[i];
    rule_t *r = NULL;
    if (ins->opcode == OP_TYPES || ins->opcode >= OP_CONDITIONAL)
      r = RULE_PTR(ins->operand);
    evaluation_t x;
    switch (ins->opcode) {
    case OP_BOOLEAN:
      out.valid = RTEST(ins->operand);
      break;
    case OP_REF:
    case OP_RECURSIVE_REF:
    case OP_DYNAMIC_REF: {
      int state = 0;
      VALUE target = safe_target(e, program, ins->operand, ins->opcode, &state);
      if (state) {
        if (!RTEST(rb_obj_is_kind_of(rb_errinfo(), eResolutionError)))
          rb_jump_tag(state);
        rb_set_errinfo(Qnil);
        out.valid = false;
      } else {
        x = evaluate_reference(e, program, target, instance, collect);
        merge_evaluation(&out, x);
      }
      break;
    }
    case OP_TYPE_NULL:
      out.valid = NIL_P(instance);
      break;
    case OP_TYPE_BOOLEAN:
      out.valid = instance == Qtrue || instance == Qfalse;
      break;
    case OP_TYPE_OBJECT:
      out.valid = RB_TYPE_P(instance, T_HASH);
      break;
    case OP_TYPE_ARRAY:
      out.valid = RB_TYPE_P(instance, T_ARRAY);
      break;
    case OP_TYPE_NUMBER:
      out.valid = number_p(instance);
      break;
    case OP_TYPE_INTEGER:
      out.valid = integer_p(instance);
      break;
    case OP_TYPE_STRING:
      out.valid = RB_TYPE_P(instance, T_STRING);
      break;
    case OP_TYPES:
      out.valid = (r->mask & instance_type(instance, (r->mask & TYPE_INTEGER) != 0)) != 0;
      break;
    case OP_ENUM:
      out.valid = false;
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++)
        if (json_equal(e, rb_ary_entry(ins->operand, j), instance)) {
          out.valid = true;
          break;
        }
      break;
    case OP_CONST:
      out.valid = json_equal(e, ins->operand, instance);
      break;
    case OP_ALL_OF:
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++) {
        x = evaluate_program_mode(e, rb_ary_entry(ins->operand, j), instance, collect);
        merge_evaluation(&out, x);
        if (!out.valid)
          break;
      }
      break;
    case OP_ANY_OF: {
      bool matched = false;
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++) {
        x = evaluate_program_mode(e, rb_ary_entry(ins->operand, j), instance, collect);
        if (x.valid) {
          matched = true;
          merge_evaluation(&out, x);
          if (!collect)
            break;
        }
      }
      out.valid = matched;
      break;
    }
    case OP_ONE_OF: {
      long matches = 0;
      evaluation_t found = evaluation(true);
      for (long j = 0; j < RARRAY_LEN(ins->operand); j++) {
        x = evaluate_program_mode(e, rb_ary_entry(ins->operand, j), instance, collect);
        if (x.valid) {
          matches++;
          found = x;
          if (matches > 1)
            break;
        }
      }
      if (matches == 1)
        merge_evaluation(&out, found);
      else
        out.valid = false;
      break;
    }
    case OP_NOT:
      out.valid = !evaluate_program(e, ins->operand, instance).valid;
      break;
    case OP_CONDITIONAL:
      x = evaluate_program_mode(e, r->as.conditional.condition, instance, collect);
      if (x.valid) {
        merge_evaluation(&out, x);
        if (!NIL_P(r->as.conditional.then_branch))
          merge_evaluation(&out, evaluate_program_mode(e, r->as.conditional.then_branch, instance, collect));
      } else if (!NIL_P(r->as.conditional.else_branch))
        merge_evaluation(&out, evaluate_program_mode(e, r->as.conditional.else_branch, instance, collect));
      break;
    case OP_NUMBER:
      if (number_p(instance))
        out.valid = valid_number(e, r, instance);
      break;
    case OP_STRING:
      if (RB_TYPE_P(instance, T_STRING))
        out.valid = valid_string(e, r, instance);
      break;
    case OP_ARRAY:
      if (RB_TYPE_P(instance, T_ARRAY)) {
        x = valid_array(e, r, instance, out, collect);
        merge_evaluation(&out, x);
      }
      break;
    case OP_OBJECT:
      if (RB_TYPE_P(instance, T_HASH)) {
        x = valid_object(e, r, instance, out, collect);
        merge_evaluation(&out, x);
      }
      break;
    case OP_TYPED_NUMBER:
      out.valid = number_p(instance) && valid_number(e, r, instance);
      break;
    case OP_TYPED_INTEGER:
      out.valid = integer_p(instance) && valid_number(e, r, instance);
      break;
    case OP_TYPED_STRING:
      out.valid = RB_TYPE_P(instance, T_STRING) && valid_string(e, r, instance);
      break;
    case OP_TYPED_ARRAY:
      if (RB_TYPE_P(instance, T_ARRAY)) {
        x = valid_array(e, r, instance, out, collect);
        merge_evaluation(&out, x);
      } else
        out.valid = false;
      break;
    case OP_TYPED_OBJECT:
      if (RB_TYPE_P(instance, T_HASH)) {
        x = valid_object(e, r, instance, out, collect);
        merge_evaluation(&out, x);
      } else
        out.valid = false;
      break;
    default:
      rb_bug("unknown VM opcode: %u", ins->opcode);
    }
  }
  if (entered)
    rb_ary_pop(e->dynamic_scope);
  return out;
}

VALUE compiler_evaluator(int argc, VALUE *argv, VALUE self) {
  VALUE node, options;
  rb_scan_args(argc, argv, "1:", &node, &options);
  bool content = RTEST(rb_hash_aref(options, sym_content));
  bool format = RTEST(rb_hash_aref(options, sym_format));
  compiler_t *c;
  TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  VALUE evaluator = evaluator_alloc(cEvaluator);
  evaluator_t *e;
  TypedData_Get_Struct(evaluator, evaluator_t, &evaluator_type, e);
  RB_OBJ_WRITE(evaluator, &e->graph, c->graph);
  RB_OBJ_WRITE(evaluator, &e->compiler, self);
  RB_OBJ_WRITE(evaluator, &e->root, compiler_compile(self, node));
  RB_OBJ_WRITE(evaluator, &e->regexps, rb_hash_new());
  RB_OBJ_WRITE(evaluator, &e->resolved, rb_hash_new());
  rb_funcall(e->resolved, id_compare_by_identity, 0);
  RB_OBJ_WRITE(evaluator, &e->dynamic_scope, rb_ary_new());
  RB_OBJ_WRITE(evaluator, &e->active, rb_hash_new());
  rb_funcall(e->active, id_compare_by_identity, 0);
  e->content = content;
  e->format = format;
  e->unsupported_instance = false;
  return evaluator;
}
VALUE evaluator_backend(VALUE self) {
  return sym_vm;
}
VALUE ruby_evaluator(evaluator_t *e) {
  program_t *p;
  TypedData_Get_Struct(e->root, program_t, &program_type, p);
  VALUE kwargs = rb_hash_new();
  rb_hash_aset(kwargs, sym_content, e->content ? Qtrue : Qfalse);
  rb_hash_aset(kwargs, sym_format, e->format ? Qtrue : Qfalse);
  VALUE argv[] = {e->graph, p->node, kwargs};
  return rb_class_new_instance_kw(3, argv, cRubyEvaluator, RB_PASS_KEYWORDS);
}
VALUE evaluator_cleanup(VALUE arg) {
  struct evaluator_call *call = (struct evaluator_call *)arg;
  evaluator_t *e = call->e;
  rb_hash_clear(e->active);
  rb_ary_clear(e->dynamic_scope);
  RB_OBJ_WRITE(call->self, &e->errors, Qnil);
  RB_OBJ_WRITE(call->self, &e->instance_path, Qnil);
  RB_OBJ_WRITE(call->self, &e->schema_path, Qnil);
  return Qnil;
}
static VALUE evaluator_valid_body(VALUE arg) {
  struct evaluator_call *call = (struct evaluator_call *)arg;
  evaluator_t *e = call->e;
  bool valid = evaluate_program(e, e->root, call->instance).valid;
  if (e->unsupported_instance)
    return rb_funcall(ruby_evaluator(e), id_valid_p, 1, call->instance);
  return valid ? Qtrue : Qfalse;
}
VALUE evaluator_valid(VALUE self, VALUE instance) {
  evaluator_t *e;
  TypedData_Get_Struct(self, evaluator_t, &evaluator_type, e);
  rb_ary_clear(e->dynamic_scope);
  rb_hash_clear(e->active);
  e->unsupported_instance = false;
  struct evaluator_call call = {self, instance, e};
  return rb_ensure(evaluator_valid_body, (VALUE)&call, evaluator_cleanup, (VALUE)&call);
}
