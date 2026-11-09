import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { promisify } from 'node:util';
import releasePlease from 'release-please';
import { createReleasePullRequests, lockfilePlugin, syncLockfiles } from './release-pr.mjs';

const execute = promisify(execFile);
const { GitHub, Errors } = releasePlease;
const logger = { info() {}, warn() {}, error() {}, debug() {} };
releasePlease.setLogger(logger);

async function fixture(t) {
  const repository = await mkdtemp(join(tmpdir(), 'release-please-test-'));
  t.after(() => rm(repository, { recursive: true, force: true }));
  const files = {
    'release-please-config.json': JSON.stringify({
      'release-type': 'ruby',
      'include-component-in-tag': false,
      'pull-request-title-pattern': 'chore: release${component} ${version}',
      packages: { '.': { 'package-name': 'schemurai', 'version-file': 'lib/schemurai/version.rb' } },
    }),
    '.release-please-manifest.json': '{".":"1.0.0"}\n',
    'lib/schemurai/version.rb': 'module Schemurai\n  VERSION = "1.0.0"\nend\n',
    Gemfile: 'source "https://rubygems.org"\ngemspec\n',
    'schemurai.gemspec': `require_relative "lib/schemurai/version"
Gem::Specification.new do |spec|
  spec.name = "schemurai"
  spec.version = Schemurai::VERSION
  spec.summary = "Release synchronization fixture"
  spec.authors = ["Schemurai"]
  spec.files = ["lib/schemurai/version.rb"]
end
`,
    'ext/schemurai_native/Cargo.toml': '[package]\nname = "schemurai-native"\nversion = "1.0.0"\nedition = "2024"\n',
    'ext/schemurai_native/src/lib.rs': '',
    'CHANGELOG.md': '# Changelog\n',
  };
  for (const [path, content] of Object.entries(files)) {
    await mkdir(dirname(join(repository, path)), { recursive: true });
    await writeFile(join(repository, path), content);
  }
  const options = { cwd: repository };
  await execute('bundle', ['lock', '--local', '--add-checksums'], options);
  await execute('cargo', ['generate-lockfile', '--manifest-path', 'ext/schemurai_native/Cargo.toml', '--offline'], options);
  await execute('git', ['init', '--initial-branch=main'], options);
  await execute('git', ['add', '.'], options);
  await execute('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', 'commit', '-m', 'chore: fixture'], options);
  const publications = [];
  const github = {
    repository: { owner: 'test', repo: 'schemurai', defaultBranch: 'main' },
    logger,
    async getFileContentsOnBranch(path) {
      try {
        const parsedContent = await readFile(join(repository, path), 'utf8');
        return { parsedContent, content: Buffer.from(parsedContent).toString('base64') };
      } catch (error) {
        if (error.code === 'ENOENT') throw new Errors.FileNotFoundError(path);
        throw error;
      }
    },
    async getFileJson(path) { return JSON.parse((await this.getFileContentsOnBranch(path)).parsedContent); },
    buildChangeSet: GitHub.prototype.buildChangeSet,
    async *releaseIterator() { yield { tagName: 'v1.0.0', sha: 'previous', notes: '' }; },
    async *mergeCommitIterator() {
      yield { sha: 'next', message: 'fix: improve validation', files: ['lib/schemurai/version.rb'] };
      yield { sha: 'previous', message: 'chore: release 1.0.0', files: [] };
    },
    async *pullRequestIterator() {},
    async createPullRequest(request, branch, message, updates) {
      const changes = await this.buildChangeSet(updates, branch);
      publications.push({ request, message, changes });
      return { ...request, number: 1 };
    },
  };
  return { repository, github, publications };
}

async function assertSynchronized(changes, version) {
  const lockfile = changes.get('Gemfile.lock').content;
  assert.equal(lockfile.match(new RegExp(`schemurai \\(${version.replaceAll('.', '\\.')}\\)`, 'g'))?.length, 2);
  assert.match(changes.get('ext/schemurai_native/Cargo.toml').content, new RegExp(`version = "${version}"`));
  assert.match(changes.get('ext/schemurai_native/Cargo.lock').content, new RegExp(`version = "${version}"`));
  assert.match(changes.get('lib/schemurai/version.rb').content, new RegExp(`VERSION = "${version}"`));
  assert.equal(JSON.parse(changes.get('.release-please-manifest.json').content)['.'], version);
}

