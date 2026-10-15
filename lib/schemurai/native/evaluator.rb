# frozen_string_literal: true

require_relative "../decimal"
require_relative "../number_checks"
require_relative "../string_checks"
require_relative "../value_equality"
require_relative "../container_checks"
require_relative "../type_checks"
require_relative "../vm/compiler"
require_relative "../evaluation_pool"
require_relative "../limit_budget"
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
        @number_state = Internal::NumberChecks::State.new
        @regexps = {}
        @scope_state = []
        @report_state = [nil, Internal::EvaluationPool.new]
        @reference_state = []
        @active_state = {}.compare_by_identity
        @program = @compiled.runner(root)
        @program.share_scalar_state(@number_state, @regexps, @scope_state, @reference_state, @active_state, @report_state)
        @unresolved = @compiled.unresolved_references?
      end

      def valid?(instance, max_errors: nil, timeout: nil)
        refresh_unresolved
        if !max_errors.nil? || !timeout.nil?
          budget = Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
          result = @program.valid_with_budget(instance, budget)
          budget.check_deadline!
          return result
        end
        @program.valid?(instance)
      end

      def validate(instance, max_errors: nil, timeout: nil)
        refresh_unresolved
        if !max_errors.nil? || !timeout.nil?
          budget = Internal::LimitBudget.new(max_errors: max_errors, timeout: timeout)
          rows = @program.diagnostics_with_budget(instance, budget)

          errors = (rows == false) ? nil : rows.map do |row|
            budget.reserve_error
            Diagnostics.error(row)
          end
          budget.check_deadline!
          return Result.new(errors)
        end
        rows = @program.diagnostics(instance)

        return Result.new(nil) if rows == false

        Result.new(rows.empty? ? rows : rows.map { |row| Diagnostics.error(row) })
      end
      private def refresh_unresolved
        while @unresolved && @graph_size != @graph.nodes.length
          graph_size = @graph.nodes.length
          compiled = Program.new(@root, @compiler, @format, @content)
          @program = compiled.runner(@root)
          @program.share_scalar_state(@number_state, @regexps, @scope_state, @reference_state, @active_state, @report_state)
          @compiled = compiled
          @unresolved = @compiled.unresolved_references?
          @graph_size = graph_size
        end
      end
    end
  end

  private_constant :Native
end
