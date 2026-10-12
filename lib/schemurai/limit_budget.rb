# frozen_string_literal: true

module Schemurai
  module Internal
    # Owned by one limited invocation, including discarded applicator trials.
    class LimitBudget
      EMPTY_ERROR_BYTES = '{"keyword":"","instance_path":"","schema_path":"","message":""}'.bytesize
      CHECK_INTERVAL = 256

      def initialize(limits)
        @limits = limits
        @errors = 0
        @bytes = 0
        @evaluations = 0
        @checks = 0
        if limits.max_duration
          @started = monotonic_time
          @deadline = @started + limits.max_duration
          check_deadline!
        end
      end

      def evaluations(amount = 1)
        return unless work_limited?

        checkpoint
        @evaluations = consume(:max_evaluations, @evaluations, amount)
      end

      def work_limited? = !@limits.max_evaluations.nil?

      # Poll only at synchronous checkpoints; never inject asynchronous exceptions.
      def checkpoint
        return unless @deadline

        @checks += 1
        check_deadline! if (@checks % CHECK_INTERVAL).zero?
      end

      def check_deadline!
        return unless @deadline

        now = monotonic_time
        raise LimitExceeded.new(:max_duration, @limits.max_duration, now - @started) if now >= @deadline
      end

      # Ruby and Rust clocks need not share an epoch. The native call receives
      # remaining seconds; Ruby retains the original deadline through fallback.
      def native_duration
        check_deadline!
        @deadline && [@deadline - monotonic_time, 0.0].max
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
        if kind == 4
          raise LimitExceeded.new(:max_duration, @limits.max_duration, monotonic_time - @started)
        end
        name = [:max_errors, :max_output_bytes, :max_evaluations].fetch(kind - 1)
        raise LimitExceeded.new(name, @limits.public_send(name), attempted)
      end

      # Check the count before constructing the next message and JSON Pointers.
      def reserve_error
        checkpoint
        @errors = consume(:max_errors, @errors, 1)
        @bytes = consume(:max_output_bytes, @bytes, EMPTY_ERROR_BYTES + ((@errors > 1) ? 1 : 0))
      end

      # Count JSON bytes without allocating a serialized copy of the diagnostic.
      # Escaping follows JSON's default compact String representation.
      def record_error(error)
        checkpoint
        fields = [error.keyword, error.instance_path, error.schema_path, error.message]
        evaluations(fields.sum(&:bytesize)) if work_limited?
        return if @limits.max_output_bytes.nil?

        fields.each do |field|
          field.each_byte do |byte|
            checkpoint
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

      private def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
