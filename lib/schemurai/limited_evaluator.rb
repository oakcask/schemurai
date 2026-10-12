# frozen_string_literal: true

require_relative "limit_exceeded"
require_relative "limit_budget"
require_relative "evaluator"

module Schemurai
  module Internal
    # Ruby evaluation with invocation-local limits.
    class LimitedEvaluator < Evaluator
      def validate(instance, max_errors: nil, timeout: nil, budget: nil)
        @budget = budget || LimitBudget.new(max_errors: max_errors, timeout: timeout)
        errors = []
        each_error(instance) do |error|
          errors << error
        end
        @budget.check_deadline!
        Result.new(errors)
      ensure
        @budget = nil
      end

      def valid?(instance, max_errors: nil, timeout: nil, budget: nil)
        @budget = budget || LimitBudget.new(max_errors: max_errors, timeout: timeout)
        result = super(instance)
        @budget.check_deadline!
        result
      ensure
        @budget = nil
      end

      private def evaluate(node, instance)
        @budget.checkpoint
        super
      end

      private def evaluate_valid(node, instance)
        @budget.checkpoint
        super
      end

      private def add_error(keyword, message = nil, append_keyword: true, &block)
        @budget.reserve_error if @error_callback
        super
      end

      private def valid_string?(node, value)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def check_string(node, value)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def decimal(value)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def ecma_regexp(pattern)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def valid_content?(schema, value)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def check_content(schema, value)
        @budget.check_deadline!
        result = super
        @budget.check_deadline!
        result
      end

      private def json_equal?(left, right)
        @budget.checkpoint
        super
      end

      private def json_fingerprint(value)
        @budget.checkpoint
        super
      end
    end
  end
end
