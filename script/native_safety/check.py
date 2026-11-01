"""Clang-based checks for the native extension's trusted C boundary.

No source snippets are evaluated. Calls and field accesses come from Clang's
expanded, typed AST, including calls introduced by Ruby header macros.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


class ContractError(Exception):
    pass


def walk(node):
    yield node
    for child in node.get("inner", []):
        yield from walk(child)


def children(node, kind):
    return [item for item in walk(node) if item.get("kind") == kind]


def reference(node):
    """Resolve a callee/argument through casts, without descending into calls."""
    if node.get("kind") == "DeclRefExpr":
        return node.get("referencedDecl", {}).get("name")
    if node.get("kind") in {"ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "UnaryOperator"}:
        inner = node.get("inner", [])
        if len(inner) == 1:
            return reference(inner[0])
    return None


def calls(node):
    for call in children(node, "CallExpr"):
        inner = call.get("inner", [])
        yield reference(inner[0]) if inner else None, inner[1:]


def function_references(node):
    return {item["referencedDecl"]["name"] for item in children(node, "DeclRefExpr")
            if item.get("referencedDecl", {}).get("kind") == "FunctionDecl"}


def ast_nodes(stream):
    """Consume Clang's top-level declaration framing without reparsing prefixes.

    Clang's JSON dumper indents top-level object terminators by four spaces.
    JSON strings cannot contain literal newlines, so this framing cannot match
    a string value. Unexpected framing fails closed instead of losing nodes.
    """
    for line in stream:
        if line == '  "inner": [\n':
            break
    else:
        raise ContractError("Clang did not produce a translation-unit AST")
    lines = []
    skip = False
    for line in stream:
        if line == '  ]\n':
            if lines or stream.read().strip() != "}":
                raise ContractError("invalid Clang AST trailer")
            return
        if not lines and line != '    {\n':
            raise ContractError("unrecognized Clang declaration framing")
        # rb_define_method expansions make Init enormous. It is not an adapter
        # or a callable leaf. Any attempt to reach it fails as an unknown call.
        if line == '      "name": "Init_schemurai_native",\n':
            skip = True
        lines.append(line if not skip else "")
        if line in {'    },\n', '    }\n'}:
            if not skip:
                yield json.loads("".join(lines).rstrip("\n,"))
            lines = []
            skip = False
    raise ContractError("truncated Clang AST")


class TranslationUnit:
    def __init__(self, nodes):
        self.functions = {}
        self.records = {}
        self.aliases = {}
        self.variables = {}
        for node in nodes:
            # Main-file locations have no includedFrom entry. Clang elides the
            # repeated file name, so comparing loc.file alone loses declarations.
            if "includedFrom" in node.get("loc", {}):
                continue
            kind = node.get("kind")
            if kind == "FunctionDecl" and any(c.get("kind") == "CompoundStmt" for c in node.get("inner", [])):
                self.functions[node["name"]] = node
            elif kind == "RecordDecl" and node.get("completeDefinition"):
                self.records[node["id"]] = node
            elif kind == "TypedefDecl":
                tags = [part["ownedTagDecl"]["id"] for part in walk(node) if "ownedTagDecl" in part]
                if tags:
                    self.aliases[node["name"]] = tags[0]
            elif kind == "VarDecl":
                self.variables[node["name"]] = node

    def function(self, name):
        if name not in self.functions:
            raise ContractError(f"missing C function definition: {name}")
        return self.functions[name]


def parse_c(source, clang, includes=(), defines=()):
    command = [clang, "-fsyntax-only", "-Xclang", "-ast-dump=json"]
    command += ["-I" + directory for directory in includes]
    command += ["-D" + definition for definition in defines]
    command.append(str(source))
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output:
        subprocess.run(command, stdout=output, check=True)
        output.seek(0)
        return TranslationUnit(ast_nodes(output))


def compile_ast(source, ruby, clang, defines):
    config = json.loads(subprocess.check_output([
        ruby, "-rrbconfig", "-rjson", "-e",
        'puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir", "rubyarchhdrdir"))',
    ], text=True))
    return parse_c(source, clang, config, defines)


def rust_imports(source):
    # Foreign declarations have a deliberately constrained spelling in ruby.rs;
    # the syn check separately prohibits other declaration sites and macros.
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    blocks = re.findall(r'unsafe\s+extern\s+"C"\s*\{([^{}]*)\}', source)
    names = {name for block in blocks for name in re.findall(r"\bfn\s+(sn_\w+)\s*\(", block)}
    if not names:
        raise ContractError("missing Rust foreign adapter declarations")
    return names


def protected_adapters():
    contract = Path(__file__).resolve().parents[2] / "ext/schemurai_native/protected.def"
    result = {}
    for line in contract.read_text().splitlines():
        match = re.fullmatch(r"SN_PROTECTED\((sn_\w+), (\w+)\)", line)
        if not match or match[1] in result:
            raise ContractError("invalid or duplicate protected adapter contract")
        result[match[1]] = match[2]
    if not result:
        raise ContractError("empty protected adapter contract")
    return result


PROTECTED = protected_adapters()


# Exact external API leaves. Preconditions are documented alongside adapters in
# glue.c; this list is an audited trust boundary, not an allocation name heuristic.
PURE_EXTERNAL = {
    # CRuby metadata and explicitly classified scalar/collection reads.
    "RB_ENCODING_GET", "RB_ENC_CODERANGE", "rb_array_const_ptr", "rb_array_len",
    "rb_ary_entry", "rb_class_of", "rb_float_value", "rb_hash_size_num", "rb_type",
    "rb_integer_type_p", "rbimpl_RB_TYPE_P_fastpath", "rb_ivar_get", "rb_sym2id",
    "rb_fix2int", "rb_fix2long", "rb_big_sign", "rb_absint_size", "rb_absint_numwords",
    "rb_integer_pack", "rb_str_cmp", "rb_str_strlen", "rb_debug_rstring_null_ptr",
    # Ordinary-string keys/identity tables only; callbacks are traversed below.
    "rb_hash_foreach", "rb_hash_stlike_foreach", "rb_hash_lookup2", "rb_st_lookup",
    # Existing Bignum digits only; adapters guard against coercion/Float paths.
    "rb_big_cmp", "rb_big_eql", "rb_hash",
    # Compiler intrinsics and scalar C math have no Ruby effects.
    "__builtin_constant_p", "__builtin_expect", "__builtin_isfinite", "trunc",
}
RUST_CALLBACKS = {"sn_identity_kind", "sn_reference_pair", "sn_object_entry"}


def check_effects(unit, imports):
    unknown = set()
    reachable = set()
    pending = list(imports - set(PROTECTED) - {"sn_pin"})
    while pending:
        name = pending.pop()
        if name in reachable:
            continue
        reachable.add(name)
        if name in RUST_CALLBACKS:
            continue
        if name not in unit.functions:
            unknown.add(name)
            continue
        node = unit.functions[name]
        for expression in children(node, "CallExpr"):
            callee = unwrap(expression["inner"][0])
            if not (callee.get("kind") == "DeclRefExpr" and callee.get("referencedDecl", {}).get("kind") == "FunctionDecl"):
                callback_type = {"hash_visit": "hash_callback", "key_view_visit": "key_view_callback"}.get(name)
                if not (callback_type and callee.get("kind") == "MemberExpr"
                        and callee.get("name") == "callback" and callee.get("type", {}).get("qualType") == callback_type):
                    raise ContractError(f"unreviewed indirect call in non-allocating adapter: {name}")
        for target in function_references(node):
            if target in unit.functions or target in RUST_CALLBACKS:
                pending.append(target)
            elif target not in PURE_EXTERNAL:
                unknown.add(target)
    if unknown:
        raise ContractError("unreviewed calls reachable from non-allocating adapters: " + ", ".join(sorted(unknown)))
    for name, callback in PROTECTED.items():
        node = unit.function(name)
        direct = list(calls(node))
        if len(direct) != 1 or direct[0][0] != "protected_result" or reference(direct[0][1][0]) != callback:
            raise ContractError(f"{name} must call only protected_result with {callback}")
    pin = list(calls(unit.function("sn_pin")))
    if len(pin) != 1 or pin[0][0] != "rb_gc_mark":
        raise ContractError("sn_pin must pin handles using rb_gc_mark")
    return reachable


def unwrap(node):
    while node.get("kind") in {"ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "ConstantExpr"}:
        inner = node.get("inner", [])
        if len(inner) != 1:
            break
        node = inner[0]
    return node


def shape(node):
    """Control/data shape independent of addresses, paths, casts and formatting."""
    node = unwrap(node)
    kind = node.get("kind", "empty")
    inner = [shape(child) for child in node.get("inner", [])]
    if kind == "DeclRefExpr":
        return ("ref", node["referencedDecl"]["name"])
    if kind == "MemberExpr":
        return ("field", node["name"], *inner)
    if kind in {"IntegerLiteral", "StringLiteral"}:
        return (kind, node["value"])
    if kind == "CallExpr":
        return ("call", *inner)
    if kind in {"UnaryOperator", "BinaryOperator", "CompoundAssignOperator"}:
        return (node["opcode"], *inner)
    if kind == "VarDecl":
        return ("var", node["name"], *inner)
    return (kind, *inner)


def body(node):
    return next(child for child in node.get("inner", []) if child.get("kind") == "CompoundStmt")


def ref(name):
    return ("ref", name)


def field(name, owner):
    return ("field", name, ref(owner))


def call(name, *arguments):
    return ("call", ref(name), *arguments)


ZERO = ("IntegerLiteral", "0")


def check_barrier(unit):
    expected = ("CompoundStmt",
        ("DeclStmt", ("var", "state", ZERO)),
        ("=", ("*", ref("result")), call("rb_protect", ref("callback"), ref("argument"), ("&", ref("state")))),
        ("IfStmt", ref("state"), ("CompoundStmt",
            ("=", ("*", ref("result")), call("rb_errinfo")),
            call("rb_set_errinfo", ref("RUBY_Qnil")))),
        ("ReturnStmt", ref("state")))
    if shape(body(unit.function("protected_result"))) != expected:
        raise ContractError("protected_result must capture and clear Ruby exceptions before returning status")


HOLDERS = {
    # record: (TypedData, mark, free, size, borrowed pointers, Rust roots)
    "holder": ("engine_type", "mark", "release", "size", {"engine"}, {"roots": "sn_roots_mark"}),
    "runner_holder": ("runner_type", "runner_mark", "runner_release", "runner_size",
                      {"frame_indices"}, {"caches": "sn_caches_mark", "root_snapshot": "sn_root_snapshot_mark"}),
    "report_holder": ("report_type", "report_mark", "report_release", "report_size", set(), {"report": "sn_report_mark"}),
    "report_collector": ("report_collector_type", "report_collector_mark", "report_collector_free", "report_collector_size",
                         set(), {"report": "sn_report_mark"}),
    "property_locations_holder": ("property_locations_type", "property_locations_mark", "property_locations_free", "property_locations_size",
                                  set(), {"locations": "sn_property_locations_mark"}),
}


def native_type(unit, spelling, seen=frozenset()):
    if spelling == "VALUE":
        return False
    if spelling in {"int", "size_t", "uint32_t", "double", "unsigned long", "unsigned int"}:
        return True
    if spelling in unit.aliases and spelling not in seen:
        record = unit.records.get(unit.aliases[spelling])
        if record:
            return all(native_type(unit, item["type"]["qualType"], seen | {spelling})
                       for item in record.get("inner", []) if item.get("kind") == "FieldDecl")
    return False


def check_holder(unit, name, spec):
    data_type, marker, releaser, sizer, borrowed, rust_roots = spec
    if name not in unit.aliases or unit.aliases[name] not in unit.records:
        raise ContractError(f"missing TypedData holder: {name}")
    record = unit.records[unit.aliases[name]]
    fields = {part["name"]: part for part in record.get("inner", []) if part.get("kind") == "FieldDecl"}
    values = {key for key, part in fields.items() if part["type"]["qualType"] == "VALUE"}
    # A reference to the collector itself is a self-edge, not an independent
    # root. All other VALUE fields must be pinned unconditionally.
    self_edge = {"self"} if name == "report_collector" else set()
    table = {"matches"} if name == "runner_holder" else set()
    for key, part in fields.items():
        if key not in values | borrowed | set(rust_roots) | table and not native_type(unit, part["type"]["qualType"]):
            raise ContractError(f"unclassified native/Ruby storage: {name}.{key}")
    statements = body(unit.function(marker))["inner"]
    if not statements or statements[0].get("kind") != "DeclStmt":
        raise ContractError(f"{marker} must bind its own TypedData pointer")
    declaration = statements[0].get("inner", [])
    if len(declaration) != 1 or declaration[0].get("kind") != "VarDecl":
        raise ContractError(f"{marker}: unsupported holder binding")
    alias = declaration[0]["name"]
    parameters = [part["name"] for part in unit.function(marker)["inner"] if part.get("kind") == "ParmVarDecl"]
    if len(parameters) != 1 or shape(declaration[0]) != ("var", alias, ref(parameters[0])):
        raise ContractError(f"{marker} must mark the callback's holder")
    expected = {call("rb_gc_mark", field(key, alias)) for key in values - self_edge}
    for key, target in rust_roots.items():
        if key not in fields:
            raise ContractError(f"missing Rust root storage: {name}.{key}")
        condition = field(key, alias)
        if name == "report_collector":
            condition = ("&&", condition, ("!", field("busy", alias)))
        expected.add(("IfStmt", condition, call(target, field(key, alias))))
    if table:
        expected.add(("IfStmt", field("matches", alias),
                      call("rb_st_foreach", field("matches", alias), ref("mark_operation"), ZERO)))
    actual = [shape(statement) for statement in statements[1:]]
    if len(actual) != len(expected) or set(actual) != expected:
        raise ContractError(f"{marker} must pin every VALUE and visit each Rust/table root with its audited guard")
    variable = unit.variables.get(data_type)
    if not variable:
        raise ContractError(f"missing TypedData registration: {data_type}")
    initializers = [item for item in variable.get("inner", []) if item.get("kind") == "InitListExpr"]
    if len(initializers) != 1 or len(initializers[0].get("inner", [])) != 5:
        raise ContractError(f"unsupported TypedData initializer: {data_type}")
    parts = initializers[0]["inner"]
    if function_references(parts[1]) != {marker, releaser, sizer} or function_references(variable) != {marker, releaser, sizer}:
        raise ContractError(f"{data_type} must install its audited mark/free/size callbacks")
    flag = ref("RUBY_TYPED_FREE_IMMEDIATELY")
    if name == "holder":
        flag = ("|", flag, ref("RUBY_TYPED_FROZEN_SHAREABLE"))
    if shape(parts[-1]) != flag:
        raise ContractError(f"{data_type}: only frozen Programs may be Ractor-shareable")


def check_roots(unit):
    registrations = {name for name, node in unit.variables.items()
                     if "rb_data_type_t" in node.get("type", {}).get("qualType", "")}
    expected = {spec[0] for spec in HOLDERS.values()} | {"construction_guard_type"}
    if registrations != expected:
        raise ContractError("every TypedData registration requires an ownership contract")
    for name, spec in HOLDERS.items():
        check_holder(unit, name, spec)
    # ST lookup tables carry Ruby keys at two levels; the outer operation key
    # and all values are native scalars or child ST tables.
    for name, expected in {
        "mark_match": ("CompoundStmt", call("rb_gc_mark", ref("key")), ("ReturnStmt", ref("ST_CONTINUE"))),
        "mark_pattern_matches": ("CompoundStmt", call("rb_gc_mark", ref("key")),
            call("rb_st_foreach", ref("value"), ref("mark_match"), ZERO), ("ReturnStmt", ref("ST_CONTINUE"))),
        "mark_operation": ("CompoundStmt", call("rb_st_foreach", ref("value"), ref("mark_pattern_matches"), ZERO), ("ReturnStmt", ref("ST_CONTINUE"))),
    }.items():
        if shape(body(unit.function(name))) != expected:
            raise ContractError(f"{name}: ST table Ruby keys must remain pinned")


def check_publication(unit):
    expected = ("CompoundStmt",
        ("DeclStmt", ("var", "h", call("ready_program", ref("self")))),
        ("DeclStmt", ("var", "count", call("sn_root_count", field("roots", "h")))),
        ("ForStmt", ("DeclStmt", ("var", "i", ZERO)), ("empty",),
            ("<", ref("i"), ref("count")), ("++", ref("i")),
            call("rb_ractor_make_shareable", call("sn_root_at", field("roots", "h"), ref("i")))),
        call("rb_ractor_make_shareable", field("program", "h")),
        ("ReturnStmt", call("rb_ractor_make_shareable", ref("self"))))
    if shape(body(unit.function("make_shareable"))) != expected:
        raise ContractError("publish only a ready Program after making all hidden roots shareable")
    statements = body(unit.function("ready_program"))["inner"]
    if len(statements) != 5:
        raise ContractError("ready_program must reject uninitialized/compiling programs")
    if shape(statements[0]) != ("DeclStmt", ("var", "h")) or shape(statements[-1]) != ("ReturnStmt", ref("h")):
        raise ContractError("ready_program must return its own checked holder")
    binding = shape(statements[1])
    allowed_bindings = {("=", ref("h"), call(target, ref("self"), ("&", ref("engine_type"))))
                        for target in {"rb_check_typeddata", "rbimpl_check_typeddata"}}
    if binding not in allowed_bindings:
        raise ContractError("ready_program must check the Program TypedData type")
    guards = [shape(statement) for statement in statements[2:4]]
    for guard, condition in zip(guards, [("!", field("engine", "h")), field("compiling", "h")]):
        if len(guard) != 3 or guard[0] != "IfStmt" or guard[1] != condition or guard[2][:2] != ("call", ref("rb_raise")):
            raise ContractError("ready_program must reject uninitialized/compiling programs")


GLOBAL_IDS = {
    "id_resolve", "id_schemurai", "id_resolution_error", "id_root", "id_compile", "id_graph",
    "id_dynamic_anchor", "id_dynamic_anchor_names", "id_dynamic_anchor_count",
}


def check_globals(unit):
    types = {name: "ID" for name in GLOBAL_IDS}
    types.update({name: "int" for name in {"utf8_index", "ascii_index", "binary_index"}})
    types.update({"identity_methods": "ID[5]", "active_caches": "const void *"})
    types.update({spec[0]: "const rb_data_type_t" for spec in HOLDERS.values()})
    types["construction_guard_type"] = "const rb_data_type_t"
    if set(unit.variables) != set(types) | {"fields", "opcodes"}:
        raise ContractError("new C global storage requires a Ractor/GC ownership contract")
    for name, spelling in types.items():
        node = unit.variables[name]
        if node.get("storageClass") != "static" or node.get("type", {}).get("qualType") != spelling:
            raise ContractError(f"global {name} must remain native metadata or borrowed runtime state")
        if (name == "active_caches") != (node.get("tls") is not None):
            raise ContractError("only the borrowed active_caches pointer may use C thread-local storage")
    for name, expected in {"fields": {"id": "ID", "symbol": "const char *"},
                           "opcodes": {"id": "ID", "symbol": "const char *", "opcode": "int"}}.items():
        spelling = unit.variables[name]["type"]["qualType"]
        match = re.search(r" at .*:(\d+):(\d+)\)\[\d+\]$", spelling)
        if not match:
            raise ContractError(f"unsupported native metadata table: {name}")
        record = next((record for record in unit.records.values()
                       if record.get("loc", {}).get("line") == int(match[1])
                       and record.get("loc", {}).get("col") == int(match[2])), None)
        actual = {item["name"]: item["type"]["qualType"] for item in (record or {}).get("inner", [])
                  if item.get("kind") == "FieldDecl"}
        if actual != expected:
            raise ContractError(f"global metadata table {name} must not retain Ruby objects")


PUBLICATIONS = {
    "sn_message_result": ({"evaluate_runtime"}, "messages"),
    "sn_pointer_result": ({"evaluate_runtime"}, "pointers"),
    "sn_properties_result": ({"merge_runtime_properties"}, "report_results"),
    "sn_report_accept": ({"container_report_runtime", "call_runtime"}, "report_results"),
}


def check_result_roots(unit):
    """Require the root write immediately before publication into Rust caches.

    These are structural proof rules for the actual driver protocol, not an
    optimistic search for some earlier rb_ary_push elsewhere in a function.
    """
    found = {name: set() for name in PUBLICATIONS}
    reviewed = set()
    all_publications = {item["id"] for node in unit.functions.values() for item in children(node, "CallExpr")
                        if reference(item["inner"][0]) in PUBLICATIONS}
    for function, node in unit.functions.items():
        for compound in children(node, "CompoundStmt"):
            statements = compound.get("inner", [])
            for index, statement in enumerate(statements):
                parts = list(calls(statement))
                # Nested blocks are visited independently, retaining dominance.
                if statement.get("kind") in {"IfStmt", "ForStmt", "WhileStmt", "CompoundStmt"}:
                    continue
                for target, arguments in parts:
                    if target not in PUBLICATIONS:
                        continue
                    owners, root = PUBLICATIONS[target]
                    if function not in owners:
                        raise ContractError(f"{target}: new publication site needs an ownership contract")
                    found[target].add(function)
                    reviewed.update(item["id"] for item in children(statement, "CallExpr")
                                    if reference(item["inner"][0]) == target)
                    offset = 3 if target == "sn_report_accept" else 1
                    root_write = (call("root_runtime_locations", field(root, "r"), ("&", ref("locations")))
                                  if target == "sn_properties_result"
                                  else call("rb_ary_push", field(root, "r"), ref("result")))
                    if index < offset or shape(statements[index - offset]) != root_write:
                        raise ContractError(f"{target}: C must root the completed result before publishing it to Rust")
                    if target == "sn_report_accept":
                        # The rooted result is the owner of completed->report.
                        if shape(statements[index - 2]) != ("DeclStmt", ("var", "completed")):
                            raise ContractError("report publication must extract the rooted TypedData owner")
                        assignment = shape(statements[index - 1])
                        allowed = {("=", ref("completed"), call(helper, ref("result"), ("&", ref("report_type"))))
                                   for helper in {"rb_check_typeddata", "rbimpl_check_typeddata"}}
                        if assignment not in allowed or shape(arguments[1]) != field("report", "completed"):
                            raise ContractError("report publication must extract the rooted TypedData owner")
                    elif target == "sn_properties_result":
                        # All copied handles are rooted by root_runtime_locations.
                        origins = [shape(item) for item in statements[:index - 1]]
                        expected = ("DeclStmt", ("var", "locations", call("read_runtime_locations", ref("result"))))
                        if expected not in origins or shape(arguments[1]) != ("&", ref("locations")):
                            raise ContractError("property locations must belong to the rooted result buffer")
                    elif shape(arguments[1]) != ref("result"):
                        raise ContractError(f"{target}: published handle must be the rooted result")
    if reviewed != all_publications:
        raise ContractError("every result publication must have a dominating C root write")
    for target, (owners, _) in PUBLICATIONS.items():
        if found[target] != owners:
            raise ContractError(f"missing reviewed publication site: {target}")


def check_snapshot_protocol(unit):
    # Construction and replacement occur outside native passes. Never discard
    # the previous snapshot before the new complete snapshot is published.
    expected = ("CompoundStmt",
        ("DeclStmt", ("var", "next", call("sn_caches_snapshot", field("caches", "runner")))),
        ("IfStmt", ("!", ref("next")), call("rb_raise", ref("rb_eRuntimeError"),
            ("StringLiteral", '\"native root snapshot has an active borrow\"'))),
        ("DeclStmt", ("var", "previous", field("root_snapshot", "runner"))),
        ("=", field("root_snapshot", "runner"), ref("next")),
        call("sn_root_snapshot_free", ref("previous")))
    if shape(body(unit.function("refresh_root_snapshot"))) != expected:
        raise ContractError("publish a complete root snapshot before freeing its predecessor")
    clear = ("CompoundStmt", call("sn_caches_begin", field("caches", "runner")),
        ("DeclStmt", ("var", "previous", field("root_snapshot", "runner"))),
        ("=", field("root_snapshot", "runner"), ZERO), call("sn_root_snapshot_free", ref("previous")))
    if shape(body(unit.function("clear_native_caches"))) != clear:
        raise ContractError("clear caches before releasing their root snapshot")
    statements = body(unit.function("evaluate_native"))["inner"]
    restore = ("=", ref("active_caches"), ref("previous_caches"))
    position = next((i for i, node in enumerate(statements) if shape(node) == restore), -1)
    refresh = ("IfStmt", ("==", field("status", "call"), ref("SN_VERDICT_UNSUPPORTED")),
               call("refresh_root_snapshot", ref("r")))
    if position < 0 or [shape(n) for n in statements[position + 1:position + 3]] != [refresh, call("publish_scope", ref("r"))]:
        raise ContractError("suspended native passes must snapshot roots before Ruby publication/callbacks")
    # The clear/refresh entrypoints must not acquire new callers casually.
    for name, node in unit.functions.items():
        for target, _ in calls(node):
            if target == "sn_caches_snapshot" and name != "refresh_root_snapshot":
                raise ContractError("capture cache roots only between native passes")
            if target == "sn_caches_begin" and name != "clear_native_caches":
                raise ContractError("cache clearing must release the root snapshot")
            if target == "refresh_root_snapshot" and name != "evaluate_native":
                raise ContractError("root snapshots may only be replaced between native passes")
            if target == "clear_native_caches" and name not in {"close_callback_scope", "clear_runtime"}:
                raise ContractError("cache roots may only be cleared by invocation cleanup")
        for assignment in children(node, "BinaryOperator"):
            if assignment.get("opcode") == "=" and unwrap(assignment["inner"][0]).get("kind") == "MemberExpr":
                if unwrap(assignment["inner"][0]).get("name") == "root_snapshot" and name not in {
                    "refresh_root_snapshot", "clear_native_caches", "prepare_runner"}:
                    raise ContractError("root snapshot ownership may not be overwritten outside its lifecycle helpers")
    for target, owners in {
        "sn_caches_snapshot": {"refresh_root_snapshot"},
        "refresh_root_snapshot": {"evaluate_native"},
        "sn_caches_begin": {"clear_native_caches"},
        "clear_native_caches": {"clear_runtime", "close_callback_scope"},
        "sn_root_snapshot_free": {"refresh_root_snapshot", "clear_native_caches", "runner_release"},
    }.items():
        callers = {name for name, node in unit.functions.items() if target in function_references(node)}
        if callers != owners:
            raise ContractError(f"{target}: preserve all audited snapshot lifecycle callers")
    release_calls = list(calls(unit.function("runner_release")))
    released = [args for name, args in release_calls if name == "sn_root_snapshot_free"]
    if len(released) != 1 or [shape(arg) for arg in released[0]] != [field("root_snapshot", "h")]:
        raise ContractError("runner destruction must release its root snapshot exactly once")
    size_rule = ("IfStmt", field("root_snapshot", "h"),
                 ("+=", ref("bytes"), call("sn_root_snapshot_size", field("root_snapshot", "h"))))
    if size_rule not in [shape(node) for node in body(unit.function("runner_size"))["inner"]]:
        raise ContractError("runner memory size must include its root snapshot")


def check_runtime_location_roots(unit):
    record = unit.records[unit.aliases["runtime_locations"]]
    fields = [item for item in record["inner"] if item.get("kind") == "FieldDecl"]
    if any(item["type"]["qualType"] != "VALUE" for item in fields):
        raise ContractError("runtime-location root fields must remain VALUE handles")
    expected = [call("rb_ary_push", ref("roots"), field(item["name"], "locations")) for item in fields]
    actual = [call(name, *(shape(arg) for arg in args))
              for name, args in calls(unit.function("root_runtime_locations")) if name == "rb_ary_push"]
    if actual != expected:
        raise ContractError("all runtime-location handles must be rooted independently of their buffer")


def check_construction_guard(unit):
    registration = unit.variables.get("construction_guard_type")
    initializer = [node for node in (registration or {}).get("inner", []) if node.get("kind") == "InitListExpr"]
    expected = ("InitListExpr", ("StringLiteral", '\"Schemurai::Native::ProgramConstruction\"'),
                ("InitListExpr", ZERO, ZERO, ZERO, ZERO, ("InitListExpr", ZERO)),
                ZERO, ZERO, ref("RUBY_TYPED_FREE_IMMEDIATELY"))
    if len(initializer) != 1 or shape(initializer[0]) != expected:
        raise ContractError("the Program construction guard must remain intrinsically unshareable")
    allocation = body(unit.function("allocate"))["inner"]
    create = ("DeclStmt", ("var", "guard", call("rb_data_typed_object_wrap", ref("rb_cObject"),
                                                ZERO, ("&", ref("construction_guard_type")))))
    retain = ("=", field("construction_guard", "h"), ref("guard"))
    if shape(allocation[0]) != create or retain not in [shape(node) for node in allocation]:
        raise ContractError("allocate must retain an unshareable guard before Program construction")
    initialization = body(unit.function("initialize"))["inner"]
    if [shape(node) for node in initialization[-2:]] != [
        ("=", field("construction_guard", "h"), ref("RUBY_Qnil")), ("ReturnStmt", ref("self"))]:
        raise ContractError("publish Program readiness only after successful compilation")
    failure = shape(initialization[-3])
    if failure[:2] != ("IfStmt", ("!=", ref("status"), ref("SN_VERDICT_VALID"))):
        raise ContractError("compile failures must not remove the construction guard")
    failure_body = initialization[-3].get("inner", [])[-1]
    if not failure_body.get("inner") or reference(unwrap(failure_body["inner"][-1])["inner"][0]) != "rb_raise":
        raise ContractError("failed compilation must raise before Program publication")
    writes = []
    for name, node in unit.functions.items():
        for assignment in children(node, "BinaryOperator"):
            if assignment.get("opcode") == "=" and unwrap(assignment["inner"][0]).get("kind") == "MemberExpr":
                if unwrap(assignment["inner"][0]).get("name") == "construction_guard":
                    writes.append(name)
    if sorted(writes) != ["allocate", "initialize"]:
        raise ContractError("construction guards must be retained once and cleared once after successful compilation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ruby", default=os.environ.get("RUBY", "ruby"))
    parser.add_argument("--clang", default=os.environ.get("CLANG", "clang"))
    parser.add_argument("--define", action="append", default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    unit = compile_ast(root / "ext/schemurai_native/glue.c", args.ruby, args.clang, args.define)
    imports = rust_imports((root / "ext/schemurai_native/src/ruby.rs").read_text())
    reachable = check_effects(unit, imports)
    check_barrier(unit)
    check_roots(unit)
    check_publication(unit)
    check_globals(unit)
    check_result_roots(unit)
    check_snapshot_protocol(unit)
    check_runtime_location_roots(unit)
    check_construction_guard(unit)
    print(f"native C boundary: {len(imports)} imports, {len(reachable)} non-allocating functions checked")


if __name__ == "__main__":
    try:
        main()
    except (ContractError, subprocess.CalledProcessError, OSError) as error:
        raise SystemExit(str(error)) from None
