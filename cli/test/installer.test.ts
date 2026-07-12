// Ports the fresh-install / update / idempotence scenarios from
// test/unit-install-copy.sh to drive the TS installer (src/core/installer.ts)
// instead of scripts/install.sh, through the same AUTODUCKS_SOURCE_DIR-style
// offline seam (passed here as `sourceDir` directly rather than the env var,
// since installer.install() takes it as an explicit option).
import { execFileSync } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { install, isFreshInstall, readRecordedVersion } from '../src/core/installer.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

let scratch: string;
let sourceDir: string;
let consumer: string;

beforeEach(async () => {
  scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-installer-test-'));
  sourceDir = path.join(scratch, 'source');
  consumer = path.join(scratch, 'consumer');

  await fs.mkdir(path.join(sourceDir, '.github', 'ISSUE_TEMPLATE'), { recursive: true });
  await fs.mkdir(path.join(sourceDir, 'scripts'), { recursive: true });
  await fs.cp(path.join(REPO_ROOT, '.autoducks'), path.join(sourceDir, '.autoducks'), { recursive: true });
  for (const file of await fs.readdir(path.join(REPO_ROOT, '.github', 'ISSUE_TEMPLATE'))) {
    await fs.copyFile(
      path.join(REPO_ROOT, '.github', 'ISSUE_TEMPLATE', file),
      path.join(sourceDir, '.github', 'ISSUE_TEMPLATE', file),
    );
  }
  for (const file of ['setup.sh', 'install.sh', 'update-triggers.sh', 'smoke-test.sh', 'smoke-test-plan.sh']) {
    await fs.copyFile(path.join(REPO_ROOT, 'scripts', file), path.join(sourceDir, 'scripts', file));
  }

  // Dev-only artifacts that must NEVER reach a consumer repo (#784 regression guard):
  // the unit-test suite (top-level test/) and the source repo's own CI workflow.
  await fs.mkdir(path.join(sourceDir, 'test'), { recursive: true });
  await fs.writeFile(path.join(sourceDir, 'test', 'unit-canary.sh'), '#!/usr/bin/env bash\necho canary\n');
  await fs.mkdir(path.join(sourceDir, '.github', 'workflows'), { recursive: true });
  await fs.writeFile(path.join(sourceDir, '.github', 'workflows', 'ci-unit-tests.yml'), 'name: CI — unit tests\n');

  await fs.mkdir(consumer, { recursive: true });
});

afterEach(async () => {
  await fs.rm(scratch, { recursive: true, force: true });
});

function diffDirs(a: string, b: string): boolean {
  try {
    execFileSync('diff', ['-r', a, b]);
    return true;
  } catch {
    return false;
  }
}

describe('install() — fresh install', () => {
  it('matches the on-disk tree scripts/install.sh produces, and excludes dev-only artifacts', async () => {
    const sourceSnapshot = path.join(scratch, 'source-snapshot');
    await fs.cp(sourceDir, sourceSnapshot, { recursive: true });

    const result = await install({ cwd: consumer, sourceDir, version: 'v1.2.3' });
    expect(result.freshInstall).toBe(true);

    const config = JSON.parse(await fs.readFile(path.join(consumer, '.autoducks', 'autoducks.json'), 'utf8'));
    expect(config.version).toBe('v1.2.3');

    await expect(fs.access(path.join(consumer, '.autoducks', '.autoducks'))).rejects.toThrow();

    const workflows = (await fs.readdir(path.join(consumer, '.github', 'workflows'))).sort();
    const runtimeTemplates = (
      await fs.readdir(path.join(consumer, '.autoducks', 'runtimes', 'github-actions'))
    ).filter((f) => f.startsWith('autoducks-') && f.endsWith('.yml')).sort();
    expect(workflows).toEqual(runtimeTemplates);
    for (const file of workflows) {
      expect(
        Buffer.compare(
          await fs.readFile(path.join(consumer, '.github', 'workflows', file)),
          await fs.readFile(path.join(consumer, '.autoducks', 'runtimes', 'github-actions', file)),
        ),
      ).toBe(0);
    }

    expect(
      Buffer.compare(
        await fs.readFile(path.join(consumer, '.autoducks', 'core', 'orchestration', 'fold-duplicate.sh')),
        await fs.readFile(path.join(REPO_ROOT, '.autoducks', 'core', 'orchestration', 'fold-duplicate.sh')),
      ),
    ).toBe(0);

    expect(diffDirs(sourceDir, sourceSnapshot)).toBe(true);

    await expect(fs.access(path.join(consumer, 'test', 'unit-canary.sh'))).rejects.toThrow();
    await expect(fs.access(path.join(consumer, '.github', 'workflows', 'ci-unit-tests.yml'))).rejects.toThrow();

    const scriptStat = await fs.stat(path.join(consumer, 'scripts', 'install.sh'));
    expect(scriptStat.mode & 0o111).not.toBe(0);
  });
});

