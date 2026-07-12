import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  detectRepoTags,
  install,
  installRecommended,
  list,
  matchesRepo,
  parseIndex,
  readManifest,
  resolvePluginDir,
  uninstall,
  type MarketplaceEntry,
  type PluginSourceHandle,
} from '../src/core/plugins.js';

let scratch: string;
let consumer: string;

beforeEach(async () => {
  scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-plugins-test-'));
  consumer = path.join(scratch, 'consumer');
  await fs.mkdir(consumer, { recursive: true });
});

afterEach(async () => {
  await fs.rm(scratch, { recursive: true, force: true });
});

async function makeBundle(name: string, fileContents = `sentinel contents for ${name}\n`): Promise<string> {
  const dir = path.join(scratch, 'bundles', name);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, 'plugin.md'), fileContents);
  return dir;
}

function stubBundle(dir: string): () => Promise<PluginSourceHandle> {
  return async () => ({ dir, cleanup: async () => {} });
}

const GITLAB_ENTRY: MarketplaceEntry = {
  name: 'gitlab',
  description: 'GitLab ITS provider',
  type: 'its',
  source: 'example/autoducks-plugin-gitlab',
  version: 'v1.0.0',
};

describe('parseIndex', () => {
  it('parses a bare array of entries', () => {
    const parsed = parseIndex(JSON.stringify([GITLAB_ENTRY]));
    expect(parsed).toEqual([GITLAB_ENTRY]);
  });

  it('parses a { plugins: [...] } wrapper', () => {
    const parsed = parseIndex(JSON.stringify({ plugins: [GITLAB_ENTRY] }));
    expect(parsed).toEqual([GITLAB_ENTRY]);
  });

  it('drops malformed entries instead of throwing', () => {
    const parsed = parseIndex(JSON.stringify({ plugins: [GITLAB_ENTRY, { name: 'incomplete' }] }));
    expect(parsed).toEqual([GITLAB_ENTRY]);
  });
});

describe('install / list', () => {
  it('installs a plugin, records the manifest entry, and list() reports it as installed', async () => {
    const bundleDir = await makeBundle('gitlab');

    const result = await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir });
    expect(result.alreadyInstalled).toBe(false);

    const manifest = await readManifest(consumer);
    expect(manifest.plugins).toEqual([{ name: 'gitlab', type: 'its', source: GITLAB_ENTRY.source, version: 'v1.0.0' }]);

    const installedFile = await fs.readFile(path.join(resolvePluginDir(consumer, 'gitlab'), 'plugin.md'), 'utf8');
    expect(installedFile).toBe('sentinel contents for gitlab\n');

    const entries = await list(consumer, [GITLAB_ENTRY]);
    expect(entries).toEqual([
      {
        name: 'gitlab',
        description: GITLAB_ENTRY.description,
        type: 'its',
        state: 'installed',
        installedVersion: 'v1.0.0',
        latestVersion: 'v1.0.0',
        recommended: undefined,
      },
    ]);
  });

  it('list() reports available (not installed) and update-available (version drift)', async () => {
    const notInstalled = await list(consumer, [GITLAB_ENTRY]);
    expect(notInstalled[0]!.state).toBe('available');

    await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir: await makeBundle('gitlab') });

    const newerEntry = { ...GITLAB_ENTRY, version: 'v2.0.0' };
    const withUpdate = await list(consumer, [newerEntry]);
    expect(withUpdate[0]).toMatchObject({ state: 'update-available', installedVersion: 'v1.0.0', latestVersion: 'v2.0.0' });
  });

  it('is idempotent: installing the same entry twice converges to the same state', async () => {
    const bundleDir = await makeBundle('gitlab');
    await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir });
    const second = await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir });
    expect(second.alreadyInstalled).toBe(true);

    const manifest = await readManifest(consumer);
    expect(manifest.plugins).toHaveLength(1);
  });
});

describe('uninstall', () => {
  it('removes both the plugin files and the manifest entry', async () => {
    await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir: await makeBundle('gitlab') });

    const result = await uninstall(consumer, 'gitlab');
    expect(result.removed).toBe(true);

    await expect(fs.access(resolvePluginDir(consumer, 'gitlab'))).rejects.toThrow();
    const manifest = await readManifest(consumer);
    expect(manifest.plugins).toEqual([]);
  });

  it('is idempotent: uninstalling something not installed is a no-op that reports removed: false', async () => {
    const result = await uninstall(consumer, 'never-installed');
    expect(result.removed).toBe(false);
  });
});

