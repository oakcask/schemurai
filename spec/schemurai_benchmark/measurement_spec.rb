# frozen_string_literal: true

require_relative "../../benchmark/support/measurement"

RSpec.describe SchemuraiBenchmark::Measurement do
  describe ".alternating" do
    let(:calls) { [] }

    it "reverses backend order each round while retaining per-backend samples" do
      samples = described_class.alternating(iterations: 3) do |backend|
        calls << backend
        calls.length
      end

      expect([calls, samples]).to eq([%i[vm native native vm vm native], {vm: [1, 4, 5], native: [2, 3, 6]}])
    end
  end

  describe ".samples" do
    let(:events) { [] }

    before do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_THREAD_CPUTIME_ID)
        .and_return(10.0, 16.0, 20.0, 29.0)
    end

    it "normalizes each batch by call count using the selected clock" do
      samples = described_class.samples(iterations: 2, batch: 3, clock: Process::CLOCK_THREAD_CPUTIME_ID) do
        events << :work
      end

      expect([samples, events.length]).to eq([[2.0, 3.0], 6])
    end

    context "with garbage collection before samples" do
      before do
        allow(GC).to receive(:start) { events << :gc }
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) do
          events << :clock
          events.length.to_f
        end
      end

      it "keeps collection outside the timed region" do
        described_class.samples(iterations: 2, batch: 1, clock: Process::CLOCK_MONOTONIC, gc: true) do
          events << :work
        end

        expect(events).to eq(%i[gc clock work clock gc clock work clock])
      end
    end

    it "leaves garbage collection to the runner by default" do
      allow(GC).to receive(:start)

      described_class.samples(iterations: 1, batch: 1, clock: Process::CLOCK_MONOTONIC) { nil }

      expect(GC).not_to have_received(:start)
    end
  end

  describe ".median" do
    it "uses the upper middle sample without changing the recorded samples" do
      samples = [9.0, 1.0, 5.0, 3.0]

      expect([described_class.median(samples), samples]).to eq([5.0, [9.0, 1.0, 5.0, 3.0]])
    end
  end
end
