# frozen_string_literal: true

require "json"
require "open3"

# Keep the write-enabled workflow limited to the suite and its generated counts.
base = ENV.fetch("BASE_SHA")
files, status = Open3.capture2("git", "diff", "--name-only", base, "HEAD")
abort "could not read PR changes" unless status.success?
allowed = %w[references/JSON-Schema-Test-Suite oracle/case_catalog.json]
abort "PR changes files other than the suite and counts" unless (files.lines.map(&:chomp) - allowed).empty?

original, status = Open3.capture2("git", "show", "#{base}:oracle/case_catalog.json")
abort "could not read base catalog" unless status.success?
catalogs = [JSON.parse(original), JSON.parse(File.read("oracle/case_catalog.json"))]
catalogs.each do |catalog|
  catalog.fetch("dialects").each_value { |settings| settings.delete("expected_counts") }
end
abort "PR changes catalog classification settings" unless catalogs.first == catalogs.last