describe('files land only under .autoducks/custom/plugins/', () => {
  it('install() never writes outside .autoducks/custom/', async () => {
    await install({ cwd: consumer, entry: GITLAB_ENTRY, bundleDir: await makeBundle('gitlab') });

    const autoducksEntries = await fs.readdir(path.join(consumer, '.autoducks'));
    expect(autoducksEntries).toEqual(['custom']);

    const customEntries = await fs.readdir(path.join(consumer, '.autoducks', 'custom'));
    expect(customEntries).toEqual(['plugins']);

    const pluginsEntries = (await fs.readdir(path.join(consumer, '.autoducks', 'custom', 'plugins'))).sort();
    expect(pluginsEntries).toEqual(['gitlab', 'manifest.json']);
  });
});

describe('detectRepoTags / matchesRepo', () => {
  it('detects tags from marker files at the repo root', async () => {
    await fs.writeFile(path.join(consumer, 'package.json'), '{}');
    await fs.writeFile(path.join(consumer, 'tsconfig.json'), '{}');
    const tags = await detectRepoTags(consumer);
    expect(tags.sort()).toEqual(['node', 'typescript']);
  });

  it('matchesRepo: no matcher matches every repo', () => {
    expect(matchesRepo(undefined, { tags: [] })).toBe(true);
  });

  it('matchesRepo: explicit OWNER/REPO matches only that repo', () => {
    expect(matchesRepo('owner/repo', { slug: 'owner/repo', tags: [] })).toBe(true);
    expect(matchesRepo('owner/repo', { slug: 'other/repo', tags: [] })).toBe(false);
  });

  it('matchesRepo: comma-separated tag list matches on overlap', () => {
    expect(matchesRepo('python, go', { tags: ['node', 'python'] })).toBe(true);
    expect(matchesRepo('rust', { tags: ['node', 'python'] })).toBe(false);
  });
});

describe('installRecommended', () => {
  const universal: MarketplaceEntry = {
    name: 'security-baseline',
    description: 'Universal recommended agent',
    type: 'agent',
    source: 'example/plugin-security',
    version: 'v1.0.0',
    recommended: true,
  };
  const nodeOnly: MarketplaceEntry = {
    name: 'node-audit',
    description: 'Node-only recommended agent',
    type: 'agent',
    source: 'example/plugin-node-audit',
    version: 'v1.0.0',
    recommended: true,
    repos: 'node',
  };
  const pythonOnly: MarketplaceEntry = {
    name: 'python-lint-fix',
    description: 'Python-only recommended agent',
    type: 'agent',
    source: 'example/plugin-python-lint',
    version: 'v1.0.0',
    recommended: true,
    repos: 'python',
  };
  const notRecommended: MarketplaceEntry = {
    name: 'gitea',
    description: 'Not recommended',
    type: 'git',
    source: 'example/plugin-gitea',
    version: 'v1.0.0',
  };

  it('installs only recommended entries matching the repo, and logs every selected and skipped entry', async () => {
    const index = [universal, nodeOnly, pythonOnly, notRecommended];
    const result = await installRecommended({
      cwd: consumer,
      index,
      detection: { tags: ['node'] },
      resolveBundle: async (entry) => ({ dir: await makeBundle(entry.name), cleanup: async () => {} }),
    });

    expect(result.selected.map((s) => s.name).sort()).toEqual(['node-audit', 'security-baseline']);
    expect(result.skipped.map((s) => s.name).sort()).toEqual(['gitea', 'python-lint-fix']);

    // Every index entry appears in exactly one of selected/skipped — no silent selection.
    const accounted = [...result.selected, ...result.skipped].map((entry) => entry.name).sort();
    expect(accounted).toEqual(index.map((entry) => entry.name).sort());

    const skippedGitea = result.skipped.find((s) => s.name === 'gitea');
    expect(skippedGitea?.reason).toMatch(/not marked recommended/);
    const skippedPython = result.skipped.find((s) => s.name === 'python-lint-fix');
    expect(skippedPython?.reason).toMatch(/repos matcher/);

    const manifest = await readManifest(consumer);
    expect(manifest.plugins.map((p) => p.name).sort()).toEqual(['node-audit', 'security-baseline']);
  });

  it('skips entries already installed instead of reinstalling them', async () => {
    await install({ cwd: consumer, entry: universal, bundleDir: await makeBundle('security-baseline') });

    const result = await installRecommended({
      cwd: consumer,
      index: [universal],
      detection: { tags: [] },
      resolveBundle: stubBundle(await makeBundle('security-baseline-v2')),
    });

    expect(result.selected).toEqual([]);
    expect(result.skipped).toEqual([{ name: 'security-baseline', reason: 'already installed' }]);
  });
});
