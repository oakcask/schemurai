# frozen_string_literal: true

module Schemurai
  module Native
    # Render native diagnostic output using the messages shared by every backend.
    # The instance remains an original Ruby object; this layer never traverses it.
    module Diagnostics
      TYPE_NAMES = {1 => "null", 2 => "boolean", 3 => "object", 4 => "array", 5 => "number", 6 => "integer", 7 => "string",
                    17 => "number", 18 => "integer", 20 => "string", 22 => "array", 24 => "object"}.freeze
      ATTRIBUTES = {"maximum" => :maximum, "minimum" => :minimum, "exclusiveMaximum" => :exclusive_maximum, "exclusiveMinimum" => :exclusive_minimum,
                    "maxLength" => :max_length, "minLength" => :min_length, "maxItems" => :max_items, "minItems" => :min_items,
                    "maxProperties" => :max_properties, "minProperties" => :min_properties}.freeze
      private_constant :TYPE_NAMES, :ATTRIBUTES

      module_function def error(row)
        keyword, instance_path, schema_path, opcode, operand, instance, detail = row
        ValidationError.new(keyword: keyword, instance_path: instance_path, schema_path: schema_path,
          message: message(keyword, opcode, operand, instance, detail))
      end

      module_function def message(keyword, opcode, operand, instance, detail) # rubocop:disable Metrics/MethodLength
        messages = Internal::ErrorMessage
        case keyword
        when "falseSchema" then messages.false_schema
        when "type" then messages.type((opcode == 8) ? operand.names : TYPE_NAMES.fetch(opcode), instance)
        when "const" then messages.const
        when "enum" then messages.enum
        when "maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum"
          messages.numeric_limit(keyword, operand.public_send(ATTRIBUTES.fetch(keyword)))
        when "multipleOf" then messages.multiple_of(operand.multiple_of)
        when "maxLength", "minLength", "maxItems", "minItems", "maxProperties", "minProperties"
          messages.size(keyword, operand.public_send(ATTRIBUTES.fetch(keyword)), detail)
        when "pattern" then messages.pattern(operand.pattern)
        when "format" then messages.format(operand.format.name)
        when "contentEncoding" then messages.content_encoding
        when "contentMediaType" then messages.content_media_type
        when "uniqueItems" then messages.unique_items
        when "required" then messages.required(instance)
        when "dependencies", "dependentRequired" then messages.dependent_required(operand, instance)
        when "contains" then messages.contains(detail, operand.min_contains, operand.max_contains)
        when "anyOf" then messages.any_of
        when "oneOf" then messages.one_of(detail)
        when "not" then messages.not
        else raise "unknown native diagnostic #{keyword.inspect}"
        end
      end
      private_class_method :message
    end
  end
end
