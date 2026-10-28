# frozen_string_literal: true

require_relative "../spec/spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../benchmark/real_world/campaign"
require_relative "../benchmark/real_world/fetcher"

RSpec.describe "real-world schema corpus" do
  let(:corpus) { SchemuraiBenchmark::RealWorld::Corpus.new }
  let(:backends) { [:ruby, ENV.fetch("SCHEMURAI_DIFFERENTIAL_BACKEND", "vm").to_sym].uniq }

  it "pins each unchanged schema alongside its own license and provenance" do
    expect(corpus.entries.map { |entry| entry.fetch("id") }).to eq(%w[geojson github-workflow taskfile])
    corpus.entries.each do |entry|
      root = SchemuraiBenchmark::RealWorld::Corpus::ROOT
      license = File.join(root, "schemas", entry.fetch("id"), "LICENSE")
      expect(Digest::SHA256.file(license).hexdigest).to eq(entry.fetch("license").fetch("sha256"))
      expect(entry.fetch("provenance").fetch("revision")).to match(/\A[0-9a-f]{40}\z/)
      expect(entry.fetch("schema").fetch("$schema")).to include("draft-07")
    end
  end

  it "checks known outcomes, representation controls and seeded nested mutations" do
    checker = SchemuraiBenchmark::RealWorld::Checker.new(backends: backends)
    Dir.mktmpdir("schemurai-real-world") do |directory|
      [1, 8].each do |size|
        campaign = SchemuraiBenchmark::RealWorld::Campaign.new(seed: 9571, size: size, mutations: 20)
        artifact = File.join(directory, "failure.json")
        expect(campaign.check(checker, artifact: artifact)).to be >= 72
        expect(File.exist?(artifact)).to be(false)
      end
    end
  end

  it "reproduces the same mutation stream and varies it with the seed" do
    build = lambda do |seed|
      SchemuraiBenchmark::RealWorld::Campaign.new(seed: seed, size: 4, mutations: 10)
        .each_case.map { |test_case| [test_case.id, test_case.instance] }
    end
    expect(build.call(42)).to eq(build.call(42))
    first = build.call(42).map(&:last)
    expect(first).not_to eq(build.call(43).map(&:last))
  end

  it "distinguishes shared container identities from independent equal copies" do
    cases = corpus.cases(seed: 42, size: 4)
    shared = cases.find { |test_case| test_case.id.start_with?("geojson/") && test_case.id.end_with?("/shared") }.instance.fetch("features")
    copied = cases.find { |test_case| test_case.id.start_with?("geojson/") && test_case.id.end_with?("/copied") }.instance.fetch("features")
    expect(shared).to eq(copied)
    expect(shared.first).to equal(shared.last)
    expect(copied.first).not_to equal(copied.last)
    original = cases.find { |test_case| test_case.id.start_with?("geojson/") && test_case.id.end_with?("/shared") }
    record = JSON.parse(JSON.generate(id: original.id, schema: original.schema,
      instance: original.instance, expected: true, representation: "shared"))
    replay = SchemuraiBenchmark::RealWorld::Campaign.replay(record).instance.fetch("features")
    expect(replay.first).to equal(replay.last)
  end

  it "saves a standalone input when a backend check fails" do
    checker = instance_double(SchemuraiBenchmark::RealWorld::Checker)
    allow(checker).to receive(:check).and_raise("injected mismatch")
    campaign = SchemuraiBenchmark::RealWorld::Campaign.new(seed: 42, size: 1, mutations: 0)
    Dir.mktmpdir("schemurai-real-world") do |directory|
      artifact = File.join(directory, "failure.json")
      expect { campaign.check(checker, artifact: artifact) }.to raise_error("injected mismatch")
      record = JSON.parse(File.read(artifact))
      test_case = SchemuraiBenchmark::RealWorld::Campaign.replay(record)
      expect(SchemuraiBenchmark::RealWorld::Checker.new(backends: backends).check(test_case).first).to be(true)
    end
  end

  it "rejects a stale download after Renovate changes a source pin" do
    Dir.mktmpdir("schemurai-real-world") do |directory|
      source = corpus.entries.first
      entry = source.except("provenance", "sha256")
        .merge("schema" => source.fetch("provenance"))
      target = File.join(directory, "schemas", source.fetch("id"))
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "source.json"), JSON.generate(entry))
      receipt = {source: entry.merge("id" => "old-source"), sha256: "stale"}
      File.write(File.join(target, "receipt.json"), JSON.generate(receipt))
      stub_const("SchemuraiBenchmark::RealWorld::Corpus::ROOT", directory)
      expect { SchemuraiBenchmark::RealWorld::Corpus.new.entries }.to raise_error(/stale schema/)
    end
  end

  it "requires review when the fetched license changes" do
    fetcher = SchemuraiBenchmark::RealWorld::Fetcher.new
    allow(fetcher).to receive(:fetch_bytes).and_return("a different license")
    expect { fetcher.fetch_all }.to raise_error(/license changed/)
  end

  it "keeps both schema and license pins discoverable by Renovate" do
    configuration = JSON.parse(File.read(File.expand_path("../renovate.json", __dir__)))
    manager = configuration.fetch("customManagers").first
    pattern = Regexp.new(manager.fetch("matchStrings").first)
    corpus.entries.each do |entry|
      source = File.join(SchemuraiBenchmark::RealWorld::Corpus::ROOT, "schemas", entry.fetch("id"), "source.json")
      expected = [entry.fetch("provenance"), entry.fetch("license")].map do |dependency|
        dependency.values_at("repository", "branch", "revision")
      end
      expect(File.read(source).scan(pattern)).to eq(expected)
    end
  end

  it "pairs each guaranteed destruction with independently expected errors" do
    cases = SchemuraiBenchmark::RealWorld::Campaign.new(seed: 123, size: 8, mutations: 20).each_case.to_a
    destructive = cases.select(&:mutation)
    expect(destructive.length).to eq(69)
    destructive.each do |test_case|
      expect(test_case.expected).to be(false)
      expect(test_case.expected_errors).not_to be_empty
      mutation = test_case.mutation
      value = mutation.fetch("path").reduce(test_case.instance) { |node, key| node.fetch(key) }
      expect(value).to eq(mutation.fetch("after"))
    end
    expect(destructive.map { |test_case| test_case.mutation.fetch("after") }.uniq).to contain_exactly(nil, false, true)
  end

  it "rejects agreed invalid verdicts when an error field points elsewhere" do
    test_case = corpus.cases(seed: 42, size: 1).find(&:mutation)
    %w[instance_path schema_path keyword].each do |field|
      checker = SchemuraiBenchmark::RealWorld::Checker.new(backends: backends)
      checker.validators(test_case.schema).each_value do |validator|
        original = validator.validate(test_case.instance).errors.first
        wrong = original.with(**{field.to_sym => "/unrelated"})
        allow(validator).to receive(:validate).and_return(Schemurai::Result.new([wrong]))
      end
      expect { checker.check(test_case) }.to raise_error(/unexpected errors/)
    end
  end

  it "rejects a destruction when repairing the edited field remains invalid" do
    test_case = corpus.cases(seed: 42, size: 1).find(&:mutation)
    checker = SchemuraiBenchmark::RealWorld::Checker.new(backends: backends)
    checker.validators(test_case.schema).each_value do |validator|
      allow(validator).to receive(:valid?).and_return(false)
    end
    expect { checker.check(test_case) }.to raise_error(/repair did not restore validity/)
  end

  it "preserves the mutation and expected error contract in replay artifacts" do
    checker = instance_double(SchemuraiBenchmark::RealWorld::Checker)
    allow(checker).to receive(:check) { |test_case| raise "injected mismatch" if test_case.mutation }
    campaign = SchemuraiBenchmark::RealWorld::Campaign.new(seed: 42, size: 1, mutations: 1)
    Dir.mktmpdir("schemurai-real-world") do |directory|
      artifact = File.join(directory, "failure.json")
      expect { campaign.check(checker, artifact: artifact) }.to raise_error("injected mismatch")
      record = JSON.parse(File.read(artifact))
      replay = SchemuraiBenchmark::RealWorld::Campaign.replay(record)
      expect(replay.mutation).to eq(record.fetch("mutation"))
      expect(replay.expected_errors).to eq(record.fetch("expected_errors"))
      expect(SchemuraiBenchmark::RealWorld::Checker.new(backends: backends).check(replay).first).to be(false)
    end
  end

  it "escapes mutation and diagnostic pointers for generated task names" do
    source = corpus.cases(seed: 42, size: 1).find { |test_case| test_case.id.start_with?("taskfile/") && test_case.expected }
    instance = corpus.copy(source.instance)
    instance.fetch("tasks")["task/~0"] = instance.fetch("tasks").delete("task_0")
    source = source.with(instance: instance, faults: [["tasks", "task/~0", "cmds", 0]])
    test_case = SchemuraiBenchmark::RealWorld::DestructiveMutator.new(source, seed: 42).mutate(0)
    expect(test_case.mutation.fetch("instance_path")).to eq("/tasks/task~1~00/cmds/0")
    expect(SchemuraiBenchmark::RealWorld::Checker.new(backends: backends).check(test_case).first).to be(false)
  end
end
