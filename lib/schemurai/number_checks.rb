# frozen_string_literal: true

require_relative "decimal"
require_relative "type_checks"

module Schemurai
  module Internal
    module NumberChecks
      MAXIMUM = 1 << 0
      MINIMUM = 1 << 1
      EXCLUSIVE_MAXIMUM = 1 << 2
      EXCLUSIVE_MINIMUM = 1 << 3
      MULTIPLE_OF = 1 << 4

      class State
        CACHE_LIMIT = 16
        private_constant :CACHE_LIMIT

        attr_writer :budget

        def decimal(value)
          @budget&.check_deadline!
          result = cached_decimal(value)
          @budget&.check_deadline!
          result
        end

        private def cached_decimal(value)
          return value if value.is_a?(Integer) || value.is_a?(Rational)

          decimals = (@decimals ||= {})
          return decimals[value] if decimals.key?(value)

          decimals.clear if decimals.length >= CACHE_LIMIT
          decimals[value] = Decimal.parse(value)
        end

        def multiple?(rules, value)
          results = (@multiple_results ||= {}.compare_by_identity)
          values = (results[rules] ||= {})
          return values[value] if values.key?(value)

          values.clear if values.length >= CACHE_LIMIT
          divisor = rules.multiple_of
          values[value] = divisor.positive? && decimal(value).remainder(divisor).zero?
        end
      end

      module_function def actual(rules, value, state)
        (rules.mask & MULTIPLE_OF).zero? ? value : state.decimal(value)
      end

      module_function def bound?(actual, bit, limit)
        violated = case bit
        when MAXIMUM then actual > limit
        when MINIMUM then actual < limit
        when EXCLUSIVE_MAXIMUM then actual >= limit
        when EXCLUSIVE_MINIMUM then actual <= limit
        else raise "unknown numeric bound"
        end
        violated ? false : true
      end

      # Both the VM and native validity frames use the same ordered rules.
      module Evaluation
        private def number_state
          @number_state ||= State.new
        end

        private def valid_number?(rules, value)
          mask = rules.mask
          actual = (mask & MULTIPLE_OF).zero? ? value : number_state.decimal(value)
          return false if (mask & MAXIMUM) != 0 && actual > rules.maximum
          return false if (mask & MINIMUM) != 0 && actual < rules.minimum
          return false if (mask & EXCLUSIVE_MAXIMUM) != 0 && actual >= rules.exclusive_maximum
          return false if (mask & EXCLUSIVE_MINIMUM) != 0 && actual <= rules.exclusive_minimum
          return true if (mask & MULTIPLE_OF).zero?

          valid_multiple?(rules, value)
        end

        private def valid_multiple?(rules, value)
          number_state.multiple?(rules, value)
        end
      end

      # One native numeric instruction owns this frame while Rust yields between
      # reached assertions. No instance method runs during construction.
      class Frame
        include Evaluation

        def initialize(rules, value, state)
          @rules = rules
          @value = value
          @number_state = state
        end

        def numeric? = TypeChecks.number?(@value)
        def integral? = TypeChecks.integral?(@value)

        def valid?(required)
          return required.zero? unless numeric?
          if required == TypeChecks::INTEGER
            return false unless integral?
          end

          valid_number?(@rules, @value)
        end

        def prepare
          @actual = NumberChecks.actual(@rules, @value, @number_state)
          true
        end

        def check(bit)
          case bit
          when MAXIMUM then NumberChecks.bound?(@actual, bit, @rules.maximum)
          when MINIMUM then NumberChecks.bound?(@actual, bit, @rules.minimum)
          when EXCLUSIVE_MAXIMUM then NumberChecks.bound?(@actual, bit, @rules.exclusive_maximum)
          when EXCLUSIVE_MINIMUM then NumberChecks.bound?(@actual, bit, @rules.exclusive_minimum)
          when MULTIPLE_OF then @number_state.multiple?(@rules, @value)
          else raise "unknown numeric assertion"
          end
        end
      end
    end
  end
end
