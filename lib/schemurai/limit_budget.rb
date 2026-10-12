# frozen_string_literal: true

module Schemurai
  module Internal
    # Mutable state owned by one validation call, including native/VM fallback.
    class LimitBudget
      CHECK_INTERVAL = 256

      def self.validate_options!(max_errors, timeout)
        valid_errors = max_errors.nil? || (max_errors.is_a?(Integer) && max_errors >= 0)
        unless valid_errors
          raise ArgumentError, "max_errors must be a nonnegative Integer or nil"
        end
        valid_timeout = timeout.nil? || ((timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout >= 0 && timeout.to_f.finite?)
        unless valid_timeout
          raise ArgumentError, "timeout must be finite nonnegative seconds or nil"
        end
      end

      def initialize(max_errors: nil, timeout: nil)
        @max_errors = max_errors
        @timeout = timeout
        @errors = 0
        @checks = 0
        if timeout
          @started = monotonic_time
          @deadline = @started + timeout
          check_deadline!
        end
      end

      # Synchronous polling only; never inject exceptions into another thread.
      def checkpoint
        return unless @deadline

        @checks += 1
        check_deadline! if (@checks % CHECK_INTERVAL).zero?
      end

      def check_deadline!
        return unless @deadline

        now = monotonic_time
        raise LimitExceeded.new(:timeout, @timeout, now - @started) if now >= @deadline
      end

      # Ruby retains the original deadline through native execution and fallback.
      def native_duration
        check_deadline!
        @deadline && [@deadline - monotonic_time, 0.0].max
      end

      def native_max_errors
        @max_errors && [@max_errors, (1 << (0.size * 8)) - 1].min
      end

      def raise_native_limit(kind, attempted)
        if kind == 2
          raise LimitExceeded.new(:timeout, @timeout, monotonic_time - @started)
        end
        raise LimitExceeded.new(:max_errors, @max_errors, attempted)
      end

      # Check before constructing the next message and JSON Pointers.
      def reserve_error
        checkpoint
        attempted = @errors + 1
        raise LimitExceeded.new(:max_errors, @max_errors, attempted) if @max_errors && attempted > @max_errors

        @errors = attempted
      end

      private def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
