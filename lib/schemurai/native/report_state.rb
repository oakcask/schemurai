# frozen_string_literal: true

require_relative "../evaluation_pool"

module Schemurai
  module Internal
    # Shared by native collectors and VM compatibility traversals in one runner.
    class NativeReportState
      attr_accessor :current_collector

      def evaluation_pool
        @evaluation_pool ||= EvaluationPool.new
      end

      def buffers_used? = @evaluation_pool&.used? || false

      def reset(paths)
        @current_collector&.__send__(:native_clear_collection, paths)
        @current_collector = nil
        @evaluation_pool&.reset
      end
    end
  end
end
