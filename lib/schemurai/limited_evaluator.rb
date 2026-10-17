# frozen_string_literal: true

require_relative "limit_exceeded"
require_relative "evaluation_limits"
require_relative "evaluator"

module Schemurai
  module Internal
    # Ruby evaluation with invocation-local limits.
    class LimitedEvaluator < Evaluator
      include EvaluationLimits

      private def add_error(keyword, message = nil, append_keyword: true, &block)
        @budget.reserve_error if @error_callback
        super
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
