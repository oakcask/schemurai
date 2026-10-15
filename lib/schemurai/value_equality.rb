# frozen_string_literal: true

require_relative "unique_items"

module Schemurai
  module Internal
    # Ruby method order for VM/native value comparisons. This traverses values,
    # not schema instructions, and retains custom collection/equality methods.
    module ValueEquality
      private def json_equal?(left, right)
        if left.is_a?(Numeric) && !left.is_a?(Complex)
          return right.is_a?(Numeric) && !right.is_a?(Complex) && left == right
        end
        return false unless left.instance_of?(right.class)

        case left
        when Hash
          left.length == right.length && left.all? do |key, value|
            @budget&.checkpoint
            right.key?(key) && json_equal?(value, right[key])
          end
        when Array
          return false unless left.length == right.length

          index = 0
          while index < left.length
            @budget&.checkpoint
            return false unless json_equal?(left[index], right[index])
            index += 1
          end
          true
        else
          left == right
        end
      end

      module Checkpoints
        private def json_equal?(left, right)
          @budget.checkpoint
          super
        end

        private def json_fingerprint(value)
          @budget.checkpoint
          super
        end
      end

      class Runtime
        include ValueEquality
        include UniqueItems

        def initialize(budget)
          @budget = budget
        end

        def evaluate(operation, operand, instance)
          case operation
          when 0 then json_equal?(operand, instance)
          when 1 then operand.any? { |candidate| json_equal?(candidate, instance) }
          when 2 then unique_items?(instance)
          else raise "unknown equality operation"
          end
        end
      end

      class LimitedRuntime < Runtime
        include Checkpoints
      end
    end
  end
end
