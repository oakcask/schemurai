# frozen_string_literal: true

require_relative "../../lib/schemurai"
require_relative "corpus"

module SchemuraiBenchmark
  module RealWorld
    class Checker
      def initialize(backends: %i[ruby vm])
        @backends = backends
        @validators = {}
      end

      def validators(schema)
        @validators[schema] ||= @backends.to_h do |backend|
          [backend, Schemurai.compile(schema, backend: backend)]
        end
      end

      def check(test_case)
        observations = validators(test_case.schema).transform_values do |validator|
          valid = validator.valid?(test_case.instance)
          result = validator.validate(test_case.instance)
          raise "valid?/validate disagreement: #{test_case.id}" unless valid == result.valid?
          unless test_case.expected.nil? || valid == test_case.expected
            raise "unexpected verdict: #{test_case.id}: expected #{test_case.expected}, got #{valid}"
          end

          # Messages are implementation wording; paths, keywords and ordering
          # remain observable. Match the existing oracle's message policy.
          [valid, result.errors.map { |error| [error.instance_path, error.schema_path, error.keyword] }]
        end
        raise "backend mismatch: #{test_case.id}: #{observations.inspect}" unless observations.values.uniq.length == 1

        observations.values.first
      end
    end
  end
end
