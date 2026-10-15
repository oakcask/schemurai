# frozen_string_literal: true

module Schemurai
  module Native
    # Render native diagnostic output using the messages shared by every backend.
    # The instance remains an original Ruby object; this layer never traverses it.
    module Diagnostics
      TYPE_NAMES = {Protocol::OP_TYPE_NULL => "null", Protocol::OP_TYPE_BOOLEAN => "boolean", Protocol::OP_TYPE_OBJECT => "object",
                    Protocol::OP_TYPE_ARRAY => "array", Protocol::OP_TYPE_NUMBER => "number", Protocol::OP_TYPE_INTEGER => "integer",
                    Protocol::OP_TYPE_STRING => "string", Protocol::OP_TYPED_NUMBER => "number", Protocol::OP_TYPED_INTEGER => "integer",
                    Protocol::OP_TYPED_STRING => "string", Protocol::OP_TYPED_ARRAY => "array", Protocol::OP_TYPED_OBJECT => "object"}.freeze
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
        when "type" then messages.type((opcode == Protocol::OP_TYPES) ? operand.names : TYPE_NAMES.fetch(opcode), instance)
        when "const" then messages.const
        when "enum" then messages.enum
        when "maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum"
          messages.numeric_limit(keyword, operand.public_send(ATTRIBUTES.fetch(keyword)))
        when "multipleOf" then messages.multiple_of(operand.multiple_of)
        when "maxLength", "minLength", "maxItems", "minItems", "maxProperties", "minProperties"
          messages.size(keyword, operand.public_send(ATTRIBUTES.fetch(keyword)), detail)
        when "pattern" then (detail == 1) ? messages.invalid_pattern(operand.pattern) : messages.pattern(operand.pattern)
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
        when "$ref", "$recursiveRef", "$dynamicRef" then operand
        else raise "unknown native diagnostic #{keyword.inspect}"
        end
      end
      private_class_method :message
    end
  end
end
