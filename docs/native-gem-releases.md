# Native gem releases

The release workflow publishes the source gem and six platform gems to
RubyGems.org with the existing trusted publisher credentials. The GitHub release
becomes public only after all builds, installed-package smoke tests, and gem
pushes succeed. No RubyGems API key is needed in the build jobs.

The shared `shared--native-gems.yaml` workflow also runs for package-related
pull requests. Linux binaries are built on native x64/arm64 runners inside
official Ruby Docker images: Debian bookworm for glibc, Alpine 3.23 for musl.
macOS binaries are built on Intel and Apple Silicon runners with a macOS 14
deployment target. Rust uses its default CPU target rather than the runner CPU.
Distributed binaries use `--enable-portable-hash-walk` to avoid private Ruby Hash
storage assumptions and private symbols across Ruby patch releases. They use
`--disable-link-ruby` to resolve Ruby symbols from the interpreter rather than
requiring the build host's shared libruby; this also supports static Ruby builds.

`script/build-native-extension` builds only the sources listed in the gemspec
in a temporary directory and writes `native/<major.minor>/schemurai_native.so`
(or `.bundle` on macOS). Artifacts from every Ruby minor are combined by platform
before `script/build-native-gem` packages them. The platform gem has no `ext/`
sources or extension build hooks. Its loader chooses the binary for the running
Ruby minor, and its Ruby requirement excludes minors without a binary.

The current Ruby ABI matrix contains only 4.0, matching the source gem's minimum
Ruby version. To add a supported minor, extend the `ruby` axes in both build
jobs and both test jobs. Keep the earliest patch release and the latest patch
release in the test axes. All supported minors must be packaged together: do
not publish separate gems with the same version and platform for each Ruby ABI.

`script/test-native-gem` installs each assembled gem in an isolated gem home
with only Ruby on PATH, then exercises Ruby, VM, and native validation via
`test/package_smoke_test.rb`. This checks that native execution works without
compilers and cannot silently delegate to the VM. Linux tests use fresh runtime
containers, and both operating systems test Ruby 4.0.0 and the latest 4.0.

Local build and install validation (use the platform matching the build host):

```sh
ruby script/build-native-extension native
ruby script/build-native-gem x86_64-linux-gnu native pkg
SCHEMURAI_NATIVE_PLATFORM=x86_64-linux-gnu ruby script/test-native-gem pkg/*.gem
```

The source gem remains available for other platforms and Ruby versions. Its
optional compilation behavior is unchanged. Publishing a new Ruby minor binary
for an already published version/platform requires a new gem version; RubyGems
does not allow replacing an existing package.
