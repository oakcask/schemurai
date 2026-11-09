import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import releasePlease from 'release-please';

const { GitHub, Manifest } = releasePlease;
const execute = promisify(execFile);
const cargoManifest = 'ext/schemurai_native/Cargo.toml';
const generatedFiles = ['Gemfile.lock', cargoManifest, 'ext/schemurai_native/Cargo.lock'];
const syncInputs = ['Gemfile', 'schemurai.gemspec', 'lib/schemurai/version.rb', ...generatedFiles];

export async function syncLockfiles(directory) {
  const options = { cwd: directory, maxBuffer: 16 * 1024 * 1024 };
  await execute('bundle', ['lock'], options);
  const { stdout } = await execute('ruby', [
    '-Ilib', '-rschemurai/version', '-e', 'print Schemurai::VERSION',
  ], options);
  const path = join(directory, cargoManifest);
  const manifest = await readFile(path, 'utf8');
  const packageVersion = /^(\[package\]\nname = "schemurai-native"\n)version = "[^"]+"$/m;
  if (!packageVersion.test(manifest)) throw new Error('schemurai-native package version not found');
  const updated = manifest.replace(
    packageVersion,
    (_, prefix) => `${prefix}version = ${JSON.stringify(stdout.trim())}`,
  );
  await writeFile(path, updated);
  await execute('cargo', ['update', '--manifest-path', cargoManifest, '--workspace'], options);
}

// All remote writes remain in release-please, after this plugin has succeeded.
export function lockfilePlugin({ github, targetBranch }, {
  repository = process.cwd(),
  sync = syncLockfiles,
} = {}) {
  return {
    preconfigure: strategies => strategies,
    processCommits: commits => commits,
    async run(candidates) {
      if (candidates.length === 0) return candidates;
      if (candidates.length !== 1 || candidates[0].path !== '.') {
        throw new Error('Lockfile synchronization requires one root release');
      }
      const pullRequest = candidates[0].pullRequest;
      // Read inputs through release-please's branch cache too: main may have
      // advanced since checkout, especially while a draft release was created.
      const changes = await github.buildChangeSet([
        ...syncInputs.map(path => ({
          path,
          createIfMissing: false,
          updater: { updateContent: content => content },
        })),
        ...pullRequest.updates,
      ], targetBranch);
      for (const path of syncInputs) {
        if (!changes.has(path)) throw new Error(`Missing synchronization input: ${path}`);
      }
      const temporary = await mkdtemp(join(tmpdir(), 'schemurai-release-'));
      const directory = join(temporary, 'source');
      let added = false;
      try {
        await execute('git', ['worktree', 'add', '--detach', directory, 'HEAD'], { cwd: repository });
        added = true;
        for (const [path, change] of changes) {
          const destination = resolve(directory, path);
          if (!destination.startsWith(`${directory}/`)) throw new Error(`Invalid update path: ${path}`);
          await mkdir(dirname(destination), { recursive: true });
          await writeFile(destination, change.content);
        }
        await sync(directory);
        // Replace existing updaters so they cannot overwrite the regenerated contents.
        const contents = await Promise.all(generatedFiles.map(async path => ({
          path,
          content: await readFile(join(directory, path), 'utf8'),
        })));
        pullRequest.updates = [
          ...pullRequest.updates.filter(update => !generatedFiles.includes(update.path)),
          ...contents.map(({ path, content }) => ({
            path,
            createIfMissing: false,
            updater: { updateContent: () => content },
          })),
        ];
        return candidates;
      } finally {
        try {
          if (added) await execute('git', ['worktree', 'remove', '--force', directory], { cwd: repository });
        } finally {
          await rm(temporary, { recursive: true, force: true });
        }
      }
    },
  };
}

export async function createReleasePullRequests({ github, targetBranch, repository = process.cwd(), sync }) {
  const manifest = await Manifest.fromManifest(github, targetBranch);
  manifest.plugins.push(lockfilePlugin({ github, targetBranch }, { repository, sync }));
  return manifest.createPullRequests();
}

async function main() {
  const [owner, repo] = (process.env.GITHUB_REPOSITORY ?? '').split('/');
  const token = process.env.GH_TOKEN;
  if (!owner || !repo || !token) throw new Error('GITHUB_REPOSITORY and GH_TOKEN are required');
  const targetBranch = 'main';
  const github = await GitHub.create({ owner, repo, token, defaultBranch: targetBranch });
  const pullRequests = await createReleasePullRequests({ github, targetBranch });
  console.log(`Updated ${pullRequests.filter(Boolean).length} release pull request(s)`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}
