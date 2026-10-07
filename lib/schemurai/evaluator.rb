# frozen_string_literal: true

require "json"
require "base64"
require_relative "evaluation"
require_relative "error_message"
require_relative "unique_items"

module Schemurai
  module Internal
    class Evaluator
      include UniqueItems

      MISSING_SEGMENT = Object.new.freeze

      def backend = :ruby

      def initialize(graph, root, content: false, format: false)
        @validate_content = content
        @validate_format = format
        @graph = graph
        @root = root
        @regexps = nil
        @active = nil
      end

      def validate(instance)
        errors = []
        each_error(instance) { |error| errors << error }
        Result.new(errors)
      end

      def valid?(instance)
        @error_callback = nil
        @error_count = 0
        @track_dynamic_scope = @graph.dynamic_scope?
        @dynamic_scope = nil
        @instance_path = nil
        @schema_path = nil
        evaluate_valid(@root, instance)
      end

      private def each_error(instance, &callback)
        @error_callback = callback
        @error_count = 0
        @track_dynamic_scope = @graph.dynamic_scope?
        @dynamic_scope = nil
        @instance_path = []
        @schema_path = []
        evaluate(@root, instance)
      ensure
        @error_callback = nil
      end

      private def evaluate_valid(node, instance)
        schema = node.schema
        return schema if schema == true || schema == false
        return true unless schema.is_a?(Hash)

        # These applicators depend on annotations collected from sibling
        # applicators. Keep them on the full evaluation path; schemas without
        # them can avoid allocating Evaluation objects and JSON Pointer paths.
        if schema.key?("unevaluatedProperties") || schema.key?("unevaluatedItems")
          @instance_path ||= []
          @schema_path ||= []
          return evaluate(node, instance).valid?
        end

        if @track_dynamic_scope
          entered_scope = @dynamic_scope.nil? || !@dynamic_scope.last.equal?(node.resource)
          (@dynamic_scope ||= []) << node.resource if entered_scope
        end

        if schema.key?("$ref")
          return false unless valid_reference?(node, @graph.resolve(node, schema["$ref"]), instance)
          return true unless node.dialect.ref_siblings?
        end

        if schema.key?("$recursiveRef")
          return false unless valid_reference?(node, recursive_target(node, schema["$recursiveRef"]), instance)
        end

        if schema.key?("$dynamicRef")
          return false unless valid_reference?(node, dynamic_target(node, schema["$dynamicRef"]), instance)
        end

        keywords = node.keyword_mask
        if keywords.zero? && format_asserted?(node)
          return !instance.is_a?(String) || node.format.call(instance)
        end

        categories = Internal::Dialect
        return false if (keywords & categories::TYPE) != 0 && !valid_type?(schema, instance)
        return false if (keywords & categories::ENUM) != 0 && !valid_enum?(schema, instance)
        return false if (keywords & categories::COMBINER) != 0 && !valid_combiners?(node, instance)

        case instance
        when Hash
          (keywords & categories::OBJECT) == 0 || valid_object?(node, instance)
        when Array
          (keywords & categories::ARRAY) == 0 || valid_array?(node, instance)
        when String
          if (keywords & categories::STRING) != 0
            valid_string?(node, instance)
          elsif format_asserted?(node)
            node.format.call(instance)
          else
            true
          end
        when Numeric
          instance.is_a?(Complex) || (keywords & categories::NUMBER) == 0 || valid_number?(schema, instance)
        else
          true
        end
      rescue ResolutionError
        false
      ensure
        @dynamic_scope.pop if entered_scope
      end

      private def valid_reference?(source, target, instance)
        instances = active_instances(source)
        instance_id = instance.object_id
        return true if instances[instance_id]

        instances[instance_id] = true
        activated = true
        evaluate_valid(target, instance)
      ensure
        instances&.delete(instance_id) if activated
      end

      private def valid_type?(schema, value)
        types = schema["type"]
        return types.any? { |type| type?(value, type) } if types.is_a?(Array)

        type?(value, types)
      end

      private def valid_enum?(schema, value)
        return false if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
        return false if schema.key?("const") && !json_equal?(schema["const"], value)

        true
      end

      private def valid_combiners?(node, value)
        schema = node.schema
        if schema.key?("allOf")
          schema["allOf"].each_index do |index|
            return false unless evaluate_valid(node.child("allOf", index), value)
          end
        end
        if schema.key?("anyOf")
          matched = schema["anyOf"].each_index.any? do |index|
            evaluate_valid(node.child("anyOf", index), value)
          end
          return false unless matched
        end
        if schema.key?("oneOf")
          matches = 0
          schema["oneOf"].each_index do |index|
            matches += 1 if evaluate_valid(node.child("oneOf", index), value)
            return false if matches > 1
          end
          return false unless matches == 1
        end
        return false if schema.key?("not") && evaluate_valid(node.child("not"), value)

        if schema.key?("if")
          branch = evaluate_valid(node.child("if"), value) ? "then" : "else"
          return false if schema.key?(branch) && !evaluate_valid(node.child(branch), value)
        end
        true
      end

      private def valid_number?(schema, value)
        actual = nil
        if schema.key?("maximum")
          actual ||= decimal(value)
          return false unless actual <= decimal(schema["maximum"])
        end
        if schema.key?("minimum")
          actual ||= decimal(value)
          return false unless actual >= decimal(schema["minimum"])
        end
        if schema.key?("exclusiveMaximum")
          actual ||= decimal(value)
          return false unless actual < decimal(schema["exclusiveMaximum"])
        end
        if schema.key?("exclusiveMinimum")
          actual ||= decimal(value)
          return false unless actual > decimal(schema["exclusiveMinimum"])
        end
        if schema.key?("multipleOf")
          divisor = decimal(schema["multipleOf"])
          return false unless divisor.positive?
          return false unless (actual || decimal(value)).remainder(divisor).zero?
        end
        true
      end

      private def valid_string?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxLength") && length > schema["maxLength"]
        return false if schema.key?("minLength") && length < schema["minLength"]
        return false if schema.key?("pattern") && !ecma_regexp(schema["pattern"]).match?(value)
        if format_asserted?(node)
          return false unless node.format.call(value)
        end
        return valid_content?(schema, value) if @validate_content

        true
      rescue RegexpError, IPAddr::InvalidAddressError
        false
      end

      private def valid_content?(schema, value)
        decoded = (schema["contentEncoding"] == "base64") ? Base64.strict_decode64(value) : value
        JSON.parse(decoded) if schema["contentMediaType"] == "application/json"
        true
      rescue ArgumentError, JSON::ParserError
        false
      end

      private def valid_array?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxItems") && length > schema["maxItems"]
        return false if schema.key?("minItems") && length < schema["minItems"]
        return false if schema["uniqueItems"] && !unique_items?(value)

        prefix_items = schema["prefixItems"]
        if prefix_items.is_a?(Array)
          prefix_items.each_index do |index|
            break if index >= length
            return false unless evaluate_valid(node.child("prefixItems", index), value[index])
          end
        end

        items = schema["items"]
        if items.is_a?(Array)
          items.each_index do |index|
            break if index >= length
            return false unless evaluate_valid(node.child("items", index), value[index])
          end
          if length > items.length && schema.key?("additionalItems")
            additional = node.child("additionalItems")
            (items.length...length).each do |index|
              return false unless evaluate_valid(additional, value[index])
            end
          end
        elsif !items.nil?
          child = node.child("items")
          start = prefix_items.is_a?(Array) ? prefix_items.length : 0
          (start...length).each do |index|
            return false unless evaluate_valid(child, value[index])
          end
        end

        if schema.key?("contains")
          child = node.child("contains")
          if node.dialect.keywords.key?("minContains")
            matches = value.count { |item| evaluate_valid(child, item) }
            return false if matches < schema.fetch("minContains", 1)
            return false if schema.key?("maxContains") && matches > schema["maxContains"]
          else
            return false unless value.any? { |item| evaluate_valid(child, item) }
          end
        end
        true
      end

      private def valid_object?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxProperties") && length > schema["maxProperties"]
        return false if schema.key?("minProperties") && length < schema["minProperties"]
        return false if schema.key?("required") && !schema["required"].all? { |name| value.key?(name) }

        properties = schema["properties"]
        patterns = schema["patternProperties"]
        additional = node.child("additionalProperties") if schema.key?("additionalProperties")
        value.each do |name, property_value|
          matched = false
          if properties&.key?(name)
            matched = true
            return false unless evaluate_valid(node.child("properties", name), property_value)
          end
          if patterns
            patterns.each_key do |pattern|
              next unless ecma_regexp(pattern).match?(name)
              matched = true
              return false unless evaluate_valid(node.child("patternProperties", pattern), property_value)
            end
          end
          return false if !matched && additional && !evaluate_valid(additional, property_value)
        end

        if schema.key?("propertyNames")
          child = node.child("propertyNames")
          value.each_key { |name| return false unless evaluate_valid(child, name) }
        end

        if schema.key?("dependencies")
          schema["dependencies"].each do |name, dependency|
            next unless value.key?(name)
            if dependency.is_a?(Array)
              return false unless dependency.all? { |required_name| value.key?(required_name) }
            else
              return false unless evaluate_valid(node.child("dependencies", name), value)
            end
          end
        end
        if schema.key?("dependentRequired")
          schema["dependentRequired"].each do |name, required_names|
            next unless value.key?(name)
            return false unless required_names.all? { |required_name| value.key?(required_name) }
          end
        end

        if schema.key?("dependentSchemas")
          schema["dependentSchemas"].each_key do |name|
            next unless value.key?(name)
            return false unless evaluate_valid(node.child("dependentSchemas", name), value)
          end
        end
        true
      end

      private def evaluate(node, instance)
        schema = node.schema
        return Evaluation.valid if schema == true
        if schema == false
          add_error("falseSchema", append_keyword: false) { ErrorMessage.false_schema }
          return Evaluation.invalid
        end
        return Evaluation.valid unless schema.is_a?(Hash)

        before = @error_count
        evaluation = Evaluation.valid

        if @track_dynamic_scope
          entered_scope = @dynamic_scope.nil? || !@dynamic_scope.last.equal?(node.resource)
          (@dynamic_scope ||= []) << node.resource if entered_scope
        end

        if schema.key?("$ref")
          begin
            target = @graph.resolve(node, schema["$ref"])
            evaluation = evaluation.merge(
              evaluate_reference(node, target, instance, "$ref")
            )
          rescue ResolutionError => e
            add_error("$ref", e.message, append_keyword: false)
          end
          return (@error_count == before) ? evaluation : Evaluation.invalid unless node.dialect.ref_siblings?
        end

        if schema.key?("$recursiveRef")
          target = recursive_target(node, schema["$recursiveRef"])
          evaluation = evaluation.merge(evaluate_reference(node, target, instance, "$recursiveRef"))
        end

        if schema.key?("$dynamicRef")
          target = dynamic_target(node, schema["$dynamicRef"])
          evaluation = evaluation.merge(evaluate_reference(node, target, instance, "$dynamicRef"))
        end

        keywords = node.keyword_mask
        categories = Internal::Dialect
        check_type(schema, instance) if (keywords & categories::TYPE) != 0
        check_enum(schema, instance) if (keywords & categories::ENUM) != 0
        if (keywords & categories::COMBINER) != 0
          evaluation = evaluation.merge(check_combiners(node, instance))
        end

        case instance
        when Hash
          if (keywords & categories::OBJECT) != 0
            evaluation = evaluation.merge(check_object(node, instance, evaluation))
          end
        when Array
          if (keywords & categories::ARRAY) != 0
            evaluation = evaluation.merge(check_array(node, instance, evaluation))
          end
        when String
          check_string(node, instance) if (keywords & categories::STRING) != 0 || format_asserted?(node)
        when Numeric
          check_number(schema, instance) if !instance.is_a?(Complex) && (keywords & categories::NUMBER) != 0
        end

        (@error_count == before) ? evaluation : Evaluation.invalid
      ensure
        @dynamic_scope.pop if entered_scope
      end

      private def evaluate_reference(node, target, instance, keyword)
        instances = active_instances(node)
        instance_id = instance.object_id
        return Evaluation.valid if instances[instance_id]

        instances[instance_id] = true
        activated = true
        evaluate_at(target, instance, MISSING_SEGMENT, keyword)
      rescue ResolutionError => e
        add_error(keyword, e.message, append_keyword: false)
        Evaluation.invalid
      ensure
        instances&.delete(instance_id) if activated
      end

      private def recursive_target(node, reference)
        target = @graph.resolve(node, reference)
        return target unless reference.to_s.end_with?("#") && target.schema.is_a?(Hash) && target.schema["$recursiveAnchor"] == true

        Array(@dynamic_scope).filter_map { |resource| resource.root if resource.root.schema.is_a?(Hash) && resource.root.schema["$recursiveAnchor"] == true }.first || target
      end

      private def dynamic_target(node, reference)
        target = @graph.resolve(node, reference)
        raw_fragment = reference.to_s.split("#", 2)[1]
        return target if raw_fragment.nil? || raw_fragment.empty? || raw_fragment.start_with?("/")
        return target unless target.schema.is_a?(Hash) && target.schema["$dynamicAnchor"] == raw_fragment

        Array(@dynamic_scope).each do |resource|
          dynamic = @graph.dynamic_anchor(resource, raw_fragment)
          return dynamic if dynamic
        end
        target
      end

      private def active_instances(node)
        active = (@active ||= {})
        active[node.object_id] ||= {}
      end

      private def check_type(schema, value)
        return unless schema.key?("type")

        types = Array(schema["type"])
        return if types.any? { |type| type?(value, type) }

        add_error("type") { ErrorMessage.type(types, value) }
      end

      private def check_enum(schema, value)
        if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
          add_error("enum") { ErrorMessage.enum }
        end
        if schema.key?("const") && !json_equal?(schema["const"], value)
          add_error("const") { ErrorMessage.const }
        end
      end

      private def check_combiners(node, value)
        schema = node.schema
        evaluation = Evaluation.valid
        if schema.key?("allOf")
          schema["allOf"].each_index do |index|
            evaluation = evaluation.merge(
              evaluate_at(node.child("allOf", index), value, MISSING_SEGMENT, "allOf", index)
            )
          end
        end

        if schema.key?("anyOf")
          matches = []
          schema["anyOf"].each_index do |index|
            result = trial_at(node.child("anyOf", index), value, MISSING_SEGMENT, "anyOf", index)
            matches << result if result.valid?
          end
          if matches.empty?
            add_error("anyOf") { ErrorMessage.any_of }
          else
            matches.each { |result| evaluation = evaluation.merge(result) }
          end
        end

        if schema.key?("oneOf")
          matches = []
          schema["oneOf"].each_index do |index|
            result = trial_at(node.child("oneOf", index), value, MISSING_SEGMENT, "oneOf", index)
            matches << result if result.valid?
          end
          if matches.length == 1
            evaluation = evaluation.merge(matches.first)
          else
            add_error("oneOf") { ErrorMessage.one_of(matches.length) }
          end
        end

        if schema.key?("not") && trial_at(node.child("not"), value, MISSING_SEGMENT, "not").valid?
          add_error("not") { ErrorMessage.not }
        end

        if schema.key?("if")
          condition = trial_at(node.child("if"), value, MISSING_SEGMENT, "if")
          branch = condition.valid? ? "then" : "else"
          evaluation = evaluation.merge(condition) if condition.valid?
          if schema.key?(branch)
            evaluation = evaluation.merge(evaluate_at(node.child(branch), value, MISSING_SEGMENT, branch))
          end
        end
        evaluation
      end

      private def check_number(schema, value)
        compare(schema, "maximum", value) { |a, b| a <= b }
        compare(schema, "minimum", value) { |a, b| a >= b }
        compare(schema, "exclusiveMaximum", value) { |a, b| a < b }
        compare(schema, "exclusiveMinimum", value) { |a, b| a > b }

        return unless schema.key?("multipleOf")

        divisor = decimal(schema["multipleOf"])
        valid = divisor.positive? && decimal(value).remainder(divisor).zero?
        add_error("multipleOf") { ErrorMessage.multiple_of(schema["multipleOf"]) } unless valid
      end

      private def compare(schema, keyword, value)
        return unless schema.key?(keyword)
        return if yield(decimal(value), decimal(schema[keyword]))

        add_error(keyword) { ErrorMessage.numeric_limit(keyword, schema[keyword]) }
      end

      private def check_string(node, value)
        schema = node.schema
        length = value.length
        limit(schema, "maxLength", length) { |actual, expected| actual <= expected }
        limit(schema, "minLength", length) { |actual, expected| actual >= expected }

        if schema.key?("pattern")
          matched = ecma_regexp(schema["pattern"]).match?(value)
          add_error("pattern") { ErrorMessage.pattern(schema["pattern"]) } unless matched
        end
        if format_asserted?(node)
          add_error("format") { ErrorMessage.format(node.format.name) } unless node.format.call(value)
        end
        check_content(schema, value) if @validate_content
      rescue RegexpError
        add_error("pattern") { ErrorMessage.invalid_pattern(schema["pattern"]) }
      end

      private def format_asserted?(node)
        (@validate_format || node.dialect.format_assertion?) && !node.format.nil?
      end

      private def check_array(node, value, prior_evaluation)
        schema = node.schema
        evaluated = []
        limit(schema, "maxItems", value.length) { |actual, expected| actual <= expected }
        limit(schema, "minItems", value.length) { |actual, expected| actual >= expected }

        add_error("uniqueItems") { ErrorMessage.unique_items } if schema["uniqueItems"] && !unique_items?(value)

        prefix_items = schema["prefixItems"]
        if prefix_items.is_a?(Array)
          prefix_items.each_index do |index|
            break if index >= value.length
            evaluate_at(node.child("prefixItems", index), value[index], index, "prefixItems", index)
            evaluated << index
          end
        end

        items = schema["items"]
        if items.is_a?(Array)
          items.each_index do |index|
            break if index >= value.length
            evaluate_at(node.child("items", index), value[index], index, "items", index)
            evaluated << index
          end
          if value.length > items.length && schema.key?("additionalItems")
            additional = node.child("additionalItems")
            (items.length...value.length).each do |index|
              evaluate_at(additional, value[index], index, "additionalItems")
              evaluated << index
            end
          end
        elsif !items.nil?
          start = prefix_items.is_a?(Array) ? prefix_items.length : 0
          value.each_with_index do |item, index|
            next if index < start
            evaluate_at(node.child("items"), item, index, "items")
            evaluated << index
          end
        end

        if schema.key?("contains")
          matched = value.each_index.select do |index|
            trial_at(node.child("contains"), value[index], index, "contains").valid?
          end
          minimum = schema.fetch("minContains", 1)
          maximum = schema.fetch("maxContains", Float::INFINITY)
          unless matched.length.between?(minimum, maximum)
            add_error("contains") { ErrorMessage.contains(matched.length, minimum, maximum) }
          end
          evaluated.concat(matched)
        end

        combined = prior_evaluation.evaluated_items | evaluated
        if schema.key?("unevaluatedItems")
          unevaluated = (0...value.length).to_a - combined
          unevaluated.each do |index|
            evaluate_at(node.child("unevaluatedItems"), value[index], index, "unevaluatedItems")
          end
          evaluated.concat(unevaluated)
        end
        Evaluation.valid(evaluated_items: evaluated.uniq)
      end

      private def check_object(node, value, prior_evaluation)
        schema = node.schema
        evaluated = []
        limit(schema, "maxProperties", value.length) { |actual, expected| actual <= expected }
        limit(schema, "minProperties", value.length) { |actual, expected| actual >= expected }

        Array(schema["required"]).each do |name|
          add_error("required") { ErrorMessage.required(name) } unless value.key?(name)
        end

        properties = schema.fetch("properties", {})
        patterns = schema.fetch("patternProperties", {})
        value.each do |name, property_value|
          matched = false
          if properties.key?(name)
            matched = true
            evaluate_at(node.child("properties", name), property_value, name, "properties", name)
            evaluated << name
          end
          patterns.each do |pattern, subschema|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            evaluate_at(node.child("patternProperties", pattern), property_value, name, "patternProperties", pattern)
            evaluated << name
          end
          if !matched && schema.key?("additionalProperties")
            evaluate_at(node.child("additionalProperties"), property_value, name, "additionalProperties")
            evaluated << name
          end
        end

        if schema.key?("propertyNames")
          value.each_key do |name|
            evaluate_at(node.child("propertyNames"), name, name, "propertyNames")
          end
        end

        schema.fetch("dependencies", {}).each do |name, dependency|
          next unless value.key?(name)
          if dependency.is_a?(Array)
            dependency.each do |required_name|
              add_error("dependencies") { ErrorMessage.dependent_required(name, required_name) } unless value.key?(required_name)
            end
          else
            result = evaluate_at(node.child("dependencies", name), value, MISSING_SEGMENT, "dependencies", name)
            evaluated.concat(result.evaluated_properties) if result.valid?
          end
        end

        schema.fetch("dependentRequired", {}).each do |name, required_names|
          next unless value.key?(name)
          required_names.each do |required_name|
            unless value.key?(required_name)
              add_error("dependentRequired") { ErrorMessage.dependent_required(name, required_name) }
            end
          end
        end

        schema.fetch("dependentSchemas", {}).each_key do |name|
          next unless value.key?(name)
          result = evaluate_at(node.child("dependentSchemas", name), value, MISSING_SEGMENT, "dependentSchemas", name)
          evaluated.concat(result.evaluated_properties) if result.valid?
        end

        combined = prior_evaluation.evaluated_properties | evaluated
        if schema.key?("unevaluatedProperties")
          unevaluated = value.keys - combined
          unevaluated.each do |name|
            evaluate_at(node.child("unevaluatedProperties"), value[name], name, "unevaluatedProperties")
          end
          evaluated.concat(unevaluated)
        end
        Evaluation.valid(evaluated_properties: evaluated.uniq)
      end

      private def trial(node, value)
        saved_callback = @error_callback
        saved_error_count = @error_count
        @error_callback = nil
        @error_count = 0
        result = evaluate(node, value)
        result
      ensure
        @error_callback = saved_callback
        @error_count = saved_error_count
      end

      private def limit(schema, keyword, actual)
        return unless schema.key?(keyword)
        return if yield(actual, schema[keyword])

        add_error(keyword) { ErrorMessage.size(keyword, schema[keyword], actual) }
      end

      private def type?(value, type)
        case type
        when "null" then value.nil?
        when "boolean" then value == true || value == false
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "number" then number?(value)
        when "integer" then number?(value) && value.finite? && value.to_i == value
        when "string" then value.is_a?(String)
        else false
        end
      end

      private def number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end

      private def json_equal?(left, right)
        return false if json_kind(left) != json_kind(right)
        case left
        when Hash
          left.length == right.length && left.all? { |key, value| right.key?(key) && json_equal?(value, right[key]) }
        when Array
          left.length == right.length && left.each_index.all? { |index| json_equal?(left[index], right[index]) }
        else
          left == right
        end
      end

      private def json_kind(value)
        return :number if number?(value)
        return :boolean if value == true || value == false
        value.class
      end

      private def decimal(value)
        return value if value.is_a?(Integer) || value.is_a?(Rational)

        Rational(value.to_s)
      end

      # Ruby and ECMA-262 differ in their ASCII character classes, anchors, and
      # definition of whitespace. Draft 7 patterns use the ECMA behavior.
      private def ecma_regexp(pattern)
        regexps = (@regexps ||= {})
        return regexps[pattern] if regexps.key?(pattern)

        whitespace = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
        translated = +""
        escaped = false
        in_class = false
        pattern.each_char do |character|
          if escaped
            translated << case character
            when "d" then in_class ? "0-9" : "[0-9]"
            when "D" then in_class ? "^0-9" : "[^0-9]"
            when "w" then in_class ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
            when "W" then in_class ? "^A-Za-z0-9_" : "[^A-Za-z0-9_]"
            when "s" then in_class ? whitespace : "[#{whitespace}]"
            when "S" then in_class ? "^#{whitespace}" : "[^#{whitespace}]"
            else "\\#{character}"
            end
            escaped = false
          elsif character == "\\"
            escaped = true
          elsif character == "["
            in_class = true
            translated << character
          elsif character == "]"
            in_class = false
            translated << character
          elsif character == "^" && !in_class
            translated << "\\A"
          elsif character == "$" && !in_class
            translated << "\\z"
          else
            translated << character
          end
        end
        translated << "\\" if escaped
        regexps[pattern] = Regexp.new(translated)
      end

      private def check_content(schema, value)
        decoded = value
        if schema["contentEncoding"] == "base64"
          decoded = Base64.strict_decode64(value)
        end
        return unless schema["contentMediaType"] == "application/json"

        JSON.parse(decoded)
      rescue ArgumentError, JSON::ParserError
        keyword = (schema["contentEncoding"] == "base64") ? "contentEncoding" : "contentMediaType"
        add_error(keyword) do
          (keyword == "contentEncoding") ? ErrorMessage.content_encoding : ErrorMessage.content_media_type
        end
      end

      private def add_error(keyword, message = nil, append_keyword: true)
        @error_count += 1
        if @error_callback
          schema_keyword = append_keyword ? keyword : MISSING_SEGMENT
          @error_callback.call(
            ValidationError.new(
              keyword: keyword,
              instance_path: pointer(@instance_path),
              schema_path: pointer(@schema_path, schema_keyword),
              message: message || yield
            )
          )
        end
        false
      end

      private def evaluate_at(node, instance, instance_segment, schema_segment, schema_child_segment = MISSING_SEGMENT)
        @instance_path << instance_segment unless instance_segment.equal?(MISSING_SEGMENT)
        @schema_path << schema_segment
        @schema_path << schema_child_segment unless schema_child_segment.equal?(MISSING_SEGMENT)
        evaluate(node, instance)
      ensure
        @schema_path.pop unless schema_child_segment.equal?(MISSING_SEGMENT)
        @schema_path.pop
        @instance_path.pop unless instance_segment.equal?(MISSING_SEGMENT)
      end

      private def trial_at(node, instance, instance_segment, schema_segment, schema_child_segment = MISSING_SEGMENT)
        @instance_path << instance_segment unless instance_segment.equal?(MISSING_SEGMENT)
        @schema_path << schema_segment
        @schema_path << schema_child_segment unless schema_child_segment.equal?(MISSING_SEGMENT)
        trial(node, instance)
      ensure
        @schema_path.pop unless schema_child_segment.equal?(MISSING_SEGMENT)
        @schema_path.pop
        @instance_path.pop unless instance_segment.equal?(MISSING_SEGMENT)
      end

      private def pointer(path, final_segment = MISSING_SEGMENT)
        pointer = +""
        path.each { |segment| append_pointer_segment(pointer, segment) }
        append_pointer_segment(pointer, final_segment) unless final_segment.equal?(MISSING_SEGMENT)
        pointer
      end

      private def append_pointer_segment(pointer, segment)
        pointer << "/" << segment.to_s.gsub("~", "~0").gsub("/", "~1")
      end

      private_constant :MISSING_SEGMENT
    end
  end
end
