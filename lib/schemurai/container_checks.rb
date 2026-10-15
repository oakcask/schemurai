# frozen_string_literal: true

require_relative "error_message"
require_relative "value_equality"

module Schemurai
  module Internal
    module ContainerChecks
      module Bounds
        private def valid_container_bounds?(length, maximum, minimum)
          return false if maximum && length > maximum
          return false if minimum && length < minimum

          true
        end
      end

      module Required
        private def valid_required_keys?(required, value)
          return true unless required

          required.all? do |name|
            @budget&.checkpoint
            value.key?(name)
          end
        end
      end

      # Frames evaluate only container applicability, bounds and uniqueness.
      # Child schema execution remains with the native traversal.
      class Frame
        include Bounds

        def initialize(rules, value, budget, required)
          @rules = rules
          @value = value
          @budget = budget
          @required = required != 0
        end

        def valid?
          return !@required unless container?

          length = @value.length
          return false unless valid_container_bounds?(length, maximum, minimum)

          valid_tail?(length)
        end

        def check(step)
          case step
          when 2
            violated = @value.length > maximum
            violated ? false : true
          when 3
            violated = @value.length < minimum
            violated ? false : true
          when 4 then unique?
          when 6
            @value.each do |name, _value|
              @budget&.checkpoint
              @rules.properties[name]
            end
            true
          when 5
            # The VM evaluates this gate even when no additional schema exists.
            _additional = @value.length > @rules.items.length
            true
          else raise "unknown container assertion"
          end
        end

        def message(keyword, _rescued)
          case keyword
          when "type" then ErrorMessage.type(type_name, @value)
          when "maxItems", "maxProperties" then ErrorMessage.size(keyword, maximum, @value.length)
          when "minItems", "minProperties" then ErrorMessage.size(keyword, minimum, @value.length)
          when "uniqueItems" then ErrorMessage.unique_items
          else raise "unknown container diagnostic"
          end
        end

        private def valid_tail?(_length) = true
      end

      class ArrayFrame < Frame
        include ValueEquality
        include UniqueItems

        def container? = @value.is_a?(Array)

        private def type_name = "array"
        private def maximum = @rules.max_items
        private def minimum = @rules.min_items
        private def unique?
          return true unless @rules.unique

          unique_items?(@value)
        end

        private def valid_tail?(length)
          return false unless unique?

          length > @rules.items.length if @rules.items_list
          true
        end
      end

      class LimitedArrayFrame < ArrayFrame
        include ValueEquality::Checkpoints
      end

      class ObjectFrame < Frame
        include Required

        def container? = @value.is_a?(Hash)

        def check(step)
          return super if step < 7
          return true unless @rules.required

          if step == 7
            # Preserve errors from malformed required operands before iteration.
            @rules.required.each { break }
            return true
          end
          if Array === @rules.required
            return check_required_name(@rules.required[step - 8])
          end
          @rules.required.each_with_index do |name, index|
            next unless index == step - 8

            return check_required_name(name)
          end
          true
        end

        def message(keyword, rescued)
          return ErrorMessage.required(@required_name) if keyword == "required"

          super
        end

        private def type_name = "object"
        private def maximum = @rules.max_properties
        private def minimum = @rules.min_properties
        private def valid_tail?(_length) = valid_required_keys?(@rules.required, @value)
        private def check_required_name(name)
          @required_name = name
          @budget&.checkpoint
          @value.key?(name) || false
        end
      end
    end
  end
end
