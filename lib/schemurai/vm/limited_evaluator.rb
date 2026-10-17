# frozen_string_literal: true

require_relative "../limit_exceeded"
require_relative "../evaluation_limits"
require_relative "evaluator"

module Schemurai
  module VM
    # VM execution with invocation-local limits; no Ruby evaluator delegation.
    class LimitedEvaluator < Evaluator
      include Internal::ValueEquality::Checkpoints
      include Internal::StringChecks::TimedRegexps
      include Internal::EvaluationLimits

      private def add_error(keyword, message = nil, append_keyword: true, &block)
        @budget.reserve_error if @errors
        super
      end

      private def number_state
        state = super
        state.budget = @budget
        state
      end
    end
  end
end
