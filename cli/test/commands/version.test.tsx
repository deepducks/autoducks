import React from 'react';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { render } from 'ink-testing-library';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { VersionInfo } from '../../src/commands/version.js';
import { getVersion, load, type AutoducksConfig, UNPINNED_VERSION_LABEL } from '../../src/core/config.js';
import { getCliVersion } from '../../src/core/pkg.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'autoducks-version-test-'));
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

/** Mirrors what `run()` in version.tsx does, without invoking a real Ink `render()`. */
async function resolveVersionInfo(root: string): Promise<{ cliVersion: string; pinnedVersion: string }> {
  const cliVersion = await getCliVersion();
  let config: AutoducksConfig = {};
  try {
    config = (await load(root)).config;
  } catch {
    // No config file yet — reported as unpinned.
  }
  return { cliVersion, pinnedVersion: getVersion(config) };
}

describe('version command', () => {
  it('reports the unpinned label when there is no config file', async () => {
    const { pinnedVersion } = await resolveVersionInfo(dir);
    expect(pinnedVersion).toBe(UNPINNED_VERSION_LABEL);
  });

  it('reports the pinned version when the config has one', async () => {
    await mkdir(path.join(dir, '.autoducks'), { recursive: true });
    await writeFile(path.join(dir, '.autoducks/autoducks.json'), JSON.stringify({ command: '', version: 'v1.2.3' }), 'utf8');

    const { pinnedVersion } = await resolveVersionInfo(dir);
    expect(pinnedVersion).toBe('v1.2.3');
  });

  it('reports the CLI package version', async () => {
    const pkg = JSON.parse(await readFile(path.join(REPO_ROOT, 'package.json'), 'utf8')) as { version: string };
    const { cliVersion } = await resolveVersionInfo(dir);
    expect(cliVersion).toBe(pkg.version);
  });
});

describe('VersionInfo', () => {
  it('renders both the CLI version and the pinned/unpinned autoducks version', () => {
    const { lastFrame } = render(<VersionInfo cliVersion="0.1.0" pinnedVersion={UNPINNED_VERSION_LABEL} />);
    const output = lastFrame() ?? '';
    expect(output).toContain('0.1.0');
    expect(output).toContain('unpinned');
  });

  it('renders a pinned version', () => {
    const { lastFrame } = render(<VersionInfo cliVersion="0.1.0" pinnedVersion="v1.2.3" />);
    expect(lastFrame()).toContain('v1.2.3');
  });
});
