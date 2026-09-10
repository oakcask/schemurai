# frozen_string_literal: true

require "base64"
require "json"
require_relative "../evaluation"
require_relative "../error_message"

module Schemurai
  module VM
    module NativeSupport
      module_function def regexp(pattern)
        whitespace = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
        translated = +""
        escaped = false
        in_class = false
        pattern.each_char do |character|
          if escaped
            translated << case character
            when "d" then in_class ? "0-9" : "[0-9]"
            when "D" then in_class ? "^0-9" : "[^0-9]"
            when "w" then in_class ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
            when "W" then in_class ? "^A-Za-z0-9_" : "[^A-Za-z0-9_]"
            when "s" then in_class ? whitespace : "[#{whitespace}]"
            when "S" then in_class ? "^#{whitespace}" : "[^#{whitespace}]"
            else "\\#{character}"
            end
            escaped = false
          elsif character == "\\"
            escaped = true
          elsif character == "["
            in_class = true
            translated << character
          elsif character == "]"
            in_class = false
            translated << character
          elsif character == "^" && !in_class
            translated << "\\A"
          elsif character == "$" && !in_class
            translated << "\\z"
          else
            translated << character
          end
        end
        translated << "\\" if escaped
        Regexp.new(translated)
      end

      module_function def valid_content?(value, decode_base64, parse_json)
        decoded = decode_base64 ? Base64.strict_decode64(value) : value
        JSON.parse(decoded) if parse_json
        true
      rescue ArgumentError, JSON::ParserError
        false
      end
    end
    private_constant :NativeSupport
  end
end

begin
  require "schemurai_native"
rescue LoadError
  require_relative "../../../ext/schemurai_native/schemurai_native"
end

Schemurai.private_constant :VM
