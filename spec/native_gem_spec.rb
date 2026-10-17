# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

RSpec.describe "native gem packaging" do
  around do |example|
    Dir.mktmpdir("schemurai-package-spec") do |directory|
      @directory = directory # rubocop:disable RSpec/InstanceVariable -- temporary directory scoped to this example.
      example.run
    end
  end

  let(:directory) { @directory } # rubocop:disable RSpec/InstanceVariable -- set by the around hook.

  def build_native_gem(abis, platform = "x86_64-linux-gnu")
    abis.each do |abi|
      target = File.join(directory, "native", abi)
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "schemurai_native.so"), "binary fixture for #{abi}")
    end
    Open3.capture3(RbConfig.ruby, "script/build-native-gem", platform,
      File.join(directory, "native"), File.join(directory, "pkg"))
  end

  it "bundles multiple Ruby minors with bounded compatibility and no build step", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    _, stderr, status = build_native_gem(%w[4.0 4.1])
    expect(status).to be_success, stderr
    spec = Gem::Package.new(Dir[File.join(directory, "pkg/*.gem")].fetch(0)).spec

    expect(spec.platform.to_s).to eq("x86_64-linux-gnu")
    expect(spec.extensions).to be_empty
    expect(spec.files).to include("lib/schemurai_native.rb", "lib/schemurai/native/4.0/schemurai_native.so",
      "lib/schemurai/native/4.1/schemurai_native.so", "sig/schemurai.rbs")
    expect(spec.files.grep(%r{\Aext/})).to be_empty
    {"3.4.9" => false, "4.0.0" => true, "4.0.9" => true, "4.1.0" => true, "4.2.0" => false}.each do |version, supported|
      expect(spec.required_ruby_version.satisfied_by?(Gem::Version.new(version))).to eq(supported)
    end
  end

  it "rejects unbuilt Ruby minors inside the declared range", :aggregate_failures do
    _, stderr, status = build_native_gem(%w[4.0 4.2])
    expect(status).not_to be_success
    expect(stderr).to include("Ruby ABI range contains gaps")
  end

  it "rejects a macOS package containing Linux extensions", :aggregate_failures do
    _, stderr, status = build_native_gem(["4.0"], "arm64-darwin")
    expect(status).not_to be_success
    expect(stderr).to include("missing extension for Ruby 4.0")
  end

  it "rejects Ruby minors excluded by the source gem", :aggregate_failures do
    _, stderr, status = build_native_gem(["3.4"])
    expect(status).not_to be_success
    expect(stderr).to include("unsupported Ruby ABI")
  end
end
