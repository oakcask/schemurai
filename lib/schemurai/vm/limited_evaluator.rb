# frozen_string_literal: true

require_relative "../limit_exceeded"
require_relative "../limit_budget"
require_relative "evaluator"

module Schemurai
  module VM
    # VM execution with invocation-local limits; no Ruby evaluator delegation.
    class LimitedEvaluator < Evaluator
      def validate(instance, max_errors: nil, timeout: nil, budget: nil)
        @budget = budget || Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
        result = super(instance)
        @budget.check_deadline!
        result
      ensure
        @budget = nil
      end

      def valid?(instance, max_errors: nil, timeout: nil, budget: nil)
        @budget = budget || Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
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
        @budget.reserve_error if @errors
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

      private def number_state
        state = super
        state.budget = @budget
        state
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
