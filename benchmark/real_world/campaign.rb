# frozen_string_literal: true

require_relative "checker"
require_relative "mutator"

module SchemuraiBenchmark
  module RealWorld
    class Campaign
      def self.replay(record)
        id = record.fetch("id")
        instance = record.fetch("instance")
        if record.fetch("representation", nil) == "shared"
          instance = Corpus.new.representation(instance, id.split("/").first, "shared")
        end
        Case.new(id, record.fetch("schema"), instance, record.fetch("expected"), [],
          record["mutation"], record["expected_errors"])
      end

      def initialize(seed:, size:, mutations:)
        raise ArgumentError, "mutations must be nonnegative" if mutations.negative?

        @seed = seed
        @size = size
        @mutations = mutations
      end

      def each_case
        return enum_for(__method__) unless block_given?

        Corpus.new.cases(seed: @seed, size: @size).each do |test_case|
          yield test_case
          next unless test_case.id.end_with?("/valid")

          mutator = Mutator.new(test_case.schema, seed: @seed)
          destroyer = DestructiveMutator.new(test_case, seed: @seed)
          @mutations.times do |index|
            yield destroyer.mutate(index)
            yield Case.new("#{test_case.id}/mutation=#{index}", test_case.schema,
              mutator.mutate(test_case.instance), nil)
          end
        end
      end

      def check(checker, artifact:)
        count = 0
        each_case do |test_case|
          record = {id: test_case.id, seed: @seed, size: @size, schema: test_case.schema,
                    instance: test_case.instance, expected: test_case.expected, status: "running",
                    mutation: test_case.mutation, expected_errors: test_case.expected_errors,
                    representation: test_case.id.end_with?("/shared") ? "shared" : "json"}
          # Save before entering a backend: crashes and process-level timeouts
          # must leave the active input available for replay too.
          File.write(artifact, JSON.pretty_generate(record) + "\n")
          begin
            checker.check(test_case)
          rescue => error
            record.merge!(status: "failed", error: "#{error.class}: #{error.message}")
            File.write(artifact, JSON.pretty_generate(record) + "\n")
            raise
          end
          count += 1
        end
        File.delete(artifact) if File.file?(artifact)
        count
      end
    end
  end
end
