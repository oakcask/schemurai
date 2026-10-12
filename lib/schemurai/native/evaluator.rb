# frozen_string_literal: true

require_relative "../vm/limited_evaluator"
require "schemurai_native"
require_relative "diagnostics"

module Schemurai
  module Native
    class Evaluator
      def backend = :native

      def initialize(graph, compiler, root, content: false, format: false, compiled: nil)
        @graph = graph
        @compiler = compiler
        @root = root
        @content = content
        @format = format
        @compiled = compiled || Program.new(root, compiler, format, content)
        @program = @compiled.runner(root)
        @vm = VM::Evaluator.new(graph, compiler, root, content: content, format: format)
      end

      def valid?(instance, max_errors: nil, timeout: nil)
        if !max_errors.nil? || !timeout.nil?
          budget = Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
          result = @program.valid_with_budget(instance, budget)
          budget.check_deadline!
          return result.nil? ? limited_vm.valid?(instance, budget: budget) : result
        end
        result = @program.valid?(instance)
        result.nil? ? @vm.valid?(instance) : result
      end

      def validate(instance, max_errors: nil, timeout: nil)
        if !max_errors.nil? || !timeout.nil?
          budget = Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
          rows = @program.diagnostics_with_budget(instance, budget)
          return limited_vm.validate(instance, budget: budget) if rows.nil?

          errors = rows.map do |row|
            budget.reserve_error
            Diagnostics.error(row)
          end
          budget.check_deadline!
          return Result.new(errors)
        end
        rows = @program.diagnostics(instance)
        return @vm.validate(instance) if rows.nil?

        Result.new(rows.empty? ? rows : rows.map { |row| Diagnostics.error(row) })
      end
      private def limited_vm
        VM::LimitedEvaluator.new(@graph, @compiler, @root, content: @content, format: @format)
      end
    end
  end

  private_constant :Native
end
