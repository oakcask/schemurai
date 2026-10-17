# frozen_string_literal: true

# Installed as lib/schemurai_native.rb in binary gems only.
require_relative "schemurai/native/#{RUBY_VERSION.split(".").first(2).join(".")}/schemurai_native"
