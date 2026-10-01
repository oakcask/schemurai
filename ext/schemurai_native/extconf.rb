# frozen_string_literal: true

require "mkmf"

cflags = [ENV["CFLAGS"], "-std=c99", "-Wall", "-Wextra", "-Wno-unused-parameter"].compact
append_cflags(cflags.join(" "))
create_makefile("schemurai_native")
