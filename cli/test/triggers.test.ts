// Ports the idempotence/mirror assertions from test/unit-update-triggers.sh
// to drive bakeTriggers() (src/core/triggers.ts), which shells out to the
// same scripts/update-triggers.sh rather than re-implementing it.
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { bakeTriggers } from '../src/core/triggers.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

let scratch: string;

beforeEach(async () => {
  scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-triggers-test-'));

  await fs.mkdir(path.join(scratch, '.autoducks', 'core', 'config'), { recursive: true });
  await fs.mkdir(path.join(scratch, '.autoducks', 'runtimes'), { recursive: true });
  await fs.mkdir(path.join(scratch, '.github'), { recursive: true });
  await fs.mkdir(path.join(scratch, 'scripts'), { recursive: true });

  await fs.copyFile(
    path.join(REPO_ROOT, '.autoducks', 'autoducks.json'),
    path.join(scratch, '.autoducks', 'autoducks.json'),
  );
  await fs.copyFile(
    path.join(REPO_ROOT, '.autoducks', 'core', 'config', 'generate-trigger-conditions.sh'),
    path.join(scratch, '.autoducks', 'core', 'config', 'generate-trigger-conditions.sh'),
  );
  await fs.cp(
    path.join(REPO_ROOT, '.autoducks', 'runtimes', 'github-actions'),
    path.join(scratch, '.autoducks', 'runtimes', 'github-actions'),
    { recursive: true },
  );
  await fs.cp(path.join(REPO_ROOT, '.github', 'workflows'), path.join(scratch, '.github', 'workflows'), {
    recursive: true,
  });
  await fs.copyFile(
    path.join(REPO_ROOT, 'scripts', 'update-triggers.sh'),
    path.join(scratch, 'scripts', 'update-triggers.sh'),
  );
});

afterEach(async () => {
  await fs.rm(scratch, { recursive: true, force: true });
});

describe('bakeTriggers', () => {
  it('reproduces the committed workflow guards from the shipped config', async () => {
    const result = await bakeTriggers(scratch);
    expect(result?.code).toBe(0);

    for (const file of await fs.readdir(path.join(REPO_ROOT, '.github', 'workflows'))) {
      const committed = await fs.readFile(path.join(REPO_ROOT, '.github', 'workflows', file));
      const regenerated = await fs.readFile(path.join(scratch, '.github', 'workflows', file));
      expect(Buffer.compare(regenerated, committed), `${file} differs from the committed guard`).toBe(0);
    }
  });

  it('is idempotent: a second run is byte-identical to the first', async () => {
    await bakeTriggers(scratch);
    const before = path.join(scratch, 'workflows-before');
    await fs.cp(path.join(scratch, '.github', 'workflows'), before, { recursive: true });

    await bakeTriggers(scratch);

    for (const file of await fs.readdir(before)) {
      const a = await fs.readFile(path.join(before, file));
      const b = await fs.readFile(path.join(scratch, '.github', 'workflows', file));
      expect(Buffer.compare(a, b)).toBe(0);
    }
  });

  it('mirrors every regenerated autoducks-*.yml runtime template into .github/workflows/', async () => {
    await bakeTriggers(scratch);

    const runtimeDir = path.join(scratch, '.autoducks', 'runtimes', 'github-actions');
    for (const file of await fs.readdir(runtimeDir)) {
      if (!file.startsWith('autoducks-') || !file.endsWith('.yml')) continue;
      const runtime = await fs.readFile(path.join(runtimeDir, file));
      const mirrored = await fs.readFile(path.join(scratch, '.github', 'workflows', file));
      expect(Buffer.compare(runtime, mirrored), `${file} mirror out of sync`).toBe(0);
    }
  });

  it('skips (returns undefined) when jq is unavailable', async () => {
    const fakeBin = path.join(scratch, 'fake-bin');
    await fs.mkdir(fakeBin, { recursive: true });

    const originalPath = process.env.PATH;
    // An empty bin dir with nothing else on PATH — jq (and everything else) unresolvable.
    process.env.PATH = fakeBin;
    try {
      const result = await bakeTriggers(scratch);
      expect(result).toBeUndefined();
    } finally {
      process.env.PATH = originalPath;
    }
  });
});
