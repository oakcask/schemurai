# frozen_string_literal: true

require_relative "limits"
require_relative "limit_budget"
require_relative "evaluator"

module Schemurai
  module Internal
    # Ruby evaluation with invocation-local limits.
    class LimitedEvaluator < Evaluator
      def validate(instance, limits:)
        @budget = LimitBudget.new(limits)
        @budget.start_diagnostics
        errors = []
        each_error(instance) do |error|
          @budget.record_error(error)
          errors << error
        end
        Result.new(errors)
      ensure
        @budget = nil
      end

      def valid?(instance, limits:)
        @budget = LimitBudget.new(limits)
        super(instance)
      ensure
        @budget = nil
      end

      private def evaluate(node, instance)
        visit_node(node, instance)
        super
      end

      private def evaluate_valid(node, instance)
        visit_node(node, instance)
        super
      end

      private def visit_node(node, instance)
        schema = node.schema
        @budget.evaluations(1 + (schema.is_a?(Hash) ? schema.length : 0))
        scalar_work(instance) unless instance.is_a?(Hash) || instance.is_a?(Array)
      end

      private def add_error(keyword, message = nil, append_keyword: true, &block)
        @budget.reserve_error if @error_callback
        super
      end

      private def valid_array?(node, value)
        array_scan(node, value)
        super
      end

      private def check_array(node, value, prior_evaluation)
        array_scan(node, value)
        super
      end

      private def array_scan(node, value)
        schema = node.schema
        prefix = schema["prefixItems"]
        items = schema["items"]
        @budget.evaluations(value.length + (prefix.is_a?(Array) ? prefix.length : 0) + (items.is_a?(Array) ? items.length : 0))
      end

      private def valid_object?(node, value)
        object_scan(node, value)
        super
      end

      private def check_object(node, value, prior_evaluation)
        object_scan(node, value)
        super
      end

      private def object_scan(node, value)
        schema = node.schema
        patterns = schema.fetch("patternProperties", {})
        @budget.evaluations(value.length * (1 + patterns.length) + Array(schema["required"]).length)
        Array(schema["required"]).each { |name| scalar_work(name) }
        value.each_key { |key| scalar_work(key, multiplier: 1 + patterns.length) }
        %w[dependencies dependentRequired dependentSchemas].each do |keyword|
          schema.fetch(keyword, {}).each do |name, dependency|
            scalar_work(name)
            @budget.evaluations(1 + (dependency.is_a?(Array) ? dependency.length : 0))
            dependency.each { |required_name| scalar_work(required_name) } if dependency.is_a?(Array)
          end
        end
      end

      private def valid_string?(node, value)
        scalar_work(value)
        super
      end

      private def check_string(node, value)
        scalar_work(value)
        super
      end

      private def decimal(value)
        scalar_work(value)
        super
      end

      private def type?(value, type)
        scalar_work(type)
        scalar_work(value)
        super
      end

      private def ecma_regexp(pattern)
        scalar_work(pattern)
        super
      end

      private def valid_content?(schema, value)
        scalar_work(value)
        super
      end

      private def check_content(schema, value)
        scalar_work(value)
        super
      end

      private def unique_items?(values)
        @budget.evaluations(values.length)
        super
      end

      private def json_equal?(left, right)
        @budget.evaluations(1 + ((left.is_a?(Hash) || left.is_a?(Array)) ? left.length : 0))
        scalar_work(left)
        scalar_work(right)
        left.each_key { |key| scalar_work(key) } if left.is_a?(Hash)
        super
      end

      private def json_fingerprint(value)
        @budget.evaluations(1 + ((value.is_a?(Hash) || value.is_a?(Array)) ? value.length : 0))
        scalar_work(value)
        value.each_key { |key| scalar_work(key) } if value.is_a?(Hash)
        super
      end

      private def recursive_target(node, reference)
        @budget.evaluations(Array(@dynamic_scope).length)
        super
      end

      private def dynamic_target(node, reference)
        @budget.evaluations(Array(@dynamic_scope).length)
        super
      end

      private def append_pointer_segment(pointer, segment)
        scalar_work(segment)
        super
      end

      private def scalar_work(value, multiplier: 1)
        size = case value
        when String then value.bytesize
        when Integer then (value.bit_length + 7) / 8
        when Rational then (value.numerator.bit_length + value.denominator.bit_length + 7) / 8
        else 1
        end
        @budget.evaluations(size * multiplier)
      end
    end
  end
end
