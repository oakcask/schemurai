# frozen_string_literal: true

module Schemurai
  # Raised when validation cannot finish within an application-supplied limit.
  # This is an incomplete evaluation, not a JSON Schema validation failure.
  class LimitExceeded < Error
    # Limit name, configured maximum and the work/output count that would exceed it.
    attr_reader :limit, :maximum, :attempted

    # Creates an interruption error without embedding the input or partial errors.
    def initialize(limit, maximum, attempted)
      @limit = limit
      @maximum = maximum
      @attempted = attempted
      super("validation exceeded #{limit} (maximum #{maximum}, attempted #{attempted})")
    end
  end

  # Immutable per-call validation limits. nil means unlimited; zero is allowed.
  # Output bytes measure JSON.generate(result.errors.map(&:to_h)), including
  # array punctuation and JSON escaping. Evaluations are work units, not time.
  class Limits
    # The configured caps; each nil value disables that cap.
    attr_reader :max_errors, :max_output_bytes, :max_evaluations

    # Creates and freezes a limits object from nonnegative integers or nil.
    def initialize(max_errors: nil, max_output_bytes: nil, max_evaluations: nil)
      {max_errors: max_errors, max_output_bytes: max_output_bytes, max_evaluations: max_evaluations}.each do |name, value|
        next if value.nil?
        raise ArgumentError, "#{name} must be a nonnegative Integer or nil" if !value.is_a?(Integer) || value.negative?
      end
      @max_errors = max_errors
      @max_output_bytes = max_output_bytes
      @max_evaluations = max_evaluations
      freeze
    end

    # Returns whether any cap is configured.
    def enabled?
      !max_errors.nil? || !max_output_bytes.nil? || !max_evaluations.nil?
    end

    # Accepts a Limits object, a keyword Hash, or nil for unlimited evaluation.
    def self.coerce(value)
      return new if value.nil?
      return value if value.is_a?(self)
      return new(**value) if value.is_a?(Hash)

      raise ArgumentError, "limits must be a Schemurai::Limits, Hash or nil"
    end
  end
end
