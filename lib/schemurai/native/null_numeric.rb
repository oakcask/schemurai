# frozen_string_literal: true

module Schemurai
  module Native
    # Native traversal selects one reached assertion and its comparison mode.
    # Ruby dispatch preserves the exception and method visibility for nil.
    module NullNumeric
      module_function def valid?(value, bit, decimal)
        actual = if decimal && !value.is_a?(Integer) && !value.is_a?(Rational)
          Internal::Decimal.parse(value)
        else
          value
        end
        case bit
        when Protocol::MAXIMUM, Protocol::MINIMUM, Protocol::EXCLUSIVE_MAXIMUM, Protocol::EXCLUSIVE_MINIMUM
          Internal::NumberChecks.bound?(actual, bit, nil)
        when Protocol::MULTIPLE_OF then nil.positive? && actual.remainder(nil).zero?
        else raise "unknown null numeric assertion"
        end
      end
    end
  end
end