test('the first published release PR includes actual Bundler and Cargo synchronization', async t => {
  const { repository, github, publications } = await fixture(t);
  const original = await readFile(join(repository, 'Gemfile.lock'), 'utf8');
  await createReleasePullRequests({ github, targetBranch: 'main', repository });
  assert.equal(publications.length, 1);
  await assertSynchronized(publications[0].changes, '1.0.1');
  assert.equal(await readFile(join(repository, 'Gemfile.lock'), 'utf8'), original);
  const { stdout } = await execute('git', ['worktree', 'list', '--porcelain'], { cwd: repository });
  assert.equal(stdout.match(/^worktree /gm).length, 1);
});

test('an existing release PR receives one fully synchronized update', async t => {
  const { repository, github, publications } = await fixture(t);
  const [existing] = await createReleasePullRequests({ github, targetBranch: 'main', repository });
  github.pullRequestIterator = async function* (_branch, state) {
    if (state === 'OPEN') yield existing;
  };
  github.mergeCommitIterator = async function* () {
    yield { sha: 'next', message: 'feat: add validation', files: ['lib/schemurai/version.rb'] };
    yield { sha: 'previous', message: 'chore: release 1.0.0', files: [] };
  };
  github.updatePullRequest = async function (number, pullRequest, branch) {
    assert.equal(number, existing.number);
    publications.push({ changes: await this.buildChangeSet(pullRequest.updates, branch) });
    return existing;
  };
  await createReleasePullRequests({ github, targetBranch: 'main', repository });
  assert.equal(publications.length, 2);
  await assertSynchronized(publications[1].changes, '1.1.0');
});

test('native manifest changes on main are preserved when checkout is older', async t => {
  const { repository, github, publications } = await fixture(t);
  const read = github.getFileContentsOnBranch;
  github.getFileContentsOnBranch = async function (path) {
    const file = await read.call(this, path);
    if (path !== 'ext/schemurai_native/Cargo.toml') return file;
    const parsedContent = `${file.parsedContent}description = "New metadata on main"\n`;
    return { parsedContent, content: Buffer.from(parsedContent).toString('base64') };
  };
  await createReleasePullRequests({ github, targetBranch: 'main', repository });
  assert.equal(publications.length, 1);
  await assertSynchronized(publications[0].changes, '1.0.1');
  assert.match(publications[0].changes.get('ext/schemurai_native/Cargo.toml').content, /New metadata on main/);
});

test('a real synchronization failure prevents publication and cleans up the worktree', async t => {
  const { repository, github, publications } = await fixture(t);
  let directory;
  await assert.rejects(createReleasePullRequests({
    github, targetBranch: 'main', repository,
    async sync(path) {
      directory = path;
      const manifest = join(path, 'ext/schemurai_native/Cargo.toml');
      await writeFile(manifest, `${await readFile(manifest, 'utf8')}\n[dependencies]\nmissing = { path = "missing" }\n`);
      await syncLockfiles(path);
    },
  }));
  assert.equal(publications.length, 0);
  await assert.rejects(readFile(join(directory, 'Gemfile.lock')), { code: 'ENOENT' });
  const { stdout } = await execute('git', ['worktree', 'list', '--porcelain'], { cwd: repository });
  assert.equal(stdout.match(/^worktree /gm).length, 1);
});

test('no release candidate performs no synchronization or publication', async t => {
  const { repository, github, publications } = await fixture(t);
  github.mergeCommitIterator = async function* () {
    yield { sha: 'previous', message: 'chore: release 1.0.0', files: [] };
  };
  const result = await createReleasePullRequests({
    github, targetBranch: 'main', repository,
    sync() { assert.fail('Synchronization must not run without a release'); },
  });
  assert.deepEqual(result, []);
  assert.equal(publications.length, 0);
});

test('unsupported release layouts are rejected', async () => {
  const plugin = lockfilePlugin({});
  await assert.rejects(plugin.run([{ path: 'other' }]), /one root release/);
});
