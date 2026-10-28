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
          if test_case.mutation
            repaired = Corpus.new.copy(test_case.instance)
            Corpus.new.replace(repaired, test_case.mutation.fetch("path"), test_case.mutation.fetch("before"))
            raise "repair did not restore validity: #{test_case.id}" unless validator.valid?(repaired)
          end
          valid = validator.valid?(test_case.instance)
          result = validator.validate(test_case.instance)
          raise "valid?/validate disagreement: #{test_case.id}" unless valid == result.valid?
          unless test_case.expected.nil? || valid == test_case.expected
            raise "unexpected verdict: #{test_case.id}: expected #{test_case.expected}, got #{valid}"
          end
          errors = result.errors.map do |error|
            {"instance_path" => error.instance_path, "schema_path" => error.schema_path, "keyword" => error.keyword}
          end
          unless test_case.expected_errors.nil? || errors == test_case.expected_errors
            raise "unexpected errors: #{test_case.id}: expected #{test_case.expected_errors.inspect}, got #{errors.inspect}"
          end

          # Messages are implementation wording; paths, keywords and ordering
          # remain observable. Match the existing oracle's message policy.
          [valid, errors]
        end
        raise "backend mismatch: #{test_case.id}: #{observations.inspect}" unless observations.values.uniq.length == 1

        observations.values.first
      end
    end
  end
end
