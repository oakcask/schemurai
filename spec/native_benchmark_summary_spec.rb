# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "native benchmark workflow summary" do
  it "publishes timings, allocations and the target count to the job summary", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    report = {ruby: "Ruby | with `markup`", width: 1000, iterations: 31, batch: 100,
              results: {"valid / valid?" => {seconds: {vm: 0.00002, native: 0.000001}, allocations: {native: 0}},
                        "invalid / validate" => {seconds: {vm: 0.00002, native: 0.000004}, allocations: {native: 2}}}}
    Dir.mktmpdir do |directory|
      input = File.join(directory, "report.json")
      output = File.join(directory, "summary.md")
      File.write(input, JSON.generate(report))
      stdout, stderr, status = Open3.capture3({"GITHUB_STEP_SUMMARY" => output}, RbConfig.ruby, "script/native-benchmark-summary", input)
      expect(status.success?).to be(true), stderr
      expect(File.read(output)).to eq(stdout)
      expect(stdout).to include("1/2 cases ≥10×; minimum 5.00×", "| valid / valid? | 20.00 | 1.00 | 20.00× | 0.00 |")
      expect(stdout).to include("| invalid / validate | 20.00 | 4.00 | 5.00× | 2.00 |", "Ruby: Ruby   with  markup ")
    end
  end

  it "explains a failed benchmark when no report was produced", :aggregate_failures do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3({"GITHUB_STEP_SUMMARY" => nil}, RbConfig.ruby, "script/native-benchmark-summary", File.join(directory, "missing.json"))
      expect(status.success?).to be(true), stderr
      expect(stdout).to include("No benchmark report was produced", "failed build or benchmark step")
    end
  end
end
