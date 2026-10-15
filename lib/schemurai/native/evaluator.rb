# frozen_string_literal: true

require_relative "../decimal"
require_relative "../vm/limited_evaluator"
require_relative "../ecma_regexp"
require_relative "../json_pointer"
require "schemurai_native"
require_relative "diagnostics"
require_relative "null_numeric"

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
        @graph_size = @graph.nodes.length
        @compiled = compiled || Program.new(root, compiler, format, content)
        @program = @compiled.runner(root)
        @unresolved = @compiled.unresolved_references?
        @vm = VM::Evaluator.new(graph, compiler, root, content: content, format: format)
      end

      def valid?(instance, max_errors: nil, timeout: nil)
        refresh_unresolved
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
        refresh_unresolved
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

      private def refresh_unresolved
        while @unresolved && @graph_size != @graph.nodes.length
          graph_size = @graph.nodes.length
          compiled = Program.new(@root, @compiler, @format, @content)
          @program = compiled.runner(@root)
          @compiled = compiled
          @unresolved = @compiled.unresolved_references?
          @graph_size = graph_size
        end
      end
    end
  end

  private_constant :Native
end
