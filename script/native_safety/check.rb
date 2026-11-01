# frozen_string_literal: true

# Clang-based checks for the native extension's trusted C boundary.
# No source snippets are evaluated. Calls and field accesses come from Clang's
# expanded, typed AST, including calls introduced by Ruby header macros.
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tempfile"

module NativeSafety
  extend self

  class ContractError < StandardError; end

  def walk(node, &block)
    return enum_for(__method__, node) unless block

    yield node
    node.fetch("inner", []).each { |child| walk(child, &block) }
  end

  def children(node, kind)
    walk(node).select { |item| item["kind"] == kind }
  end

  # Resolve a callee/argument through casts, without descending into calls.
  def reference(node)
    return node.dig("referencedDecl", "name") if node["kind"] == "DeclRefExpr"

    if %w[ImplicitCastExpr CStyleCastExpr ParenExpr UnaryOperator].include?(node["kind"])
      inner = node.fetch("inner", [])
      return reference(inner[0]) if inner.length == 1
    end
    nil
  end

  def calls(node)
    children(node, "CallExpr").map do |expression|
      inner = expression.fetch("inner", [])
      [inner.empty? ? nil : reference(inner[0]), inner.drop(1)]
    end
  end

  def function_references(node)
    children(node, "DeclRefExpr").filter_map do |item|
      item.dig("referencedDecl", "name") if item.dig("referencedDecl", "kind") == "FunctionDecl"
    end.to_set
  end

  # Consume Clang's top-level declaration framing without reparsing prefixes.
  # JSON strings cannot contain literal newlines, so the four-space top-level
  # terminator cannot match a string value. Unexpected framing fails closed.
  def ast_nodes(stream)
    return enum_for(__method__, stream) unless block_given?

    loop do
      line = stream.gets
      raise ContractError, "Clang did not produce a translation-unit AST" unless line
      break if line == "  \"inner\": [\n"
    end
    lines = []
    skip = false
    while (line = stream.gets)
      if line == "  ]\n"
        raise ContractError, "invalid Clang AST trailer" unless lines.empty? && stream.read.strip == "}"

        return
      end
      if lines.empty? && line != "    {\n"
        raise ContractError, "unrecognized Clang declaration framing"
      end
      # rb_define_method expansions make Init enormous. It is not an adapter
      # or a callable leaf. Any attempt to reach it fails as an unknown call.
      skip = true if line == "      \"name\": \"Init_schemurai_native\",\n"
      lines << (skip ? "" : line)
      next unless ["    },\n", "    }\n"].include?(line)

      yield JSON.parse(lines.join.sub(/[\n,]+\z/, ""), max_nesting: false) unless skip
      lines = []
      skip = false
    end
    raise ContractError, "truncated Clang AST"
  end

  class TranslationUnit
    attr_reader :functions, :records, :aliases, :variables

    def initialize(nodes)
      @functions = {}
      @records = {}
      @aliases = {}
      @variables = {}
      nodes.each do |node|
        # Clang elides repeated file names. Main-file declarations have no
        # includedFrom entry, so comparing loc.file alone loses declarations.
        next if node.fetch("loc", {}).key?("includedFrom")

        case node["kind"]
        when "FunctionDecl"
          @functions[node["name"]] = node if node.fetch("inner", []).any? { |child| child["kind"] == "CompoundStmt" }
        when "RecordDecl"
          @records[node["id"]] = node if node["completeDefinition"]
        when "TypedefDecl"
          tag = NativeSafety.walk(node).find { |part| part.key?("ownedTagDecl") }
          @aliases[node["name"]] = tag["ownedTagDecl"]["id"] if tag
        when "VarDecl"
          @variables[node["name"]] = node
        end
      end
    end

    def function(name)
      @functions.fetch(name) { raise ContractError, "missing C function definition: #{name}" }
    end
  end

  def parse_c(source, clang, includes = [], defines = [])
    command = [clang, "-fsyntax-only", "-Xclang", "-ast-dump=json"]
    command.concat(includes.map { |directory| "-I#{directory}" })
    command.concat(defines.map { |definition| "-D#{definition}" })
    command << source.to_s
    Tempfile.create(["schemurai-c-ast-", ".json"]) do |output|
      raise ContractError, "Clang AST compilation failed" unless system(*command, out: output)

      output.rewind
      TranslationUnit.new(ast_nodes(output))
    end
  end

  def compile_ast(source, ruby, clang, defines)
    config, status = Open3.capture2(ruby, "-rrbconfig", "-rjson", "-e",
      'puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir", "rubyarchhdrdir"))')
    raise ContractError, "Ruby header configuration failed" unless status.success?

    parse_c(source, clang, JSON.parse(config), defines)
  end

  def rust_imports(source)
    # Foreign declarations have a constrained spelling in ruby.rs; the syn
    # check separately prohibits other declaration sites and macros.
    source = source.gsub(%r{//[^\n]*|/\*.*?\*/}m, "")
    blocks = source.scan(/unsafe\s+extern\s+"C"\s*\{([^{}]*)\}/).flatten
    names = blocks.flat_map { |block| block.scan(/\bfn\s+(sn_\w+)\s*\(/).flatten }.to_set
    raise ContractError, "missing Rust foreign adapter declarations" if names.empty?

    names
  end

  def protected_adapters
    result = {}
    File.foreach(File.expand_path("../../ext/schemurai_native/protected.def", __dir__), chomp: true) do |line|
      match = /\ASN_PROTECTED\((sn_\w+), (\w+)\)\z/.match(line)
      raise ContractError, "invalid or duplicate protected adapter contract" unless match && !result.key?(match[1])

      result[match[1]] = match[2]
    end
    raise ContractError, "empty protected adapter contract" if result.empty?

    result
  end

  PROTECTED = protected_adapters.freeze

  # Exact external API leaves. Preconditions are documented alongside adapters
  # in glue.c; this is an audited trust boundary, not an allocation heuristic.
  PURE_EXTERNAL = Set.new(%w[
    RB_ENCODING_GET RB_ENC_CODERANGE rb_array_const_ptr rb_array_len
    rb_ary_entry rb_class_of rb_float_value rb_hash_size_num rb_type
    rb_integer_type_p rbimpl_RB_TYPE_P_fastpath rb_ivar_get rb_sym2id
    rb_fix2int rb_fix2long rb_big_sign rb_absint_size rb_absint_numwords
    rb_integer_pack rb_str_cmp rb_str_strlen rb_debug_rstring_null_ptr
    rb_hash_foreach rb_hash_stlike_foreach rb_hash_lookup2 rb_st_lookup
    rb_big_cmp rb_big_eql rb_hash
    __builtin_constant_p __builtin_expect __builtin_isfinite trunc
  ]).freeze
  # Hash reads require ordinary-string keys/identity tables; callbacks are
  # traversed below. Bignum reads require existing digits, without coercion.
  RUST_CALLBACKS = Set.new(%w[sn_identity_kind sn_reference_pair sn_object_entry]).freeze

  def check_effects(unit, imports)
    unknown = Set.new
    reachable = Set.new
    pending = (imports - PROTECTED.keys.to_set - Set["sn_pin"]).to_a
    until pending.empty?
      name = pending.pop
      next unless reachable.add?(name)
      next if RUST_CALLBACKS.include?(name)

      unless unit.functions.key?(name)
        unknown.add(name)
        next
      end
      node = unit.functions[name]
      children(node, "CallExpr").each do |expression|
        callee = unwrap(expression["inner"][0])
        next if callee["kind"] == "DeclRefExpr" && callee.dig("referencedDecl", "kind") == "FunctionDecl"

        callback_type = {"hash_visit" => "hash_callback", "key_view_visit" => "key_view_callback"}[name]
        unless callback_type && callee["kind"] == "MemberExpr" && callee["name"] == "callback" && callee.dig("type", "qualType") == callback_type
          raise ContractError, "unreviewed indirect call in non-allocating adapter: #{name}"
        end
      end
      function_references(node).each do |target|
        if unit.functions.key?(target) || RUST_CALLBACKS.include?(target)
          pending << target
        elsif !PURE_EXTERNAL.include?(target)
          unknown.add(target)
        end
      end
    end
    unless unknown.empty?
      raise ContractError, "unreviewed calls reachable from non-allocating adapters: #{unknown.sort.join(", ")}"
    end
    PROTECTED.each do |name, callback|
      direct = calls(unit.function(name))
      unless direct.length == 1 && direct[0][0] == "protected_result" && reference(direct[0][1][0]) == callback
        raise ContractError, "#{name} must call only protected_result with #{callback}"
      end
    end
    pin = calls(unit.function("sn_pin"))
    raise ContractError, "sn_pin must pin handles using rb_gc_mark" unless pin.length == 1 && pin[0][0] == "rb_gc_mark"

    reachable
  end

  def unwrap(node)
    while %w[ImplicitCastExpr CStyleCastExpr ParenExpr ConstantExpr].include?(node["kind"])
      inner = node.fetch("inner", [])
      break unless inner.length == 1

      node = inner[0]
    end
    node
  end

  # Control/data shape independent of addresses, paths, casts and formatting.
  def shape(node)
    node = unwrap(node)
    kind = node.fetch("kind", "empty")
    inner = node.fetch("inner", []).map { |child| shape(child) }
    case kind
    when "DeclRefExpr" then ["ref", node["referencedDecl"]["name"]]
    when "MemberExpr" then ["field", node["name"], *inner]
    when "IntegerLiteral", "StringLiteral" then [kind, node["value"]]
    when "CallExpr" then ["call", *inner]
    when "UnaryOperator", "BinaryOperator", "CompoundAssignOperator" then [node["opcode"], *inner]
    when "VarDecl" then ["var", node["name"], *inner]
    else [kind, *inner]
    end
  end

  def body(node)
    node.fetch("inner", []).find { |child| child["kind"] == "CompoundStmt" }
  end

  def ref(name)
    ["ref", name]
  end

  def field(name, owner)
    ["field", name, ref(owner)]
  end

  def call(name, *arguments)
    ["call", ref(name), *arguments]
  end

  ZERO = ["IntegerLiteral", "0"].freeze

  def check_barrier(unit)
    expected = ["CompoundStmt",
      ["DeclStmt", ["var", "state", ZERO]],
      ["=", ["*", ref("result")], call("rb_protect", ref("callback"), ref("argument"), ["&", ref("state")])],
      ["IfStmt", ref("state"), ["CompoundStmt",
        ["=", ["*", ref("result")], call("rb_errinfo")],
        call("rb_set_errinfo", ref("RUBY_Qnil"))]],
      ["ReturnStmt", ref("state")]]
    unless shape(body(unit.function("protected_result"))) == expected
      raise ContractError, "protected_result must capture and clear Ruby exceptions before returning status"
    end
  end

  HOLDERS = {
    # record: [TypedData, mark, free, size, borrowed pointers, Rust roots]
    "holder" => ["engine_type", "mark", "release", "size", Set["engine"], {"roots" => "sn_roots_mark"}],
    "runner_holder" => ["runner_type", "runner_mark", "runner_release", "runner_size",
      Set["frame_indices"], {"caches" => "sn_caches_mark", "root_snapshot" => "sn_root_snapshot_mark"}],
    "report_holder" => ["report_type", "report_mark", "report_release", "report_size", Set.new, {"report" => "sn_report_mark"}],
    "report_collector" => ["report_collector_type", "report_collector_mark", "report_collector_free", "report_collector_size",
      Set.new, {"report" => "sn_report_mark"}],
    "property_locations_holder" => ["property_locations_type", "property_locations_mark", "property_locations_free", "property_locations_size",
      Set.new, {"locations" => "sn_property_locations_mark"}]
  }.freeze

  def native_type(unit, spelling, seen = Set.new)
    return false if spelling == "VALUE"
    return true if ["int", "size_t", "uint32_t", "double", "unsigned long", "unsigned int"].include?(spelling)

    if unit.aliases.key?(spelling) && !seen.include?(spelling)
      record = unit.records[unit.aliases[spelling]]
      if record
        return record.fetch("inner", []).select { |item| item["kind"] == "FieldDecl" }.all? do |item|
          native_type(unit, item["type"]["qualType"], seen | Set[spelling])
        end
      end
    end
    false
  end

  def check_holder(unit, name, spec)
    data_type, marker, releaser, sizer, borrowed, rust_roots = spec
    unless unit.aliases.key?(name) && unit.records.key?(unit.aliases[name])
      raise ContractError, "missing TypedData holder: #{name}"
    end
    record = unit.records[unit.aliases[name]]
    fields = record.fetch("inner", []).select { |part| part["kind"] == "FieldDecl" }.to_h { |part| [part["name"], part] }
    values = fields.select { |_, part| part["type"]["qualType"] == "VALUE" }.keys.to_set
    # The collector's self-edge is not an independent root. All other VALUE
    # fields must be pinned unconditionally.
    self_edge = (name == "report_collector") ? Set["self"] : Set.new
    table = (name == "runner_holder") ? Set["matches"] : Set.new
    classified = values | borrowed | rust_roots.keys.to_set | table
    fields.each do |key, part|
      unless classified.include?(key) || native_type(unit, part["type"]["qualType"])
        raise ContractError, "unclassified native/Ruby storage: #{name}.#{key}"
      end
    end
    statements = body(unit.function(marker))["inner"]
    if statements.empty? || statements[0]["kind"] != "DeclStmt"
      raise ContractError, "#{marker} must bind its own TypedData pointer"
    end
    declaration = statements[0].fetch("inner", [])
    unless declaration.length == 1 && declaration[0]["kind"] == "VarDecl"
      raise ContractError, "#{marker}: unsupported holder binding"
    end
    holder_alias = declaration[0]["name"]
    parameters = unit.function(marker)["inner"].select { |part| part["kind"] == "ParmVarDecl" }.map { |part| part["name"] }
    unless parameters.length == 1 && shape(declaration[0]) == ["var", holder_alias, ref(parameters[0])]
      raise ContractError, "#{marker} must mark the callback's holder"
    end
    expected = (values - self_edge).map { |key| call("rb_gc_mark", field(key, holder_alias)) }.to_set
    rust_roots.each do |key, target|
      raise ContractError, "missing Rust root storage: #{name}.#{key}" unless fields.key?(key)

      condition = field(key, holder_alias)
      condition = ["&&", condition, ["!", field("busy", holder_alias)]] if name == "report_collector"
      expected.add(["IfStmt", condition, call(target, field(key, holder_alias))])
    end
    unless table.empty?
      expected.add(["IfStmt", field("matches", holder_alias),
        call("rb_st_foreach", field("matches", holder_alias), ref("mark_operation"), ZERO)])
    end
    actual = statements.drop(1).map { |statement| shape(statement) }
    unless actual.length == expected.length && actual.to_set == expected
      raise ContractError, "#{marker} must pin every VALUE and visit each Rust/table root with its audited guard"
    end
    variable = unit.variables[data_type]
    raise ContractError, "missing TypedData registration: #{data_type}" unless variable

    initializers = variable.fetch("inner", []).select { |item| item["kind"] == "InitListExpr" }
    unless initializers.length == 1 && initializers[0].fetch("inner", []).length == 5
      raise ContractError, "unsupported TypedData initializer: #{data_type}"
    end
    parts = initializers[0]["inner"]
    callbacks = Set[marker, releaser, sizer]
    unless function_references(parts[1]) == callbacks && function_references(variable) == callbacks
      raise ContractError, "#{data_type} must install its audited mark/free/size callbacks"
    end
    flag = ref("RUBY_TYPED_FREE_IMMEDIATELY")
    flag = ["|", flag, ref("RUBY_TYPED_FROZEN_SHAREABLE")] if name == "holder"
    raise ContractError, "#{data_type}: only frozen Programs may be Ractor-shareable" unless shape(parts[-1]) == flag
  end

  def check_roots(unit)
    registrations = unit.variables.select { |_, node| node.dig("type", "qualType").to_s.include?("rb_data_type_t") }.keys.to_set
    expected = HOLDERS.values.map(&:first).to_set | Set["construction_guard_type"]
    raise ContractError, "every TypedData registration requires an ownership contract" unless registrations == expected

    HOLDERS.each { |name, spec| check_holder(unit, name, spec) }
    # ST tables carry Ruby keys at two levels; the outer operation key and all
    # values are native scalars or child ST tables.
    {
      "mark_match" => ["CompoundStmt", call("rb_gc_mark", ref("key")), ["ReturnStmt", ref("ST_CONTINUE")]],
      "mark_pattern_matches" => ["CompoundStmt", call("rb_gc_mark", ref("key")),
        call("rb_st_foreach", ref("value"), ref("mark_match"), ZERO), ["ReturnStmt", ref("ST_CONTINUE")]],
      "mark_operation" => ["CompoundStmt", call("rb_st_foreach", ref("value"), ref("mark_pattern_matches"), ZERO), ["ReturnStmt", ref("ST_CONTINUE")]]
    }.each do |name, rule|
      raise ContractError, "#{name}: ST table Ruby keys must remain pinned" unless shape(body(unit.function(name))) == rule
    end
  end

  def check_publication(unit)
    expected = ["CompoundStmt",
      ["DeclStmt", ["var", "h", call("ready_program", ref("self"))]],
      ["DeclStmt", ["var", "count", call("sn_root_count", field("roots", "h"))]],
      ["ForStmt", ["DeclStmt", ["var", "i", ZERO]], ["empty"],
        ["<", ref("i"), ref("count")], ["++", ref("i")],
        call("rb_ractor_make_shareable", call("sn_root_at", field("roots", "h"), ref("i")))],
      call("rb_ractor_make_shareable", field("program", "h")),
      ["ReturnStmt", call("rb_ractor_make_shareable", ref("self"))]]
    unless shape(body(unit.function("make_shareable"))) == expected
      raise ContractError, "publish only a ready Program after making all hidden roots shareable"
    end
    statements = body(unit.function("ready_program"))["inner"]
    raise ContractError, "ready_program must reject uninitialized/compiling programs" unless statements.length == 5

    unless shape(statements[0]) == ["DeclStmt", ["var", "h"]] && shape(statements[-1]) == ["ReturnStmt", ref("h")]
      raise ContractError, "ready_program must return its own checked holder"
    end
    binding = shape(statements[1])
    allowed_bindings = %w[rb_check_typeddata rbimpl_check_typeddata].map do |target|
      ["=", ref("h"), call(target, ref("self"), ["&", ref("engine_type")])]
    end
    raise ContractError, "ready_program must check the Program TypedData type" unless allowed_bindings.include?(binding)

    guards = statements[2, 2].map { |statement| shape(statement) }
    guards.zip([["!", field("engine", "h")], field("compiling", "h")]).each do |guard, condition|
      unless guard.length == 3 && guard[0] == "IfStmt" && guard[1] == condition && guard[2].take(2) == ["call", ref("rb_raise")]
        raise ContractError, "ready_program must reject uninitialized/compiling programs"
      end
    end
  end

  GLOBAL_IDS = Set.new(%w[
    id_resolve id_schemurai id_resolution_error id_root id_compile id_graph
    id_dynamic_anchor id_dynamic_anchor_names id_dynamic_anchor_count
  ]).freeze

  def check_globals(unit)
    types = GLOBAL_IDS.to_h { |name| [name, "ID"] }
    types.merge!(%w[utf8_index ascii_index binary_index].to_h { |name| [name, "int"] })
    types.merge!("identity_methods" => "ID[5]", "active_caches" => "const void *")
    types.merge!(HOLDERS.values.to_h { |spec| [spec[0], "const rb_data_type_t"] })
    types["construction_guard_type"] = "const rb_data_type_t"
    unless unit.variables.keys.to_set == types.keys.to_set | Set["fields", "opcodes"]
      raise ContractError, "new C global storage requires a Ractor/GC ownership contract"
    end
    types.each do |name, spelling|
      node = unit.variables[name]
      unless node["storageClass"] == "static" && node.dig("type", "qualType") == spelling
        raise ContractError, "global #{name} must remain native metadata or borrowed runtime state"
      end
      if (name == "active_caches") != !node["tls"].nil?
        raise ContractError, "only the borrowed active_caches pointer may use C thread-local storage"
      end
    end
    {"fields" => {"id" => "ID", "symbol" => "const char *"},
     "opcodes" => {"id" => "ID", "symbol" => "const char *", "opcode" => "int"}}.each do |name, expected|
      spelling = unit.variables[name]["type"]["qualType"]
      match = / at .*:(\d+):(\d+)\)\[\d+\]\z/.match(spelling)
      raise ContractError, "unsupported native metadata table: #{name}" unless match

      record = unit.records.values.find do |item|
        item.dig("loc", "line") == match[1].to_i && item.dig("loc", "col") == match[2].to_i
      end
      actual = (record || {}).fetch("inner", []).select { |item| item["kind"] == "FieldDecl" }.to_h do |item|
        [item["name"], item["type"]["qualType"]]
      end
      raise ContractError, "global metadata table #{name} must not retain Ruby objects" unless actual == expected
    end
  end

  PUBLICATIONS = {
    "sn_message_result" => [Set["evaluate_runtime"], "messages"],
    "sn_pointer_result" => [Set["evaluate_runtime"], "pointers"],
    "sn_properties_result" => [Set["merge_runtime_properties"], "report_results"],
    "sn_report_accept" => [Set["container_report_runtime", "call_runtime"], "report_results"]
  }.freeze

  # Require a root write immediately before publication into Rust caches. These
  # are structural rules for the driver protocol, not a search for earlier roots.
  def check_result_roots(unit)
    found = PUBLICATIONS.to_h { |name, _| [name, Set.new] }
    reviewed = Set.new
    all_publications = unit.functions.values.flat_map do |node|
      children(node, "CallExpr").filter_map { |item| item["id"] if PUBLICATIONS.key?(reference(item["inner"][0])) }
    end.to_set
    unit.functions.each do |function, node|
      children(node, "CompoundStmt").each do |compound|
        statements = compound.fetch("inner", [])
        statements.each_with_index do |statement, index|
          # Nested blocks are visited independently, retaining dominance.
          next if %w[IfStmt ForStmt WhileStmt CompoundStmt].include?(statement["kind"])

          calls(statement).each do |target, arguments|
            next unless PUBLICATIONS.key?(target)

            owners, root = PUBLICATIONS[target]
            unless owners.include?(function)
              raise ContractError, "#{target}: new publication site needs an ownership contract"
            end
            found[target].add(function)
            reviewed.merge(children(statement, "CallExpr").filter_map do |item|
              item["id"] if reference(item["inner"][0]) == target
            end)
            offset = (target == "sn_report_accept") ? 3 : 1
            root_write = if target == "sn_properties_result"
              call("root_runtime_locations", field(root, "r"), ["&", ref("locations")])
            else
              call("rb_ary_push", field(root, "r"), ref("result"))
            end
            if index < offset || shape(statements[index - offset]) != root_write
              raise ContractError, "#{target}: C must root the completed result before publishing it to Rust"
            end
            if target == "sn_report_accept"
              # The rooted result owns completed->report.
              unless shape(statements[index - 2]) == ["DeclStmt", ["var", "completed"]]
                raise ContractError, "report publication must extract the rooted TypedData owner"
              end
              assignment = shape(statements[index - 1])
              allowed = %w[rb_check_typeddata rbimpl_check_typeddata].map do |helper|
                ["=", ref("completed"), call(helper, ref("result"), ["&", ref("report_type")])]
              end
              unless allowed.include?(assignment) && shape(arguments[1]) == field("report", "completed")
                raise ContractError, "report publication must extract the rooted TypedData owner"
              end
            elsif target == "sn_properties_result"
              # All copied handles are rooted by root_runtime_locations.
              origins = statements.take(index - 1).map { |item| shape(item) }
              expected = ["DeclStmt", ["var", "locations", call("read_runtime_locations", ref("result"))]]
              unless origins.include?(expected) && shape(arguments[1]) == ["&", ref("locations")]
                raise ContractError, "property locations must belong to the rooted result buffer"
              end
            elsif shape(arguments[1]) != ref("result")
              raise ContractError, "#{target}: published handle must be the rooted result"
            end
          end
        end
      end
    end
    raise ContractError, "every result publication must have a dominating C root write" unless reviewed == all_publications

    PUBLICATIONS.each do |target, (owners, _)|
      raise ContractError, "missing reviewed publication site: #{target}" unless found[target] == owners
    end
  end

  def check_snapshot_protocol(unit)
    # Never discard a snapshot before publishing its complete replacement.
    expected = ["CompoundStmt",
      ["DeclStmt", ["var", "next", call("sn_caches_snapshot", field("caches", "runner"))]],
      ["IfStmt", ["!", ref("next")], call("rb_raise", ref("rb_eRuntimeError"),
        ["StringLiteral", '"native root snapshot has an active borrow"'])],
      ["DeclStmt", ["var", "previous", field("root_snapshot", "runner")]],
      ["=", field("root_snapshot", "runner"), ref("next")],
      call("sn_root_snapshot_free", ref("previous"))]
    unless shape(body(unit.function("refresh_root_snapshot"))) == expected
      raise ContractError, "publish a complete root snapshot before freeing its predecessor"
    end
    clear = ["CompoundStmt", call("sn_caches_begin", field("caches", "runner")),
      ["DeclStmt", ["var", "previous", field("root_snapshot", "runner")]],
      ["=", field("root_snapshot", "runner"), ZERO], call("sn_root_snapshot_free", ref("previous"))]
    unless shape(body(unit.function("clear_native_caches"))) == clear
      raise ContractError, "clear caches before releasing their root snapshot"
    end
    statements = body(unit.function("evaluate_native"))["inner"]
    restore = ["=", ref("active_caches"), ref("previous_caches")]
    position = statements.index { |node| shape(node) == restore }
    refresh = ["IfStmt", ["==", field("status", "call"), ref("SN_VERDICT_UNSUPPORTED")],
      call("refresh_root_snapshot", ref("r"))]
    unless position && statements[position + 1, 2].map { |node| shape(node) } == [refresh, call("publish_scope", ref("r"))]
      raise ContractError, "suspended native passes must snapshot roots before Ruby publication/callbacks"
    end
    # Clear/refresh entrypoints must not acquire new callers casually.
    unit.functions.each do |name, node|
      calls(node).each do |target, _|
        if target == "sn_caches_snapshot" && name != "refresh_root_snapshot"
          raise ContractError, "capture cache roots only between native passes"
        end
        if target == "sn_caches_begin" && name != "clear_native_caches"
          raise ContractError, "cache clearing must release the root snapshot"
        end
        if target == "refresh_root_snapshot" && name != "evaluate_native"
          raise ContractError, "root snapshots may only be replaced between native passes"
        end
        if target == "clear_native_caches" && !%w[close_callback_scope clear_runtime].include?(name)
          raise ContractError, "cache roots may only be cleared by invocation cleanup"
        end
      end
      children(node, "BinaryOperator").each do |assignment|
        next unless assignment["opcode"] == "="

        left = unwrap(assignment["inner"][0])
        if left["kind"] == "MemberExpr" && left["name"] == "root_snapshot" && !%w[refresh_root_snapshot clear_native_caches prepare_runner].include?(name)
          raise ContractError, "root snapshot ownership may not be overwritten outside its lifecycle helpers"
        end
      end
    end
    {
      "sn_caches_snapshot" => Set["refresh_root_snapshot"],
      "refresh_root_snapshot" => Set["evaluate_native"],
      "sn_caches_begin" => Set["clear_native_caches"],
      "clear_native_caches" => Set["clear_runtime", "close_callback_scope"],
      "sn_root_snapshot_free" => Set["refresh_root_snapshot", "clear_native_caches", "runner_release"]
    }.each do |target, owners|
      callers = unit.functions.select { |_, node| function_references(node).include?(target) }.keys.to_set
      raise ContractError, "#{target}: preserve all audited snapshot lifecycle callers" unless callers == owners
    end
    released = calls(unit.function("runner_release")).filter_map { |name, args| args if name == "sn_root_snapshot_free" }
    unless released.length == 1 && released[0].map { |arg| shape(arg) } == [field("root_snapshot", "h")]
      raise ContractError, "runner destruction must release its root snapshot exactly once"
    end
    size_rule = ["IfStmt", field("root_snapshot", "h"),
      ["+=", ref("bytes"), call("sn_root_snapshot_size", field("root_snapshot", "h"))]]
    unless body(unit.function("runner_size"))["inner"].map { |node| shape(node) }.include?(size_rule)
      raise ContractError, "runner memory size must include its root snapshot"
    end
  end

  def check_runtime_location_roots(unit)
    record = unit.records[unit.aliases["runtime_locations"]]
    fields = record["inner"].select { |item| item["kind"] == "FieldDecl" }
    if fields.any? { |item| item["type"]["qualType"] != "VALUE" }
      raise ContractError, "runtime-location root fields must remain VALUE handles"
    end
    expected = fields.map { |item| call("rb_ary_push", ref("roots"), field(item["name"], "locations")) }
    actual = calls(unit.function("root_runtime_locations")).filter_map do |name, args|
      call(name, *args.map { |arg| shape(arg) }) if name == "rb_ary_push"
    end
    unless actual == expected
      raise ContractError, "all runtime-location handles must be rooted independently of their buffer"
    end
  end

  def check_construction_guard(unit)
    registration = unit.variables["construction_guard_type"]
    initializer = (registration || {}).fetch("inner", []).select { |node| node["kind"] == "InitListExpr" }
    expected = ["InitListExpr", ["StringLiteral", '"Schemurai::Native::ProgramConstruction"'],
      ["InitListExpr", ZERO, ZERO, ZERO, ZERO, ["InitListExpr", ZERO]],
      ZERO, ZERO, ref("RUBY_TYPED_FREE_IMMEDIATELY")]
    unless initializer.length == 1 && shape(initializer[0]) == expected
      raise ContractError, "the Program construction guard must remain intrinsically unshareable"
    end
    allocation = body(unit.function("allocate"))["inner"]
    create = ["DeclStmt", ["var", "guard", call("rb_data_typed_object_wrap", ref("rb_cObject"),
      ZERO, ["&", ref("construction_guard_type")])]]
    retain = ["=", field("construction_guard", "h"), ref("guard")]
    unless shape(allocation[0]) == create && allocation.map { |node| shape(node) }.include?(retain)
      raise ContractError, "allocate must retain an unshareable guard before Program construction"
    end
    initialization = body(unit.function("initialize"))["inner"]
    unless initialization.last(2).map { |node| shape(node) } == [
      ["=", field("construction_guard", "h"), ref("RUBY_Qnil")], ["ReturnStmt", ref("self")]
    ]
      raise ContractError, "publish Program readiness only after successful compilation"
    end
    failure = shape(initialization[-3])
    unless failure.take(2) == ["IfStmt", ["!=", ref("status"), ref("SN_VERDICT_VALID")]]
      raise ContractError, "compile failures must not remove the construction guard"
    end
    failure_body = initialization[-3].fetch("inner", [])[-1]
    if failure_body.fetch("inner", []).empty? || reference(unwrap(failure_body["inner"][-1])["inner"][0]) != "rb_raise"
      raise ContractError, "failed compilation must raise before Program publication"
    end
    writes = []
    unit.functions.each do |name, node|
      children(node, "BinaryOperator").each do |assignment|
        next unless assignment["opcode"] == "="

        left = unwrap(assignment["inner"][0])
        writes << name if left["kind"] == "MemberExpr" && left["name"] == "construction_guard"
      end
    end
    unless writes.sort == %w[allocate initialize]
      raise ContractError, "construction guards must be retained once and cleared once after successful compilation"
    end
  end

  def main(argv = ARGV)
    ruby = ENV.fetch("RUBY", RbConfig.ruby)
    clang = ENV.fetch("CLANG", "clang")
    defines = []
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby script/native_safety/check.rb [options]\nCheck the native extension's trusted C boundary using Clang's typed AST."
      parser.on("--ruby RUBY", "Ruby used to build the extension") { |value| ruby = value }
      parser.on("--clang CLANG", "Clang executable") { |value| clang = value }
      parser.on("--define DEFINE", "C preprocessor definition (repeatable)") { |value| defines << value }
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?
    end
    root = File.expand_path("../..", __dir__)
    unit = compile_ast(File.join(root, "ext/schemurai_native/glue.c"), ruby, clang, defines)
    imports = rust_imports(File.read(File.join(root, "ext/schemurai_native/src/ruby.rs")))
    reachable = check_effects(unit, imports)
    check_barrier(unit)
    check_roots(unit)
    check_publication(unit)
    check_globals(unit)
    check_result_roots(unit)
    check_snapshot_protocol(unit)
    check_runtime_location_roots(unit)
    check_construction_guard(unit)
    puts "native C boundary: #{imports.length} imports, #{reachable.length} non-allocating functions checked"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    NativeSafety.main
  rescue NativeSafety::ContractError, SystemCallError, OptionParser::ParseError => error
    abort error.message
  end
end
