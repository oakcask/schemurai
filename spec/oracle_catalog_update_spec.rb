# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../oracle/lib/case_catalog"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "official suite count updates", :aggregate_failures do
  let(:root) { Dir.mktmpdir("oracle-counts-") }
  let(:catalog_path) { File.join(root, "oracle/case_catalog.json") }
  let(:suite_path) { File.join(root, "suite/tests/draft7") }
  let(:catalog) { SchemuraiOracle::CaseCatalog.new(repository_root: root) }

  before do
    FileUtils.mkdir_p(File.dirname(catalog_path))
    FileUtils.mkdir_p(File.join(suite_path, "optional/format"))
    File.write(catalog_path, <<~JSON)
      {
        "version": 1,
        "suite_root": "suite",
        "dialects": {
          "draft7": {
            "enabled_formats": ["ipv4"],
            "expected_counts": {"selected": 1, "skipped": 0, "pending": 0}
          }
        }
      }
    JSON
    group = [{description: "fixture", schema: {}, tests: [{description: "valid", data: nil, valid: true}]}]
    %w[const.json optional/format/ipv4.json optional/format/uri.json].each do |path|
      File.write(File.join(suite_path, path), JSON.generate(group))
    end
  end

  after { FileUtils.remove_entry(root) }

  it "updates counts using existing classifications and preserves the rest of the file" do
    original = File.read(catalog_path)
    catalog.update_counts!

    expect(File.read(catalog_path)).to eq(original.sub('"selected": 1, "skipped": 0, "pending": 0',
      '"selected": 2, "skipped": 0, "pending": 1'))
    expect(catalog.verify_counts!).to be(true)
  end

  it "leaves an already synchronized catalog unchanged" do
    catalog.update_counts!
    original = File.read(catalog_path)
    catalog.update_counts!

    expect(File.read(catalog_path)).to eq(original)
  end

  it "refuses to replace counts with zero when the suite is missing" do
    FileUtils.remove_entry(File.join(root, "suite"))
    original = File.read(catalog_path)

    expect { catalog.update_counts! }.to raise_error(/suite is empty/)
    expect(File.read(catalog_path)).to eq(original)
  end

  it "preserves the catalog when upstream test data cannot be parsed" do
    File.write(File.join(suite_path, "const.json"), "invalid JSON")
    original = File.read(catalog_path)

    expect { catalog.update_counts! }.to raise_error(JSON::ParserError)
    expect(File.read(catalog_path)).to eq(original)
  end

  context "when checking the scope of a PR" do
    let(:check_script) { File.expand_path("../workflow-script/oracle-counts/check-update.rb", __dir__) }

    before do
      git("init", "--initial-branch=main")
      git("add", ".")
      git("commit", "-m", "test: initial catalog")
      git("branch", "base")
    end

    it "accepts an official suite update" do
      revision = git("rev-parse", "base").strip
      git("update-index", "--add", "--cacheinfo", "160000,#{revision},references/JSON-Schema-Test-Suite")
      git("commit", "-m", "test: update official suite")

      expect(check_scope.last).to be_success
    end

    it "accepts a generated counts commit" do
      catalog.update_counts!
      commit_changes

      expect(check_scope.last).to be_success
    end

    it "rejects changes to enabled formats" do
      File.write(catalog_path, File.read(catalog_path).sub('["ipv4"]', '["ipv4", "uri"]'))
      commit_changes

      output, status = check_scope
      expect(status).not_to be_success
      expect(output).to include("classification settings")
    end

    it "rejects changes to application code" do
      File.write(File.join(root, "application.rb"), "raise 'changed'")
      commit_changes

      output, status = check_scope
      expect(status).not_to be_success
      expect(output).to include("files other than the suite and counts")
    end

    def git(*arguments)
      output, status = Open3.capture2e(
        "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
        *arguments, chdir: root
      )
      raise output unless status.success?

      output
    end

    def commit_changes
      git("add", ".")
      git("commit", "-m", "test: update fixture")
    end

    def check_scope
      Open3.capture2e({"BASE_SHA" => "base"}, "ruby", check_script, chdir: root)
    end
  end
end