describe('isFreshInstall / readRecordedVersion', () => {
  it('reports fresh before install and the resolved version as recorded after', async () => {
    expect(await isFreshInstall(consumer)).toBe(true);
    expect(await readRecordedVersion(consumer)).toBeUndefined();

    await install({ cwd: consumer, sourceDir, version: 'v1.2.3' });

    expect(await isFreshInstall(consumer)).toBe(false);
    expect(await readRecordedVersion(consumer)).toBe('v1.2.3');
  });
});

describe('install() — update', () => {
  it('preserves consumer-owned paths byte-for-byte, updates version, and leaves .github/actions/ untouched', async () => {
    await install({ cwd: consumer, sourceDir, version: 'v1.2.3' });

    const configPath = path.join(consumer, '.autoducks', 'autoducks.json');
    const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
    config.command = 'sentinel-cmd';
    await fs.writeFile(configPath, JSON.stringify(config, null, 2));

    await fs.mkdir(path.join(consumer, '.autoducks', 'providers', 'llm', 'claude'), { recursive: true });
    await fs.writeFile(
      path.join(consumer, '.autoducks', 'providers', 'llm', 'claude', 'settings.json'),
      '{"sentinel": "settings"}\n',
    );

    await fs.mkdir(path.join(consumer, '.autoducks', 'custom', 'agents', 'developer'), { recursive: true });
    await fs.writeFile(path.join(consumer, '.autoducks', 'custom', 'instructions.md'), 'sentinel custom instructions\n');
    await fs.writeFile(
      path.join(consumer, '.autoducks', 'custom', 'agents', 'developer', 'prompt.md'),
      'sentinel custom developer prompt\n',
    );

    await fs.writeFile(path.join(consumer, '.autoducks', 'OBSOLETE.txt'), 'stale file that should not survive\n');

    await fs.mkdir(path.join(consumer, '.github', 'actions', 'autoducks', 'developer-pre'), { recursive: true });
    const actionYml = 'name: sentinel developer-pre hook\nruns:\n  using: composite\n  steps:\n    - run: echo sentinel\n      shell: bash\n';
    await fs.writeFile(path.join(consumer, '.github', 'actions', 'autoducks', 'developer-pre', 'action.yml'), actionYml);

    const settingsBefore = await fs.readFile(path.join(consumer, '.autoducks', 'providers', 'llm', 'claude', 'settings.json'));
    const customSnapshot = path.join(scratch, 'custom-before-update');
    await fs.cp(path.join(consumer, '.autoducks', 'custom'), customSnapshot, { recursive: true });

    const result = await install({ cwd: consumer, sourceDir, version: 'v1.3.0' });
    expect(result.freshInstall).toBe(false);

    const configAfter = JSON.parse(await fs.readFile(configPath, 'utf8'));
    expect(configAfter.command).toBe('sentinel-cmd');
    expect(configAfter.version).toBe('v1.3.0');

    const settingsAfter = await fs.readFile(path.join(consumer, '.autoducks', 'providers', 'llm', 'claude', 'settings.json'));
    expect(Buffer.compare(settingsAfter, settingsBefore)).toBe(0);

    expect(diffDirs(path.join(consumer, '.autoducks', 'custom'), customSnapshot)).toBe(true);

    await expect(fs.access(path.join(consumer, '.autoducks', 'OBSOLETE.txt'))).rejects.toThrow();
    await expect(fs.access(path.join(consumer, '.autoducks', '.autoducks'))).rejects.toThrow();

    expect(
      Buffer.compare(
        await fs.readFile(path.join(consumer, '.github', 'actions', 'autoducks', 'developer-pre', 'action.yml')),
        Buffer.from(actionYml),
      ),
    ).toBe(0);
  });
});

describe('install() — idempotence', () => {
  it('re-running install with the same version converges to identical state', async () => {
    await install({ cwd: consumer, sourceDir, version: 'v1.2.3' });

    const workflowsSnapshot = path.join(scratch, 'workflows-before');
    await fs.cp(path.join(consumer, '.github', 'workflows'), workflowsSnapshot, { recursive: true });
    const runtimesSnapshot = path.join(scratch, 'runtimes-before');
    await fs.cp(path.join(consumer, '.autoducks', 'runtimes'), runtimesSnapshot, { recursive: true });

    await install({ cwd: consumer, sourceDir, version: 'v1.2.3' });

    expect(diffDirs(path.join(consumer, '.github', 'workflows'), workflowsSnapshot)).toBe(true);
    expect(diffDirs(path.join(consumer, '.autoducks', 'runtimes'), runtimesSnapshot)).toBe(true);
  });
});
