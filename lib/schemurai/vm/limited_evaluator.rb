# frozen_string_literal: true

require_relative "../limits"
require_relative "../limit_budget"
require_relative "evaluator"

module Schemurai
  module VM
    # VM execution with invocation-local limits; no Ruby evaluator delegation.
    class LimitedEvaluator < Evaluator
      def validate(instance, limits: nil, budget: nil)
        @budget = budget || Internal::LimitBudget.new(limits)
        @budget.start_diagnostics
        result = super(instance)
        @budget.check_deadline!
        result
      ensure
        @budget = nil
      end

      def valid?(instance, limits: nil, budget: nil)
        @budget = budget || Internal::LimitBudget.new(limits)
        result = super(instance)
        @budget.check_deadline!
        result
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
        @budget.checkpoint
        return unless @budget.work_limited?

        @budget.evaluations(1 + node.code.length / 2)
        scalar_work(instance) unless instance.is_a?(Hash) || instance.is_a?(Array)
      end

      private def add_error(keyword, message = nil, append_keyword: true, &block)
        @budget.reserve_error if @errors
        result = super
        @budget.record_error(@errors.last) if @errors
        result
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
        return unless @budget.work_limited?

        prefix = node.prefix_items
        items = node.items
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

      private def object_scan(rules, value)
        return unless @budget.work_limited?

        patterns = rules.patterns || {}
        required = rules.required || []
        @budget.evaluations(value.length * (1 + patterns.length) + required.length)
        required.each { |name| scalar_work(name) }
        value.each_key { |key| scalar_work(key, multiplier: 1 + patterns.length) }
        [rules.dependencies, rules.dependent_required, rules.dependent_schemas].compact.each do |dependencies|
          dependencies.each do |name, dependency|
            scalar_work(name)
            @budget.evaluations(1 + (dependency.is_a?(Array) ? dependency.length : 0))
            dependency.each { |required_name| scalar_work(required_name) } if dependency.is_a?(Array)
          end
        end
      end

      private def valid_string?(node, value)
        @budget.check_deadline!
        scalar_work(value)
        result = super
        @budget.check_deadline!
        result
      end

      private def check_string(node, value)
        @budget.check_deadline!
        scalar_work(value)
        result = super
        @budget.check_deadline!
        result
      end

      private def decimal(value)
        @budget.check_deadline!
        scalar_work(value)
        result = super
        @budget.check_deadline!
        result
      end

      private def instance_type_mask(value, integer:)
        scalar_work(value)
        super
      end

      private def ecma_regexp(pattern)
        @budget.check_deadline!
        scalar_work(pattern)
        result = super
        @budget.check_deadline!
        result
      end

      private def valid_content?(schema, value)
        @budget.check_deadline!
        scalar_work(value)
        result = super
        @budget.check_deadline!
        result
      end

      private def check_content(schema, value)
        @budget.check_deadline!
        scalar_work(value)
        result = super
        @budget.check_deadline!
        result
      end

      private def unique_items?(values)
        @budget.evaluations(values.length)
        super
      end

      private def json_equal?(left, right)
        @budget.checkpoint
        return super unless @budget.work_limited?

        @budget.evaluations(1 + ((left.is_a?(Hash) || left.is_a?(Array)) ? left.length : 0))
        scalar_work(left)
        scalar_work(right)
        left.each_key { |key| scalar_work(key) } if left.is_a?(Hash)
        super
      end

      private def json_fingerprint(value)
        @budget.checkpoint
        return super unless @budget.work_limited?

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
        return unless @budget.work_limited?

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
