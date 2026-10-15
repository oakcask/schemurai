# frozen_string_literal: true

require_relative "../evaluation"
require_relative "../error_message"

module Schemurai
  module Internal
    module ContainerChecks
      module ArrayDiagnostics
        private def check_array(rules, value, prior_evaluation)
          evaluation = nil
          if rules.max_items && value.length > rules.max_items
            return Evaluation.invalid unless @errors

            array_error("maxItems", rules, value)
          end
          if rules.min_items && value.length < rules.min_items
            return Evaluation.invalid unless @errors

            array_error("minItems", rules, value)
          end
          if rules.unique && !unique_items?(value)
            return Evaluation.invalid unless @errors

            array_error("uniqueItems", rules, value)
          end

          if (prefix_items = rules.prefix_items)
            prefix_items.each_with_index do |child, index|
              @budget&.checkpoint
              break if index >= value.length
              valid = evaluate_child_at(child, value[index], index, "prefixItems", index)
              return Evaluation.invalid if !valid && !@errors
              (evaluation ||= tracked_evaluation).record_item(index)
            end
          end

          items = rules.items
          if rules.items_list
            items.each_with_index do |child, index|
              @budget&.checkpoint
              break if index >= value.length
              valid = evaluate_child_at(child, value[index], index, "items", index)
              return Evaluation.invalid if !valid && !@errors
              (evaluation ||= tracked_evaluation).record_item(index)
            end
            if value.length > items.length && (additional = rules.additional)
              (items.length...value.length).each do |index|
                @budget&.checkpoint
                valid = evaluate_child_at(additional, value[index], index, "additionalItems")
                return Evaluation.invalid if !valid && !@errors
                (evaluation ||= tracked_evaluation).record_item(index)
              end
            end
          elsif items
            start = rules.prefix_items&.length || 0
            (start...value.length).each do |index|
              @budget&.checkpoint
              valid = evaluate_child_at(items, value[index], index, "items")
              return Evaluation.invalid if !valid && !@errors
              (evaluation ||= tracked_evaluation).record_item(index)
            end
          end

          if (contains = rules.contains)
            matched = nil
            index = 0
            while index < value.length
              @budget&.checkpoint
              (matched ||= []) << index if trial(contains, value[index]).valid?
              index += 1
            end
            matched_count = matched ? matched.length : 0
            unless matched_count.between?(rules.min_contains, rules.max_contains)
              return Evaluation.invalid unless @errors

              array_error("contains", rules, value, matched_count)
            end
            if matched
              matched.each { |index| (evaluation ||= tracked_evaluation).record_item(index) }
            end
          end

          if (unevaluated = rules.unevaluated)
            prior_items = prior_evaluation.evaluated_items
            index = 0
            while index < value.length
              @budget&.checkpoint
              if prior_items.include?(index) || evaluation&.evaluated_items&.include?(index)
                index += 1
                next
              end
              valid = evaluate_child_at(unevaluated, value[index], index, "unevaluatedItems")
              return Evaluation.invalid if !valid && !@errors
              (evaluation ||= tracked_evaluation).record_item(index)
              index += 1
            end
          end
          return Evaluation.valid unless evaluation

          evaluation
        end

        private def array_error(keyword, rules, value, actual = nil)
          add_error(keyword) do
            case keyword
            when "maxItems" then ErrorMessage.size(keyword, rules.max_items, value.length)
            when "minItems" then ErrorMessage.size(keyword, rules.min_items, value.length)
            when "uniqueItems" then ErrorMessage.unique_items
            when "contains" then ErrorMessage.contains(actual, rules.min_contains, rules.max_contains)
            end
          end
        end
      end
    end
  end
end
