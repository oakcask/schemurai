# frozen_string_literal: true

module Schemurai
  module Internal
    module Decimal
      module_function def parse(value)
        Rational(value.to_s)
      end
    end
  end
end
