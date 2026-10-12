# frozen_string_literal: true

module Schemurai
  # Raised when validation cannot finish within an application-supplied limit.
  # This is an incomplete evaluation, not a JSON Schema validation failure.
  class LimitExceeded < Error
    # Limit name, configured maximum and attempted count (or elapsed seconds).
    attr_reader :limit, :maximum, :attempted

    # Creates an interruption error without embedding the input or partial errors.
    def initialize(limit, maximum, attempted)
      @limit = limit
      @maximum = maximum
      @attempted = attempted
      super("validation exceeded #{limit} (maximum #{maximum}, attempted #{attempted})")
    end
  end
end
