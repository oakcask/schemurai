# frozen_string_literal: true

require "rake/clean"
require "rbconfig"

C_FORMAT_SOURCES = Dir["ext/**/*.{c,h}"].sort.freeze
C_LINT_SOURCES = Dir["ext/**/*.c"].sort.freeze
CLANG_FORMAT = ENV.fetch("CLANG_FORMAT", "clang-format-18")
CLANG_TIDY = ENV.fetch("CLANG_TIDY", "clang-tidy-18")
C_TOOLS = {"CLANG_FORMAT" => CLANG_FORMAT, "CLANG_TIDY" => CLANG_TIDY}.freeze

def command_available?(command)
  return File.file?(command) && File.executable?(command) if command.include?(File::SEPARATOR)

  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    path = File.join(directory, command)
    File.file?(path) && File.executable?(path)
  end
end

CLEAN.include("ext/schemurai_native/*.o", "ext/schemurai_native/*.so", "ext/schemurai_native/Makefile")

desc "Build the native VM backend"
task :compile do
  Dir.chdir("ext/schemurai_native") do
    ruby "extconf.rb" unless File.exist?("Makefile")
    sh "make"
  end
end

namespace :c do
  desc "Check C development tools"
  task :tools do
    missing = C_TOOLS.reject { |_, command| command_available?(command) }
    next if missing.empty?

    details = missing.map { |variable, command| "  - #{command} (override with #{variable})" }
    abort ["Missing required C development tools:", *details, "Install LLVM 18 or set the variables above."].join("\n")
  end

  desc "Format C sources"
  task format: :tools do
    sh CLANG_FORMAT, "-i", *C_FORMAT_SOURCES
  end

  namespace :format do
    desc "Check C source formatting"
    task check: "c:tools" do
      sh CLANG_FORMAT, "--dry-run", "--Werror", *C_FORMAT_SOURCES
    end
  end

  desc "Lint C sources"
  task lint: :tools do
    include_flags = %w[rubyhdrdir rubyarchhdrdir].map { |key| "-I#{RbConfig::CONFIG.fetch(key)}" }
    sh CLANG_TIDY, "--quiet", "--warnings-as-errors=*", *C_LINT_SOURCES, "--", "-std=c99", *include_flags
  end
end

begin
  require "rdoc/task"

  RDoc::Task.new do |rdoc|
    rdoc.main = "README.md"
    rdoc.options << "--visibility=public"
    rdoc.rdoc_dir = "rdoc"
    rdoc.title = "Schemurai API Documentation"
    rdoc.rdoc_files.include("README.md", "LICENSE", "lib/schemurai.rb", "lib/schemurai/version.rb")
  end
rescue LoadError
  # Native compilation does not require the optional documentation bundle.
end
