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

          all_keys_present?(required, value)
        end

        private def all_keys_present?(names, value)
          names.all? do |name|
            @budget&.checkpoint
            value.key?(name)
          end
        end

        private def valid_dependency_keys?(entries, value)
          return true unless entries

          entries.each do |name, names|
            @budget&.checkpoint
            next unless value.key?(name)
            return false unless all_keys_present?(names, value)
          end
          true
        end
      end

      module Contains
        private def valid_contains?(rules, value, &block)
          if rules.count_contains
            matches = value.count(&block)
            return false if matches < rules.min_contains || matches > rules.max_contains
          else
            return false unless value.any?(&block)
          end
          true
        end
      end

      module ArrayChildren
        include Contains

        private def valid_array_children?(rules, value, length)
          if (prefix_items = rules.prefix_items)
            prefix_items.each_with_index do |child, index|
              @budget&.checkpoint
              break if index >= length
              return false unless yield(child, value[index])
            end
          end

          items = rules.items
          if rules.items_list
            items.each_with_index do |child, index|
              @budget&.checkpoint
              break if index >= length
              return false unless yield(child, value[index])
            end
            if length > items.length && (additional = rules.additional)
              index = items.length
              while index < length
                @budget&.checkpoint
                return false unless yield(additional, value[index])
                index += 1
              end
            end
          elsif items
            start = rules.prefix_items&.length || 0
            index = start
            while index < length
              @budget&.checkpoint
              return false unless yield(items, value[index])
              index += 1
            end
          end

          if (contains = rules.contains)
            return false unless valid_contains?(rules, value) { |item| yield(contains, item) }
          end
          true
        end
      end

      # Frames preserve Ruby container operations. Compiled child schema
      # execution remains with the native traversal.
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

      class CallbackArrayFrame < ArrayFrame
        def initialize(rules, value, budget, required, callback)
          super(rules, value, budget, required)
          @callback = callback
        end
      end

      class ContainsFrame < CallbackArrayFrame
        include Contains

        private def valid_tail?(length)
          return false unless super

          valid_contains?(@rules, @value) { |item| @callback.call(item) }
        end
      end

      class LimitedContainsFrame < ContainsFrame
        include ValueEquality::Checkpoints
      end

      class ArrayChildrenFrame < CallbackArrayFrame
        include ArrayChildren

        private def valid_tail?(length)
          return false unless unique?

          valid_array_children?(@rules, @value, length) { |child, item| @callback.evaluate_child(child, item) }
        end
      end

      class LimitedArrayChildrenFrame < ArrayChildrenFrame
        include ValueEquality::Checkpoints
      end

      class ObjectFrame < Frame
        include Required

        def container? = @value.is_a?(Hash)

        def check(step)
          return super if step < 7

          if step == 7
            return true unless @rules.required

            # Preserve errors from malformed required operands before iteration.
            @rules.required.each { break }
            return true
          end
          index = step - 8
          count = iteration_length(@rules.required)
          if index < count
            return check_required_name(iteration_name(@rules.required, index))
          end
          check_dependency(index - count)
        end

        def message(keyword, rescued)
          return ErrorMessage.required(@required_name) if keyword == "required"
          if keyword == "dependencies" || keyword == "dependentRequired"
            return ErrorMessage.dependent_required(@dependency_name, @required_name)
          end

          super
        end

        private def type_name = "object"
        private def maximum = @rules.max_properties
        private def minimum = @rules.min_properties
        private def valid_tail?(_length)
          valid_required_keys?(@rules.required, @value) &&
            valid_dependency_keys?(@rules.dependencies, @value) &&
            valid_dependency_keys?(@rules.dependent_required, @value)
        end

        private def iteration_length(names)
          (Array === names || Hash === names) ? names.length : 0
        end

        private def iteration_name(names, at)
          return names[at] if Array === names

          names.each_with_index { |name, index| return name if index == at }
        end

        private def dependency_steps
          @dependency_steps ||= [@rules.dependencies, @rules.dependent_required].flat_map do |entries|
            (entries || []).flat_map do |name, names|
              [[:trigger, name], [:prepare, names]] + Array.new(iteration_length(names)) { |index| [:key, names, index] }
            end
          end
        end

        private def check_dependency(index)
          kind, operand, at = dependency_steps.fetch(index)
          case kind
          when :trigger
            @dependency_name = operand
            @budget&.checkpoint
            @value.key?(operand) || false
          when :prepare
            operand.each { break }
            true
          when :key then check_required_name(iteration_name(operand, at))
          end
        end
        private def check_required_name(name)
          @required_name = name
          @budget&.checkpoint
          @value.key?(name) || false
        end
      end
    end
  end
end
