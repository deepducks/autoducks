import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../src/core/gh.js', async () => {
  const actual = await vi.importActual<typeof import('../src/core/gh.js')>('../src/core/gh.js');
  return { ...actual, gh: vi.fn() };
});

import { gh } from '../src/core/gh.js';
import { resolveRef, resolveSourceDir, SOURCE_REPO } from '../src/core/release.js';

const ghMock = vi.mocked(gh);

describe('resolveRef', () => {
  beforeEach(() => {
    ghMock.mockReset();
  });

  it('an explicit --version tag wins outright, even on a fresh install', async () => {
    const resolved = await resolveRef({ version: 'v2.0.0', freshInstall: true });
    expect(resolved).toEqual({ ref: 'v2.0.0', tracksMain: false });
    expect(ghMock).not.toHaveBeenCalled();
  });

  it('--version main tracks main and skips release resolution', async () => {
    const resolved = await resolveRef({ version: 'main', freshInstall: true });
    expect(resolved).toEqual({ ref: 'main', tracksMain: true });
    expect(ghMock).not.toHaveBeenCalled();
  });

  it('--version edge also tracks main and skips release resolution', async () => {
    const resolved = await resolveRef({ version: 'edge', freshInstall: false, recordedVersion: 'v1.0.0' });
    expect(resolved).toEqual({ ref: 'main', tracksMain: true });
    expect(ghMock).not.toHaveBeenCalled();
  });

  it('a fresh install with no override takes the latest GitHub release', async () => {
    ghMock.mockResolvedValue({ code: 0, stdout: 'v3.1.0\n', stderr: '' });
    const resolved = await resolveRef({ freshInstall: true });
    expect(resolved).toEqual({ ref: 'v3.1.0', tracksMain: false });
    expect(ghMock).toHaveBeenCalledWith(
      ['release', 'view', '--json', 'tagName', '-q', '.tagName'],
      { repo: SOURCE_REPO },
    );
  });

  it('an update with no override keeps the recorded version, without consulting releases', async () => {
    const resolved = await resolveRef({ freshInstall: false, recordedVersion: 'v1.4.2' });
    expect(resolved).toEqual({ ref: 'v1.4.2', tracksMain: false });
    expect(ghMock).not.toHaveBeenCalled();
  });

  it('falls back to main with a warning when the source repo has no releases', async () => {
    ghMock.mockResolvedValue({ code: 1, stdout: '', stderr: 'no releases found' });
    const resolved = await resolveRef({ freshInstall: true });
    expect(resolved.ref).toBe('main');
    expect(resolved.tracksMain).toBe(true);
    expect(resolved.warning).toBeTruthy();
  });

  it('an update also falls back to main+warning when there is no recorded version and no releases exist', async () => {
    ghMock.mockResolvedValue({ code: 0, stdout: '', stderr: '' });
    const resolved = await resolveRef({ freshInstall: false });
    expect(resolved.ref).toBe('main');
    expect(resolved.tracksMain).toBe(true);
    expect(resolved.warning).toBeTruthy();
  });
});

describe('resolveSourceDir', () => {
  const originalSourceDir = process.env.AUTODUCKS_SOURCE_DIR;

  afterEach(() => {
    if (originalSourceDir === undefined) {
      delete process.env.AUTODUCKS_SOURCE_DIR;
    } else {
      process.env.AUTODUCKS_SOURCE_DIR = originalSourceDir;
    }
  });

  it('honors the AUTODUCKS_SOURCE_DIR offline seam instead of downloading', async () => {
    const seam = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-seam-'));
    process.env.AUTODUCKS_SOURCE_DIR = seam;

    const handle = await resolveSourceDir('v1.0.0');
    expect(handle.dir).toBe(seam);

    // cleanup() must be a no-op for the seam — it isn't ours to delete.
    await handle.cleanup();
    await expect(fs.access(seam)).resolves.toBeUndefined();

    await fs.rm(seam, { recursive: true, force: true });
  });
});
