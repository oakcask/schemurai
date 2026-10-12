# frozen_string_literal: true

module Schemurai
  module Internal
    # Owned by one limited invocation, including discarded applicator trials.
    class LimitBudget
      EMPTY_ERROR_BYTES = '{"keyword":"","instance_path":"","schema_path":"","message":""}'.bytesize

      def initialize(limits)
        @limits = limits
        @errors = 0
        @bytes = 0
        @evaluations = 0
      end

      def evaluations(amount = 1)
        @evaluations = consume(:max_evaluations, @evaluations, amount)
      end

      def start_diagnostics
        return if @diagnostics_started

        @bytes = consume(:max_output_bytes, @bytes, 2)
        @diagnostics_started = true
      end

      def native_caps
        word_max = (1 << (0.size * 8)) - 1
        remaining = @limits.max_evaluations && @limits.max_evaluations - @evaluations
        [@limits.max_errors, @limits.max_output_bytes, remaining].map { |value| value && [value, word_max].min }
      end

      def raise_native_limit(kind, attempted)
        name = [:max_errors, :max_output_bytes, :max_evaluations].fetch(kind - 1)
        raise LimitExceeded.new(name, @limits.public_send(name), attempted)
      end

      # Check the count before constructing the next message and JSON Pointers.
      def reserve_error
        @errors = consume(:max_errors, @errors, 1)
        @bytes = consume(:max_output_bytes, @bytes, EMPTY_ERROR_BYTES + ((@errors > 1) ? 1 : 0))
      end

      # Count JSON bytes without allocating a serialized copy of the diagnostic.
      # Escaping follows JSON's default compact String representation.
      def record_error(error)
        fields = [error.keyword, error.instance_path, error.schema_path, error.message]
        evaluations(fields.sum(&:bytesize))
        return if @limits.max_output_bytes.nil?

        fields.each do |field|
          field.each_byte do |byte|
            size = if byte == 34 || byte == 92 || [8, 9, 10, 12, 13].include?(byte)
              2
            elsif byte < 32
              6
            else
              1
            end
            @bytes = consume(:max_output_bytes, @bytes, size)
          end
        end
      end

      private def consume(name, current, amount)
        attempted = current + amount
        maximum = @limits.public_send(name)
        raise LimitExceeded.new(name, maximum, attempted) if maximum && attempted > maximum

        attempted
      end
    end
  end
end
