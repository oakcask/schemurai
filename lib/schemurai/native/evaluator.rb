# frozen_string_literal: true

require_relative "../vm/evaluator"
require "schemurai_native"
require_relative "diagnostics"

module Schemurai
  module Native
    class Evaluator
      def backend = :native

      def initialize(graph, compiler, root, content: false, format: false)
        @program = Program.new(root, compiler, format, content)
        @vm = VM::Evaluator.new(graph, compiler, root, content: content, format: format)
      end

      def valid?(instance)
        result = @program.valid?(instance)
        result.nil? ? @vm.valid?(instance) : result
      end

      def validate(instance)
        rows = @program.diagnostics(instance)
        return @vm.validate(instance) if rows.nil?

        Result.new(rows.empty? ? rows : rows.map { |row| Diagnostics.error(row) })
      end
    end
  end

  private_constant :Native
end
