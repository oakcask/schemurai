# frozen_string_literal: true

require_relative "../../benchmark/support/comparison"

RSpec.describe SchemuraiBenchmark::Comparison do
  subject(:comparison) do
    described_class.new(
      baseline_lib: "refs/base/lib",
      baseline_label: "base (abc123)",
      candidate_label: "refs/pull/42/merge (def456)",
      summary_path: "summary.md"
    )
  end

  let(:result) do
    described_class::Result.new(
      backend: "vm",
      draft: "Draft 2020-12",
      workload: "validate",
      baseline_ips: 12_345.678,
      candidate_ips: 13_580.2458
    )
  end

  it "compares only Draft 2020-12" do
    expect(described_class::DRAFTS).to eq("Draft 2020-12" => "draft2020_12.rb")
  end

  describe "#markdown" do
    it "reports throughput and the signed change for every result" do
      expect(comparison.markdown([result])).to include(
        "Compared `base (abc123)` with `refs/pull/42/merge (def456)`",
        "| vm | Draft 2020-12 | validate | 12,345.68 | 13,580.25 | +10.00% |"
      )
    end
  end
end
