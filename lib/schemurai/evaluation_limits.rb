# frozen_string_literal: true

require_relative "limit_budget"

module Schemurai
  module Internal
    # Limit policy shared by evaluators; error storage and scalar state stay local.
    module EvaluationLimits
      def validate(instance, max_errors: nil, timeout: nil, budget: nil)
        with_budget(max_errors, timeout, budget) { super(instance) }
      end

      def valid?(instance, max_errors: nil, timeout: nil, budget: nil)
        with_budget(max_errors, timeout, budget) { super(instance) }
      end

      private def with_budget(max_errors, timeout, budget)
        @budget = budget || LimitBudget.new(max_errors: max_errors, timeout: timeout)
        result = yield
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
    end
  end
end
