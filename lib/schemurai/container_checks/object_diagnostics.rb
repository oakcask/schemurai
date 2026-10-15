# frozen_string_literal: true

require_relative "../evaluation"
require_relative "../error_message"

module Schemurai
  module Internal
    module ContainerChecks
      module ObjectDiagnostics
        MISSING_SEGMENT = Object.new.freeze

        private def check_object(rules, value, prior_evaluation)
          evaluation = nil
          if rules.max_properties && value.length > rules.max_properties
            return Evaluation.invalid unless collecting_object_errors?

            object_error("maxProperties", rules, value)
          end
          if rules.min_properties && value.length < rules.min_properties
            return Evaluation.invalid unless collecting_object_errors?

            object_error("minProperties", rules, value)
          end
          if (required = rules.required)
            required.each do |name|
              object_budget&.checkpoint
              next if value.key?(name)
              return Evaluation.invalid unless collecting_object_errors?

              object_error("required", rules, value, name)
            end
          end

          properties = rules.properties
          patterns = rules.patterns
          value.each do |name, property_value|
            object_budget&.checkpoint
            matched = false
            if (child = properties[name])
              matched = true
              valid = evaluate_child_at(child, property_value, name, "properties", name)
              return Evaluation.invalid if !valid && !collecting_object_errors?
              (evaluation ||= tracked_evaluation).record_property(name)
            end
            if patterns
              patterns.each do |pattern, child|
                object_budget&.checkpoint
                next unless ecma_regexp(pattern).match?(name)
                matched = true
                valid = evaluate_child_at(child, property_value, name, "patternProperties", pattern)
                return Evaluation.invalid if !valid && !collecting_object_errors?
                (evaluation ||= tracked_evaluation).record_property(name)
              end
            end
            if !matched && (additional = rules.additional)
              valid = evaluate_child_at(additional, property_value, name, "additionalProperties")
              return Evaluation.invalid if !valid && !collecting_object_errors?
              (evaluation ||= tracked_evaluation).record_property(name)
            end
          end

          if (property_names = rules.property_names)
            value.each_key do |name|
              object_budget&.checkpoint
              valid = evaluate_child_at(property_names, name, name, "propertyNames")
              return Evaluation.invalid if !valid && !collecting_object_errors?
            end
          end
          if (dependencies = rules.dependencies)
            dependencies.each do |name, dependency|
              object_budget&.checkpoint
              next unless value.key?(name)
              if dependency.is_a?(Array)
                dependency.each do |required_name|
                  object_budget&.checkpoint
                  unless value.key?(required_name)
                    return Evaluation.invalid unless collecting_object_errors?

                    object_error("dependencies", rules, value, name, required_name)
                  end
                end
              else
                result = evaluate_at(dependency, value, MISSING_SEGMENT, "dependencies", name)
                if result.valid? && !result.evaluated_properties.empty?
                  result.evaluated_properties.each do |property|
                    object_budget&.checkpoint
                    (evaluation ||= tracked_evaluation).record_property(property)
                  end
                end
              end
            end
          end
          if (dependent_required = rules.dependent_required)
            dependent_required.each do |name, required_names|
              object_budget&.checkpoint
              next unless value.key?(name)
              required_names.each do |required_name|
                object_budget&.checkpoint
                unless value.key?(required_name)
                  return Evaluation.invalid unless collecting_object_errors?

                  object_error("dependentRequired", rules, value, name, required_name)
                end
              end
            end
          end
          if (dependent_schemas = rules.dependent_schemas)
            dependent_schemas.each do |name, child|
              object_budget&.checkpoint
              next unless value.key?(name)
              result = evaluate_at(child, value, MISSING_SEGMENT, "dependentSchemas", name)
              if result.valid? && !result.evaluated_properties.empty?
                result.evaluated_properties.each do |property|
                  object_budget&.checkpoint
                  (evaluation ||= tracked_evaluation).record_property(property)
                end
              end
            end
          end
          if (unevaluated = rules.unevaluated)
            prior_properties = prior_evaluation.evaluated_properties
            value.each_key do |name|
              object_budget&.checkpoint
              next if prior_properties.include?(name) || evaluation&.evaluated_properties&.include?(name)

              valid = evaluate_child_at(unevaluated, value[name], name, "unevaluatedProperties")
              return Evaluation.invalid if !valid && !collecting_object_errors?
              (evaluation ||= tracked_evaluation).record_property(name)
            end
          end
          return Evaluation.valid unless evaluation

          evaluation
        end

        private def object_budget = @budget
        private def collecting_object_errors? = @errors

        private def object_error(keyword, rules, value, name = nil, required_name = nil)
          add_error(keyword) do
            case keyword
            when "maxProperties" then ErrorMessage.size(keyword, rules.max_properties, value.length)
            when "minProperties" then ErrorMessage.size(keyword, rules.min_properties, value.length)
            when "required" then ErrorMessage.required(name)
            when "dependencies", "dependentRequired" then ErrorMessage.dependent_required(name, required_name)
            end
          end
        end
      end
    end
  end
end
