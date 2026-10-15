# frozen_string_literal: true

require "base64"
require "json"
require "ipaddr"
require_relative "ecma_regexp"
require_relative "error_message"

module Schemurai
  module Internal
    module StringChecks
      module Regexps
        private def ecma_regexp(pattern)
          regexps = regexp_cache
          return regexps[pattern] if regexps.key?(pattern)

          regexps[pattern] = EcmaRegexp.compile(pattern, @budget)
        end

        private def regexp_cache = (@regexps ||= {})
      end

      module TimedRegexps
        private def regexp_budget = @budget

        private def ecma_regexp(pattern)
          budget = regexp_budget
          budget.check_deadline!
          result = super
          budget.check_deadline!
          result
        end
      end

      module Evaluation
        private def valid_string?(rules, value)
          length = value.length
          return false if rules.max_length && length > rules.max_length
          return false if rules.min_length && length < rules.min_length
          return false if rules.pattern && !ecma_regexp(rules.pattern).match?(value)
          if rules.format && (@validate_format || rules.format_assertion)
            return false unless rules.format.call(value)
          end
          if @validate_content && (rules.decode_base64 || rules.parse_json)
            return valid_content?(rules, value)
          end

          true
        rescue RegexpError, IPAddr::InvalidAddressError
          false
        end

        private def valid_content?(rules, value)
          decoded = rules.decode_base64 ? Base64.strict_decode64(value) : value
          JSON.parse(decoded) if rules.parse_json
          true
        rescue ArgumentError, JSON::ParserError
          false
        end
      end

      class State
        include Regexps

        attr_reader :budget

        def ecma_regexp(pattern)
          @budget&.check_deadline!
          result = super
          @budget&.check_deadline!
          result
        end

        def initialize(regexps, budget)
          @regexps = regexps
          @budget = budget
        end
      end

      # Rust owns traversal and error limits; this frame retains arbitrary Ruby
      # length results and the VM's rescue state between reached assertions.
      class Frame
        include Evaluation

        def initialize(rules, value, state, flags)
          @rules = rules
          @value = value
          @state = state
          @budget = state.budget
          @validate_format = (flags & 1) != 0
          @validate_content = (flags & 2) != 0
          @required = (flags & 64) != 0
          @invalid_pattern = false
        end

        def string? = @value.is_a?(String)
        def invalid_pattern? = @invalid_pattern

        def valid?
          return !@required unless string?

          valid_string?(@rules, @value)
        end

        def prepare
          @budget&.check_deadline!
          check(2)
        end

        def check(step)
          case step
          when 2
            @length = @value.length
            true
          when 3
            exceeded = @length > @rules.max_length
            exceeded ? false : true
          when 4
            below = @length < @rules.min_length
            below ? false : true
          when 5 then (!ecma_regexp(@rules.pattern).match?(@value)) ? false : true
          when 6 then (!@rules.format.call(@value)) ? false : true
          when 7 then valid_content?(@rules, @value)
          else raise "unknown string assertion"
          end
        rescue RegexpError
          @invalid_pattern = true
          false
        end

        def message(keyword, rescued)
          return ErrorMessage.invalid_pattern(@rules.pattern) if rescued

          case keyword
          when "type" then ErrorMessage.type("string", @value)
          when "maxLength" then ErrorMessage.size(keyword, @rules.max_length, @length)
          when "minLength" then ErrorMessage.size(keyword, @rules.min_length, @length)
          when "pattern" then @invalid_pattern ? ErrorMessage.invalid_pattern(@rules.pattern) : ErrorMessage.pattern(@rules.pattern)
          when "format" then ErrorMessage.format(@rules.format.name)
          when "contentEncoding" then ErrorMessage.content_encoding
          when "contentMediaType" then ErrorMessage.content_media_type
          else raise "unknown string diagnostic"
          end
        end

        private def valid_string?(rules, value)
          @budget&.check_deadline!
          result = super
          @budget&.check_deadline!
          result
        end

        private def valid_content?(rules, value)
          @budget&.check_deadline!
          result = super
          @budget&.check_deadline!
          result
        end

        private def ecma_regexp(pattern)
          @state.ecma_regexp(pattern)
        end
      end
    end
  end
end
