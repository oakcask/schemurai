# frozen_string_literal: true

module Schemurai
  module Internal
    module TypeChecks
      NULL = 1 << 0
      BOOLEAN = 1 << 1
      OBJECT = 1 << 2
      ARRAY = 1 << 3
      NUMBER = 1 << 4
      INTEGER = 1 << 5
      STRING = 1 << 6
      BITS = {"null" => NULL, "boolean" => BOOLEAN, "object" => OBJECT, "array" => ARRAY,
              "number" => NUMBER, "integer" => INTEGER, "string" => STRING}.freeze

      module_function def number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end

      module_function def integer?(value)
        number?(value) && integral?(value)
      end

      module_function def integral?(value)
        value.finite? && value.to_i == value
      end

      module_function def single?(value, mask)
        case mask
        when NULL then value.nil?
        when BOOLEAN then value == true || value == false
        when OBJECT then value.is_a?(Hash)
        when ARRAY then value.is_a?(Array)
        when NUMBER then number?(value)
        when INTEGER then integer?(value)
        when STRING then value.is_a?(String)
        else false
        end
      end

      # The VM's union opcode classifies in this order, even for a one-name union.
      module_function def instance_mask(value, integer:)
        return NULL if value.nil?
        return BOOLEAN if value == true || value == false
        return OBJECT if value.is_a?(Hash)
        return ARRAY if value.is_a?(Array)
        return STRING if value.is_a?(String)
        return 0 unless number?(value)
        return NUMBER unless integer

        integral?(value) ? NUMBER | INTEGER : NUMBER
      end

      module_function def valid?(value, mask, union)
        union ? (mask & instance_mask(value, integer: (mask & INTEGER) != 0)) != 0 : single?(value, mask)
      end
    end
  end
end
