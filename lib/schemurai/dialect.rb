# frozen_string_literal: true

module Schemurai
  module Internal
    class Dialect
      TYPE = 1
      ENUM = 2
      COMBINER = 4
      NUMBER = 8
      STRING = 16
      ARRAY = 32
      OBJECT = 64

      Keyword = Data.define(:mask, :subschema_shape) do
        def initialize(mask:, subschema_shape: nil)
          super
        end
      end

      class << self
        def register(dialect, default: false)
          registry[normalize_uri(dialect.uri)] = dialect
          @default = dialect if default
          dialect
        end

        def resolve(uri = nil)
          return @default if uri.nil?

          registry[normalize_uri(uri)]
        end

        private def registry
          @registry ||= {}
        end

        private def normalize_uri(uri)
          uri.to_s.delete_suffix("#")
        end
      end

      attr_reader :name, :uri, :keywords

      def initialize(name:, uri:, keywords:, ref_siblings:, format_assertion: false)
        @name = name
        @uri = uri
        @keywords = keywords.freeze
        @ref_siblings = ref_siblings
        @format_assertion = format_assertion
        freeze
      end

      def ref_siblings?
        @ref_siblings
      end

      def format_assertion?
        @format_assertion
      end

      def keyword_mask(schema)
        schema.each_key.reduce(0) do |mask, keyword|
          mask | (keywords[keyword]&.mask || 0)
        end
      end

      def each_subschema(schema)
        return enum_for(__method__, schema) unless block_given?
        return unless schema.is_a?(Hash)
        return if schema.key?("$ref") && !ref_siblings?

        schema.each do |keyword, value|
          specification = keywords[keyword]
          next unless specification&.subschema_shape

          case specification.subschema_shape
          when :single
            yield value, [keyword] if schema?(value)
          when :single_or_list
            if value.is_a?(Array)
              value.each_with_index { |child, index| yield child, [keyword, index] if schema?(child) }
            elsif schema?(value)
              yield value, [keyword]
            end
          when :list
            Array(value).each_with_index { |child, index| yield child, [keyword, index] if schema?(child) }
          when :map
            value.each { |name, child| yield child, [keyword, name] if schema?(child) } if value.is_a?(Hash)
          when :dependencies
            if value.is_a?(Hash)
              value.each do |name, child|
                yield child, [keyword, name] if schema?(child)
              end
            end
          end
        end
      end

      private def schema?(value)
        value == true || value == false || value.is_a?(Hash)
      end
    end
  end

  private_constant :Internal
end
