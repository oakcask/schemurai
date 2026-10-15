# frozen_string_literal: true

require_relative "../decimal"
require "base64"
require "json"
require "set" # rubocop:disable Lint/RedundantRequireStatement -- Required on Ruby 3.4.
require_relative "../evaluation"
require_relative "../error_message"
require_relative "../unique_items"
require_relative "../value_equality"
require_relative "../container_checks"
require_relative "../ecma_regexp"
require_relative "../json_pointer"
require_relative "compiler"
require_relative "../string_checks"

module Schemurai
  module VM
    class EvaluationBuffer
      attr_reader :evaluated_properties, :evaluated_items

      def initialize
        # Applicators can overlap. Array membership makes collecting and merging
        # their annotations quadratic in the number of instance locations.
        @evaluated_properties = Set.new
        @evaluated_items = Set.new
      end

      def valid? = true

      def reset
        @evaluated_properties.clear
        @evaluated_items.clear
        self
      end

      def record_property(name)
        @evaluated_properties.add(name)
        self
      end

      def record_item(index)
        @evaluated_items.add(index)
        self
      end

      def merge(other)
        return Evaluation.invalid unless other.valid?

        properties = other.evaluated_properties
        items = other.evaluated_items
        @evaluated_properties.merge(properties) unless properties.empty?
        @evaluated_items.merge(items) unless items.empty?
        self
      end
    end
    private_constant :EvaluationBuffer

    class Evaluator
      include Internal::UniqueItems
      include Internal::ValueEquality
      include Internal::ContainerChecks::Bounds
      include Internal::ContainerChecks::ObjectChildren
      include Internal::ContainerChecks::ArrayChildren
      include Internal::ContainerChecks::ArrayDiagnostics
      include Internal::NumberChecks::Evaluation
      include Internal::StringChecks::Evaluation
      include Internal::StringChecks::Regexps

      MISSING_SEGMENT = Object.new.freeze

      def backend = :vm

      def initialize(graph, compiler, root, content: false, format: false, number_state: nil, regexps: nil, dynamic_scope: nil, active_state: nil, native_references: nil, native_reports: nil)
        @graph = graph
        @compiler = compiler
        @root = root
        @validate_content = content
        @validate_format = format
        @regexps = regexps
        @active = active_state
        @native_reports = native_reports
        @native_references = native_references
        @resolved_references = nil
        @number_state = number_state
        @dynamic_scope = dynamic_scope
        @instance_path_buffer = nil
        @schema_path_buffer = nil
        @evaluation_pool = nil
        @evaluation_pool_index = 0
      end

      def validate(instance)
        @errors = []
        prepare_evaluation(paths: true)
        @native_reports[0] = self if @native_reports
        evaluate(@root, instance)
        Result.new(@errors)
      ensure
        @errors = nil
      end

      def valid?(instance)
        @errors = nil
        @error_count = 0
        @dynamic_scope&.clear
        @instance_path = nil
        @schema_path = nil
        reset_evaluation_pool
        @native_reports[0] = self if @native_reports
        evaluate_valid(@root, instance)
      end

      # Data exchange for retained native blocks during a compatibility traversal.
      # These methods expose collection state, never programs or instructions.
      private def native_report_context
        [@errors, @error_count || 0, @instance_path, @schema_path]
      end

      private def native_clear_collection(paths = false)
        @errors = nil
        @error_count = 0
        if paths
          (@instance_path_buffer ||= []).clear
          (@schema_path_buffer ||= []).clear
          @instance_path = @instance_path_buffer
          @schema_path = @schema_path_buffer
        else
          @instance_path = nil
          @schema_path = nil
        end
      end

      private def native_append_report(errors, count, reset)
        native_clear_collection(reset == 2) unless reset.zero?
        @error_count += count
        @errors.concat(errors) if @errors
        @native_reports[0] = self
      end

      private def prepare_evaluation(paths:)
        @error_count = 0
        @dynamic_scope&.clear
        reset_evaluation_pool
        if paths
          (@instance_path_buffer ||= []).clear
          (@schema_path_buffer ||= []).clear
          @instance_path = @instance_path_buffer
          @schema_path = @schema_path_buffer
        else
          @instance_path = nil
          @schema_path = nil
        end
      end

      private def evaluate_valid(program, instance)
        code = program.code
        flags = code[0]
        entered_scope = false
        unless flags.zero?
          return evaluate(program, instance).valid? if (flags & TRACKS_EVALUATION) != 0

          if (flags & TRACKS_DYNAMIC_SCOPE) != 0
            resource = program.node.resource
            unless @dynamic_scope&.last.equal?(resource)
              (@dynamic_scope ||= []) << resource
              entered_scope = true
            end
          end
        end
        instruction_index = 1
        while (opcode = code[instruction_index])
          @budget&.checkpoint
          operand = code[instruction_index + 1]
          case opcode
          when :boolean
            return operand
          when :ref
            target = reference_target(program, operand)
            return false unless valid_reference?(program, target, instance)
          when :recursive_ref
            target = recursive_target(program, operand)
            return false unless valid_reference?(program, target, instance)
          when :dynamic_ref
            target = dynamic_target(program, operand)
            return false unless valid_reference?(program, target, instance)
          when :type_null
            return false unless Internal::TypeChecks.single?(instance, TYPE_NULL)
          when :type_boolean
            return false unless Internal::TypeChecks.single?(instance, TYPE_BOOLEAN)
          when :type_object
            return false unless Internal::TypeChecks.single?(instance, TYPE_OBJECT)
          when :type_array
            return false unless Internal::TypeChecks.single?(instance, TYPE_ARRAY)
          when :type_number
            return false unless Internal::TypeChecks.single?(instance, TYPE_NUMBER)
          when :type_integer
            return false unless Internal::TypeChecks.single?(instance, TYPE_INTEGER)
          when :type_string
            return false unless Internal::TypeChecks.single?(instance, TYPE_STRING)
          when :typed_number
            return false unless instance.is_a?(Numeric) && !instance.is_a?(Complex) && valid_number?(operand, instance)
          when :typed_integer
            return false unless instance.is_a?(Numeric) && !instance.is_a?(Complex) && instance.finite? &&
              instance.to_i == instance && valid_number?(operand, instance)
          when :typed_string
            return false unless instance.is_a?(String) && valid_string?(operand, instance)
          when :typed_array
            return false unless instance.is_a?(Array) && valid_array?(operand, instance)
          when :typed_object
            return false unless instance.is_a?(Hash) && valid_object?(operand, instance)
          when :types
            return false if (operand.mask & instance_type_mask(instance, integer: (operand.mask & TYPE_INTEGER) != 0)).zero?
          when :enum
            return false unless operand.any? { |candidate| json_equal?(candidate, instance) }
          when :const
            return false unless json_equal?(operand, instance)
          when :allOf
            return false unless operand.all? { |child| evaluate_valid(child, instance) }
          when :anyOf
            return false unless operand.any? { |child| evaluate_valid(child, instance) }
          when :oneOf
            matches = 0
            operand.each do |child|
              @budget&.checkpoint
              matches += 1 if evaluate_valid(child, instance)
              return false if matches > 1
            end
            return false unless matches == 1
          when :not
            return false if evaluate_valid(operand, instance)
          when :conditional
            if evaluate_valid(operand.condition, instance)
              return false if operand.then_branch && !evaluate_valid(operand.then_branch, instance)
            elsif operand.else_branch && !evaluate_valid(operand.else_branch, instance)
              return false
            end
          when :number
            return false if instance.is_a?(Numeric) && !instance.is_a?(Complex) && !valid_number?(operand, instance)
          when :string
            return false if instance.is_a?(String) && !valid_string?(operand, instance)
          when :array
            return false if instance.is_a?(Array) && !valid_array?(operand, instance)
          when :object
            return false if instance.is_a?(Hash) && !valid_object?(operand, instance)
          else
            raise "unknown VM instruction #{opcode.inspect}"
          end
          instruction_index += 2
        end
        true
      rescue ResolutionError
        false
      ensure
        leave_scope if entered_scope
      end

      private def reset_evaluation_pool
        @evaluation_pool_index = 0
      end

      private def tracked_evaluation
        pool = (@evaluation_pool ||= [])
        index = @evaluation_pool_index
        @evaluation_pool_index += 1
        (pool[index] ||= EvaluationBuffer.new).reset
      end

      private def evaluate(program, instance)
        before = @error_count
        evaluation = Evaluation.valid
        code = program.code
        flags = code[0]
        entered_scope = false
        if (flags & TRACKS_DYNAMIC_SCOPE) != 0
          resource = program.node.resource
          unless @dynamic_scope&.last.equal?(resource)
            (@dynamic_scope ||= []) << resource
            entered_scope = true
          end
        end

        instruction_index = 1
        while (opcode = code[instruction_index])
          @budget&.checkpoint
          operand = code[instruction_index + 1]
          case opcode
          when :boolean
            if operand == false
              add_error("falseSchema", append_keyword: false) { Internal::ErrorMessage.false_schema }
              evaluation = Evaluation.invalid
            end
          when :ref
            evaluation = evaluation.merge(evaluate_ref(program, operand, instance))
          when :recursive_ref
            evaluation = evaluation.merge(evaluate_recursive_ref(program, operand, instance))
          when :dynamic_ref
            evaluation = evaluation.merge(evaluate_dynamic_ref(program, operand, instance))
          when :type_null
            check_compiled_type("null", Internal::TypeChecks.single?(instance, TYPE_NULL), instance)
          when :type_boolean
            check_compiled_type("boolean", Internal::TypeChecks.single?(instance, TYPE_BOOLEAN), instance)
          when :type_object
            check_compiled_type("object", Internal::TypeChecks.single?(instance, TYPE_OBJECT), instance)
          when :type_array
            check_compiled_type("array", Internal::TypeChecks.single?(instance, TYPE_ARRAY), instance)
          when :type_number
            check_compiled_type("number", Internal::TypeChecks.single?(instance, TYPE_NUMBER), instance)
          when :type_integer
            check_compiled_type("integer", Internal::TypeChecks.single?(instance, TYPE_INTEGER), instance)
          when :type_string
            check_compiled_type("string", Internal::TypeChecks.single?(instance, TYPE_STRING), instance)
          when :typed_number
            if instance.is_a?(Numeric) && !instance.is_a?(Complex)
              check_number(operand, instance)
            else
              check_compiled_type("number", false, instance)
            end
          when :typed_integer
            if instance.is_a?(Numeric) && !instance.is_a?(Complex)
              integer = instance.finite? && instance.to_i == instance
              check_compiled_type("integer", integer, instance)
              check_number(operand, instance)
            else
              check_compiled_type("integer", false, instance)
            end
          when :typed_string
            if instance.is_a?(String)
              check_string(operand, instance)
            else
              check_compiled_type("string", false, instance)
            end
          when :typed_array
            if instance.is_a?(Array)
              result = check_array(operand, instance, evaluation)
              return Evaluation.invalid if !@errors && (!result.valid? || @error_count != before)
              evaluation = evaluation.merge(result)
            else
              check_compiled_type("array", false, instance)
            end
          when :typed_object
            if instance.is_a?(Hash)
              result = check_object(operand, instance, evaluation)
              return Evaluation.invalid if !@errors && (!result.valid? || @error_count != before)
              evaluation = evaluation.merge(result)
            else
              check_compiled_type("object", false, instance)
            end
          when :types
            check_compiled_types(operand, instance)
          when :enum
            add_error("enum") { Internal::ErrorMessage.enum } unless operand.any? { |candidate| json_equal?(candidate, instance) }
          when :const
            add_error("const") { Internal::ErrorMessage.const } unless json_equal?(operand, instance)
          when :allOf, :anyOf, :oneOf, :not, :conditional
            result = check_combiner(opcode, operand, instance)
            return Evaluation.invalid if !@errors && (!result.valid? || @error_count != before)
            evaluation = evaluation.merge(result)
          when :number
            check_number(operand, instance) if instance.is_a?(Numeric) && !instance.is_a?(Complex)
          when :string
            check_string(operand, instance) if instance.is_a?(String)
          when :array
            if instance.is_a?(Array)
              result = check_array(operand, instance, evaluation)
              return Evaluation.invalid if !@errors && (!result.valid? || @error_count != before)
              evaluation = evaluation.merge(result)
            end
          when :object
            if instance.is_a?(Hash)
              result = check_object(operand, instance, evaluation)
              return Evaluation.invalid if !@errors && (!result.valid? || @error_count != before)
              evaluation = evaluation.merge(result)
            end
          else
            raise "unknown VM instruction #{opcode.inspect}"
          end
          instruction_index += 2
        end
        (@error_count == before) ? evaluation : Evaluation.invalid
      ensure
        leave_scope if entered_scope
      end

      private def leave_scope
        @dynamic_scope.pop
      end

      private def recursive_target(program, rules)
        target = reference_target(program, rules)
        return target unless rules.fragment == "" && target.recursive_anchor?

        @dynamic_scope&.each do |resource|
          @budget&.checkpoint
          compiled = @compiler.compile(resource.root)
          return compiled if compiled.recursive_anchor?
        end
        target
      end

      private def dynamic_target(program, rules)
        target = reference_target(program, rules)
        fragment = rules.fragment
        return target if fragment.nil? || fragment.empty? || fragment.start_with?("/")

        return target unless target.dynamic_anchor == fragment

        Array(@dynamic_scope).each do |resource|
          @budget&.checkpoint
          dynamic = @graph.dynamic_anchor(resource, fragment)
          return @compiler.compile(dynamic) if dynamic
        end
        target
      end

      private def valid_reference?(source, target, instance)
        instances = active_instances(source)
        return true if instances.key?(instance) || @native_references&.reference_active?(source, instance)

        instances[instance] = true
        activated = true
        evaluate_valid(target, instance)
      ensure
        instances&.delete(instance) if activated
      end

      private def reference_target(program, rules)
        references = (@resolved_references ||= {}.compare_by_identity)
        references.fetch(rules) { references[rules] = @compiler.resolve(program, rules.value) }
      end

      private def evaluate_ref(source, rules, instance)
        target = reference_target(source, rules)
        evaluate_reference(source, target, instance, "$ref")
      rescue ResolutionError => error
        unresolved_reference("$ref", error)
      end

      private def evaluate_recursive_ref(source, rules, instance)
        evaluate_reference(source, recursive_target(source, rules), instance, "$recursiveRef")
      rescue ResolutionError => error
        unresolved_reference("$recursiveRef", error)
      end

      private def evaluate_dynamic_ref(source, rules, instance)
        evaluate_reference(source, dynamic_target(source, rules), instance, "$dynamicRef")
      rescue ResolutionError => error
        unresolved_reference("$dynamicRef", error)
      end

      private def evaluate_reference(source, target, instance, keyword)
        instances = active_instances(source)
        return Evaluation.valid if instances.key?(instance) || @native_references&.reference_active?(source, instance)

        instances[instance] = true
        activated = true
        evaluate_at(target, instance, MISSING_SEGMENT, keyword)
      ensure
        instances&.delete(instance) if activated
      end

      private def unresolved_reference(keyword, error)
        add_error(keyword, error.message, append_keyword: false)
        Evaluation.invalid
      end

      private def active_instances(program)
        active = (@active ||= {}.compare_by_identity)
        active[program] ||= {}.compare_by_identity
      end

      private def check_compiled_type(name, valid, value)
        add_error("type") { Internal::ErrorMessage.type(name, value) } unless valid
      end

      private def check_compiled_types(rules, value)
        instance_mask = instance_type_mask(value, integer: (rules.mask & TYPE_INTEGER) != 0)
        return unless (rules.mask & instance_mask).zero?

        add_error("type") { Internal::ErrorMessage.type(rules.names, value) }
      end

      private def instance_type_mask(value, integer:)
        Internal::TypeChecks.instance_mask(value, integer: integer)
      end

      private def integer?(value)
        Internal::TypeChecks.integer?(value)
      end

      private def check_number(rules, value)
        mask = rules.mask
        actual = (mask & MULTIPLE_OF).zero? ? value : number_state.decimal(value)
        if (mask & MAXIMUM) != 0 && actual > rules.maximum
          add_error("maximum") { Internal::ErrorMessage.numeric_limit("maximum", rules.maximum) }
        end
        if (mask & MINIMUM) != 0 && actual < rules.minimum
          add_error("minimum") { Internal::ErrorMessage.numeric_limit("minimum", rules.minimum) }
        end
        if (mask & EXCLUSIVE_MAXIMUM) != 0 && actual >= rules.exclusive_maximum
          add_error("exclusiveMaximum") do
            Internal::ErrorMessage.numeric_limit("exclusiveMaximum", rules.exclusive_maximum)
          end
        end
        if (mask & EXCLUSIVE_MINIMUM) != 0 && actual <= rules.exclusive_minimum
          add_error("exclusiveMinimum") do
            Internal::ErrorMessage.numeric_limit("exclusiveMinimum", rules.exclusive_minimum)
          end
        end
        return if (mask & MULTIPLE_OF).zero?

        divisor = rules.multiple_of
        valid = valid_multiple?(rules, value)
        add_error("multipleOf") { Internal::ErrorMessage.multiple_of(divisor) } unless valid
      end

      private def check_string(rules, value)
        length = value.length
        if rules.max_length && length > rules.max_length
          add_error("maxLength") { Internal::ErrorMessage.size("maxLength", rules.max_length, length) }
        end
        if rules.min_length && length < rules.min_length
          add_error("minLength") { Internal::ErrorMessage.size("minLength", rules.min_length, length) }
        end
        if rules.pattern && !ecma_regexp(rules.pattern).match?(value)
          add_error("pattern") { Internal::ErrorMessage.pattern(rules.pattern) }
        end
        if rules.format && (@validate_format || rules.format_assertion) && !rules.format.call(value)
          add_error("format") { Internal::ErrorMessage.format(rules.format.name) }
        end
        check_content(rules, value) if @validate_content && (rules.decode_base64 || rules.parse_json)
      rescue RegexpError
        add_error("pattern") { Internal::ErrorMessage.invalid_pattern(rules.pattern) }
      end

      private def check_content(rules, value)
        decoded = rules.decode_base64 ? Base64.strict_decode64(value) : value
        return unless rules.parse_json

        JSON.parse(decoded)
      rescue ArgumentError, JSON::ParserError
        keyword = rules.decode_base64 ? "contentEncoding" : "contentMediaType"
        add_error(keyword) do
          (keyword == "contentEncoding") ? Internal::ErrorMessage.content_encoding : Internal::ErrorMessage.content_media_type
        end
      end

      private def valid_array?(rules, value)
        length = value.length
        return false unless valid_container_bounds?(length, rules.max_items, rules.min_items)
        return false if rules.unique && !unique_items?(value)

        valid_array_children?(rules, value, length) { |child, item| evaluate_valid(child, item) }
      end

      private def valid_object?(rules, value)
        length = value.length
        return false unless valid_container_bounds?(length, rules.max_properties, rules.min_properties)
        return false unless valid_required_keys?(rules.required, value)

        valid_object_children?(rules, value) { |child, item| evaluate_valid(child, item) }
      end

      private def check_object(rules, value, prior_evaluation)
        evaluation = nil
        if rules.max_properties && value.length > rules.max_properties
          return Evaluation.invalid unless @errors

          add_error("maxProperties") do
            Internal::ErrorMessage.size("maxProperties", rules.max_properties, value.length)
          end
        end
        if rules.min_properties && value.length < rules.min_properties
          return Evaluation.invalid unless @errors

          add_error("minProperties") do
            Internal::ErrorMessage.size("minProperties", rules.min_properties, value.length)
          end
        end
        if (required = rules.required)
          required.each do |name|
            @budget&.checkpoint
            next if value.key?(name)
            return Evaluation.invalid unless @errors

            add_error("required") { Internal::ErrorMessage.required(name) }
          end
        end

        properties = rules.properties
        patterns = rules.patterns
        value.each do |name, property_value|
          @budget&.checkpoint
          matched = false
          if (child = properties[name])
            matched = true
            valid = evaluate_child_at(child, property_value, name, "properties", name)
            return Evaluation.invalid if !valid && !@errors
            (evaluation ||= tracked_evaluation).record_property(name)
          end
          if patterns
            patterns.each do |pattern, child|
              @budget&.checkpoint
              next unless ecma_regexp(pattern).match?(name)
              matched = true
              valid = evaluate_child_at(child, property_value, name, "patternProperties", pattern)
              return Evaluation.invalid if !valid && !@errors
              (evaluation ||= tracked_evaluation).record_property(name)
            end
          end
          if !matched && (additional = rules.additional)
            valid = evaluate_child_at(additional, property_value, name, "additionalProperties")
            return Evaluation.invalid if !valid && !@errors
            (evaluation ||= tracked_evaluation).record_property(name)
          end
        end

        if (property_names = rules.property_names)
          value.each_key do |name|
            @budget&.checkpoint
            valid = evaluate_child_at(property_names, name, name, "propertyNames")
            return Evaluation.invalid if !valid && !@errors
          end
        end
        if (dependencies = rules.dependencies)
          dependencies.each do |name, dependency|
            @budget&.checkpoint
            next unless value.key?(name)
            if dependency.is_a?(Array)
              dependency.each do |required_name|
                @budget&.checkpoint
                unless value.key?(required_name)
                  return Evaluation.invalid unless @errors

                  add_error("dependencies") { Internal::ErrorMessage.dependent_required(name, required_name) }
                end
              end
            else
              result = evaluate_at(dependency, value, MISSING_SEGMENT, "dependencies", name)
              if result.valid? && !result.evaluated_properties.empty?
                result.evaluated_properties.each do |property|
                  @budget&.checkpoint
                  (evaluation ||= tracked_evaluation).record_property(property)
                end
              end
            end
          end
        end
        if (dependent_required = rules.dependent_required)
          dependent_required.each do |name, required_names|
            @budget&.checkpoint
            next unless value.key?(name)
            required_names.each do |required_name|
              @budget&.checkpoint
              unless value.key?(required_name)
                return Evaluation.invalid unless @errors

                add_error("dependentRequired") { Internal::ErrorMessage.dependent_required(name, required_name) }
              end
            end
          end
        end
        if (dependent_schemas = rules.dependent_schemas)
          dependent_schemas.each do |name, child|
            @budget&.checkpoint
            next unless value.key?(name)
            result = evaluate_at(child, value, MISSING_SEGMENT, "dependentSchemas", name)
            if result.valid? && !result.evaluated_properties.empty?
              result.evaluated_properties.each do |property|
                @budget&.checkpoint
                (evaluation ||= tracked_evaluation).record_property(property)
              end
            end
          end
        end
        if (unevaluated = rules.unevaluated)
          prior_properties = prior_evaluation.evaluated_properties
          value.each_key do |name|
            @budget&.checkpoint
            next if prior_properties.include?(name) || evaluation&.evaluated_properties&.include?(name)

            valid = evaluate_child_at(unevaluated, value[name], name, "unevaluatedProperties")
            return Evaluation.invalid if !valid && !@errors
            (evaluation ||= tracked_evaluation).record_property(name)
          end
        end
        return Evaluation.valid unless evaluation

        evaluation
      end

      private def check_combiner(opcode, operand, value)
        evaluation = Evaluation.valid
        case opcode
        when :allOf
          index = 0
          while index < operand.length
            @budget&.checkpoint
            evaluation = evaluation.merge(evaluate_at(operand[index], value, MISSING_SEGMENT, "allOf", index))
            index += 1
          end
        when :anyOf
          matches = 0
          index = 0
          while index < operand.length
            @budget&.checkpoint
            result = trial(operand[index], value)
            if result.valid?
              matches += 1
              evaluation = evaluation.merge(result)
            end
            index += 1
          end
          add_error("anyOf") { Internal::ErrorMessage.any_of } if matches.zero?
        when :oneOf
          matches = 0
          matched_evaluation = nil
          index = 0
          while index < operand.length
            @budget&.checkpoint
            result = trial(operand[index], value)
            if result.valid?
              matches += 1
              matched_evaluation = result
            end
            index += 1
          end
          if matches == 1
            evaluation = evaluation.merge(matched_evaluation)
          else
            add_error("oneOf") { Internal::ErrorMessage.one_of(matches) }
          end
        when :not
          add_error("not") { Internal::ErrorMessage.not } if trial(operand, value).valid?
        when :conditional
          condition = trial(operand.condition, value)
          condition_valid = condition.valid?
          evaluation = evaluation.merge(condition) if condition_valid
          if condition_valid && operand.then_branch
            evaluation = evaluation.merge(evaluate_at(operand.then_branch, value, MISSING_SEGMENT, "then"))
          elsif !condition_valid && operand.else_branch
            evaluation = evaluation.merge(evaluate_at(operand.else_branch, value, MISSING_SEGMENT, "else"))
          end
        end
        evaluation
      end

      private def trial(program, value)
        saved_errors = @errors
        saved_count = @error_count
        saved_instance_path = @instance_path
        @errors = nil
        @error_count = 0
        # Trials retain annotations, but discard errors. Descendants therefore
        # need neither instance nor schema paths until the trial has returned.
        if saved_instance_path
          saved_schema_path = @schema_path
          @instance_path = nil
          @schema_path = nil
        end
        evaluate(program, value)
      ensure
        @errors = saved_errors
        @error_count = saved_count
        @native_reports[0] = self if @native_reports
        if saved_instance_path
          @instance_path = saved_instance_path
          @schema_path = saved_schema_path
        end
      end

      private def evaluate_at(program, instance, instance_segment, schema_segment, child_segment = MISSING_SEGMENT)
        return evaluate(program, instance) unless @instance_path

        evaluate_at_with_path(program, instance, instance_segment, schema_segment, child_segment)
      end

      private def evaluate_child_at(program, instance, instance_segment, schema_segment, child_segment = MISSING_SEGMENT)
        return evaluate_at(program, instance, instance_segment, schema_segment, child_segment).valid? if @errors

        valid = evaluate_valid(program, instance)
        @error_count += 1 unless valid
        valid
      end

      private def evaluate_at_with_path(program, instance, instance_segment, schema_segment, child_segment)
        @instance_path << instance_segment unless instance_segment.equal?(MISSING_SEGMENT)
        @schema_path << schema_segment
        @schema_path << child_segment unless child_segment.equal?(MISSING_SEGMENT)
        evaluate(program, instance)
      ensure
        @schema_path.pop unless child_segment.equal?(MISSING_SEGMENT)
        @schema_path.pop
        @instance_path.pop unless instance_segment.equal?(MISSING_SEGMENT)
      end

      private def add_error(keyword, message = nil, append_keyword: true)
        @error_count += 1
        return false unless @errors

        final_segment = append_keyword ? keyword : MISSING_SEGMENT
        @errors << ValidationError.new(
          keyword: keyword,
          instance_path: pointer(@instance_path),
          schema_path: pointer(@schema_path, final_segment),
          message: message || yield
        )
        false
      end

      private def number?(value)
        Internal::TypeChecks.number?(value)
      end

      private def pointer(path, final_segment = MISSING_SEGMENT)
        result = +""
        path.each { |segment| append_pointer_segment(result, segment) }
        append_pointer_segment(result, final_segment) unless final_segment.equal?(MISSING_SEGMENT)
        result
      end

      private def append_pointer_segment(pointer, segment)
        pointer << "/" << Internal::JsonPointer.escape(segment)
      end

      private_constant :MISSING_SEGMENT
    end
  end

  private_constant :VM
end
