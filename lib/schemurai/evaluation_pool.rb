# frozen_string_literal: true

require "set" # rubocop:disable Lint/RedundantRequireStatement -- Required on Ruby 3.4.
require_relative "evaluation"

module Schemurai
  module Internal
    class EvaluationBuffer
      attr_reader :evaluated_properties, :evaluated_items

      def initialize
        # Applicators can overlap. Array membership makes collecting and merging
        # their annotations quadratic in the number of instance locations.
        @evaluated_properties = Set.new
        @evaluated_items = Set.new
      end

      def valid? = true

      def reset
        @evaluated_properties.clear
        @evaluated_items.clear
        self
      end

      def record_property(name)
        @evaluated_properties.add(name)
        self
      end

      def record_item(index)
        @evaluated_items.add(index)
        self
      end

      def merge(other)
        return Evaluation.invalid unless other.valid?

        properties = other.evaluated_properties
        items = other.evaluated_items
        @evaluated_properties.merge(properties) unless properties.empty?
        @evaluated_items.merge(items) unless items.empty?
        self
      end
    end

    class EvaluationPool
      def initialize
        @buffers = []
        @index = 0
      end

      def reset
        @index = 0
      end

      def used? = !@buffers.empty?

      def acquire
        index = @index
        @index += 1
        (@buffers[index] ||= EvaluationBuffer.new).reset
      end
    end
  end
end
