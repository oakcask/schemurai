# frozen_string_literal: true

module Schemurai
  module VM
    NumberRules = Data.define(
      :mask,
      :maximum,
      :minimum,
      :exclusive_maximum,
      :exclusive_minimum,
      :multiple_of
    )

    MAXIMUM = 1 << 0
    MINIMUM = 1 << 1
    EXCLUSIVE_MAXIMUM = 1 << 2
    EXCLUSIVE_MINIMUM = 1 << 3
    MULTIPLE_OF = 1 << 4

    TypeRules = Data.define(:mask, :names)

    TYPE_NULL = 1 << 0
    TYPE_BOOLEAN = 1 << 1
    TYPE_OBJECT = 1 << 2
    TYPE_ARRAY = 1 << 3
    TYPE_NUMBER = 1 << 4
    TYPE_INTEGER = 1 << 5
    TYPE_STRING = 1 << 6

    TRACKS_EVALUATION = 1 << 0
    TRACKS_DYNAMIC_SCOPE = 1 << 1

    DIALECT = Schemurai.const_get(:Internal)::Dialect
    KEYWORD_TYPE = DIALECT::TYPE
    KEYWORD_ENUM = DIALECT::ENUM
    KEYWORD_COMBINER = DIALECT::COMBINER
    KEYWORD_NUMBER = DIALECT::NUMBER
    KEYWORD_STRING = DIALECT::STRING
    KEYWORD_ARRAY = DIALECT::ARRAY
    KEYWORD_OBJECT = DIALECT::OBJECT
    private_constant :DIALECT

    TYPE_BITS = {
      "null" => TYPE_NULL,
      "boolean" => TYPE_BOOLEAN,
      "object" => TYPE_OBJECT,
      "array" => TYPE_ARRAY,
      "number" => TYPE_NUMBER,
      "integer" => TYPE_INTEGER,
      "string" => TYPE_STRING
    }.freeze

    TYPE_OPCODES = {
      "null" => :type_null,
      "boolean" => :type_boolean,
      "object" => :type_object,
      "array" => :type_array,
      "number" => :type_number,
      "integer" => :type_integer,
      "string" => :type_string
    }.freeze

    ReferenceRules = Data.define(:value, :fragment)

    StringRules = Data.define(
      :max_length,
      :min_length,
      :pattern,
      :format,
      :format_assertion,
      :decode_base64,
      :parse_json
    )

    ArrayRules = Data.define(
      :max_items,
      :min_items,
      :unique,
      :prefix_items,
      :items,
      :items_list,
      :additional,
      :contains,
      :min_contains,
      :max_contains,
      :count_contains,
      :unevaluated
    )

    ObjectRules = Data.define(
      :max_properties,
      :min_properties,
      :required,
      :properties,
      :patterns,
      :additional,
      :property_names,
      :dependencies,
      :dependent_required,
      :dependent_schemas,
      :unevaluated
    )

    ConditionalRules = Data.define(
      :condition,
      :then_branch,
      :else_branch
    )

    class Program
      attr_reader :node, :code, :dynamic_anchor

      def initialize(node)
        @node = node
        @tracks_evaluation = false
        @tracks_dynamic_scope = false
        schema = node.schema
        if schema.instance_of?(Hash)
          @recursive_anchor = schema["$recursiveAnchor"] == true
          dynamic_anchor = schema["$dynamicAnchor"]
          @dynamic_anchor = -dynamic_anchor if dynamic_anchor.instance_of?(String)
        else
          @recursive_anchor = false
        end
      end

      def emit(code, opcode, operand)
        code.push(opcode, operand)
      end

      def track_evaluation!
        @tracks_evaluation = true
      end

      def track_dynamic_scope!
        @tracks_dynamic_scope = true
      end

      def finish(code)
        flags = 0
        flags |= TRACKS_EVALUATION if @tracks_evaluation
        flags |= TRACKS_DYNAMIC_SCOPE if @tracks_dynamic_scope
        code[0] = flags
        @code = code.freeze
        freeze
      end

      def recursive_anchor?
        @recursive_anchor
      end

      def tracks_dynamic_scope?
        @tracks_dynamic_scope
      end
    end

    class Compiler
      def initialize(graph)
        @graph = graph
        @programs = {}.compare_by_identity
      end

      def compile(node)
        program = @programs[node]
        return program if program

        program = Program.new(node)
        @programs[node] = program
        program.finish(compile_code(node, program))
      end

      def compile_all
        @graph.nodes.each { |node| compile(node) }
        self
      end

      def resolve(program, reference)
        compile(@graph.resolve(program.node, reference))
      end

      private def compile_child(node, parent)
        child = compile(node)
        parent.track_dynamic_scope! if child.tracks_dynamic_scope?
        child
      end

      private def compile_code(node, program)
        schema = node.schema
        return program.emit([0], :boolean, schema) if schema.equal?(true) || schema.equal?(false)
        return [0] unless schema.is_a?(Hash)

        code = [0]
        if schema.key?("$ref")
          program.track_dynamic_scope!
          program.emit(code, :ref, compile_reference(schema["$ref"]))
          return code unless node.dialect.ref_siblings?
        end
        if schema.key?("$recursiveRef")
          program.track_dynamic_scope!
          program.emit(code, :recursive_ref, compile_reference(schema["$recursiveRef"]))
        end
        if schema.key?("$dynamicRef")
          program.track_dynamic_scope!
          program.emit(code, :dynamic_ref, compile_reference(schema["$dynamicRef"]))
        end

        mask = node.keyword_mask
        compile_type(code, program, schema["type"]) if (mask & KEYWORD_TYPE) != 0 && schema.key?("type")
        if (mask & KEYWORD_ENUM) != 0
          program.emit(code, :enum, snapshot(schema["enum"])) if schema.key?("enum")
          program.emit(code, :const, snapshot(schema["const"])) if schema.key?("const")
        end
        compile_combiners(code, program, node, schema) if (mask & KEYWORD_COMBINER) != 0
        program.emit(code, :number, compile_number(schema)) if (mask & KEYWORD_NUMBER) != 0
        if (mask & KEYWORD_STRING) != 0 || node.format
          program.emit(code, :string, compile_string(node, schema))
        end
        if (mask & KEYWORD_ARRAY) != 0
          rules = compile_array(node, schema, program)
          program.track_evaluation! if rules.unevaluated
          program.emit(code, :array, rules)
        end
        if (mask & KEYWORD_OBJECT) != 0
          rules = compile_object(node, schema, program)
          program.track_evaluation! if rules.unevaluated
          program.emit(code, :object, rules)
        end
        fuse_type_instruction(code)
      end

      private def fuse_type_instruction(code)
        index = 1
        while index + 3 < code.length
          type_opcode = code[index]
          rules_opcode = code[index + 2]
          fused_opcode = case type_opcode
          when :type_object then :typed_object if rules_opcode == :object
          when :type_array then :typed_array if rules_opcode == :array
          when :type_string then :typed_string if rules_opcode == :string
          when :type_number then :typed_number if rules_opcode == :number
          when :type_integer then :typed_integer if rules_opcode == :number
          end
          if fused_opcode
            code[index] = fused_opcode
            code[index + 1] = code[index + 3]
            code.slice!(index + 2, 2)
            break
          end
          index += 2
        end
        code
      end

      private def compile_combiners(code, program, node, schema)
        %w[allOf anyOf oneOf].each do |keyword|
          next unless schema.key?(keyword)

          children = schema[keyword].each_index.map do |index|
            compile_child(node.child(keyword, index), program)
          end
          program.emit(code, keyword.to_sym, children)
        end
        program.emit(code, :not, compile_child(node.child("not"), program)) if schema.key?("not")
        return unless schema.key?("if")

        program.emit(
          code,
          :conditional,
          ConditionalRules.new(
            compile_child(node.child("if"), program),
            schema.key?("then") ? compile_child(node.child("then"), program) : nil,
            schema.key?("else") ? compile_child(node.child("else"), program) : nil
          )
        )
      end

      private def compile_number(schema)
        mask = 0
        mask |= MAXIMUM if schema.key?("maximum")
        mask |= MINIMUM if schema.key?("minimum")
        mask |= EXCLUSIVE_MAXIMUM if schema.key?("exclusiveMaximum")
        mask |= EXCLUSIVE_MINIMUM if schema.key?("exclusiveMinimum")
        mask |= MULTIPLE_OF if schema.key?("multipleOf")
        NumberRules.new(
          mask,
          compile_decimal(schema["maximum"]),
          compile_decimal(schema["minimum"]),
          compile_decimal(schema["exclusiveMaximum"]),
          compile_decimal(schema["exclusiveMinimum"]),
          compile_decimal(schema["multipleOf"])
        )
      end

      private def compile_reference(reference)
        value = snapshot(reference)
        separator = value.index("#")
        fragment = separator ? -value[(separator + 1)..] : nil
        ReferenceRules.new(value, fragment)
      end

      private def compile_type(code, program, types)
        return program.emit(code, TYPE_OPCODES.fetch(types), nil) unless types.is_a?(Array)

        mask = types.reduce(0) { |result, type| result | TYPE_BITS.fetch(type) }
        program.emit(code, :types, TypeRules.new(mask, snapshot(types)))
      end

      private def compile_string(node, schema)
        StringRules.new(
          schema["maxLength"],
          schema["minLength"],
          snapshot(schema["pattern"]),
          node.format,
          node.dialect.format_assertion?,
          schema["contentEncoding"] == "base64",
          schema["contentMediaType"] == "application/json"
        )
      end

      private def compile_array(node, schema, program)
        prefix_items = if schema["prefixItems"].is_a?(Array)
          schema["prefixItems"].each_index.map do |index|
            compile_child(node.child("prefixItems", index), program)
          end.freeze
        end
        items = if schema["items"].is_a?(Array)
          schema["items"].each_index.map do |index|
            compile_child(node.child("items", index), program)
          end.freeze
        elsif !schema["items"].nil?
          compile_child(node.child("items"), program)
        end
        ArrayRules.new(
          schema["maxItems"],
          schema["minItems"],
          schema["uniqueItems"],
          prefix_items,
          items,
          items.is_a?(Array),
          schema.key?("additionalItems") ? compile_child(node.child("additionalItems"), program) : nil,
          schema.key?("contains") ? compile_child(node.child("contains"), program) : nil,
          schema.fetch("minContains", 1),
          schema.fetch("maxContains", Float::INFINITY),
          node.dialect.keywords.key?("minContains"),
          schema.key?("unevaluatedItems") ? compile_child(node.child("unevaluatedItems"), program) : nil
        )
      end

      private def compile_object(node, schema, program)
        ObjectRules.new(
          schema["maxProperties"],
          schema["minProperties"],
          snapshot(schema["required"]),
          compile_map(node, schema, "properties", program),
          compile_optional_map(node, schema, "patternProperties", program),
          schema.key?("additionalProperties") ? compile_child(node.child("additionalProperties"), program) : nil,
          schema.key?("propertyNames") ? compile_child(node.child("propertyNames"), program) : nil,
          compile_dependencies(node, schema, program),
          schema.fetch("dependentRequired", {}).map do |name, required_names|
            [snapshot(name), snapshot(required_names)].freeze
          end.then { |entries| entries.empty? ? nil : entries.freeze },
          compile_optional_map(node, schema, "dependentSchemas", program),
          schema.key?("unevaluatedProperties") ? compile_child(node.child("unevaluatedProperties"), program) : nil
        )
      end

      private def compile_map(node, schema, keyword, program)
        schema.fetch(keyword, {}).each_key.to_h do |name|
          [snapshot(name), compile_child(node.child(keyword, name), program)]
        end.freeze
      end

      private def compile_optional_map(node, schema, keyword, program)
        compiled = compile_map(node, schema, keyword, program)
        compiled unless compiled.empty?
      end

      private def compile_dependencies(node, schema, program)
        compiled = schema.fetch("dependencies", {}).map do |name, dependency|
          compiled = if dependency.is_a?(Array)
            snapshot(dependency)
          else
            compile_child(node.child("dependencies", name), program)
          end
          [snapshot(name), compiled].freeze
        end
        compiled.freeze unless compiled.empty?
      end

      # Keep aliases inside one operand while copying away from caller-owned
      # containers. A fresh identity table also rechecks later compilations.
      private def snapshot(value, copies = {}.compare_by_identity)
        return copies[value] if copies.key?(value)

        case value
        when Hash
          copies[value] = value.to_h { |key, item| [snapshot(key, copies), snapshot(item, copies)] }.freeze
        when Array
          copies[value] = value.map { |item| snapshot(item, copies) }.freeze
        when String
          -value
        else
          value
        end
      end

      private def compile_decimal(value)
        return value if value.nil? || value.is_a?(Integer) || value.is_a?(Rational)

        Rational(value.to_s)
      end
    end
  end
end
