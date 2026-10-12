# frozen_string_literal: true

require "rdoc/task"

RDoc::Task.new do |rdoc|
  rdoc.main = "README.md"
  rdoc.options << "--visibility=public"
  rdoc.rdoc_dir = "rdoc"
  rdoc.title = "Schemurai API Documentation"
  rdoc.rdoc_files.include("README.md", "LICENSE", "lib/schemurai.rb", "lib/schemurai/version.rb", "lib/schemurai/limit_exceeded.rb")
end
