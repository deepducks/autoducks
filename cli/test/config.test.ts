import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  UNPINNED_VERSION_LABEL,
  applyDefaults,
  deepMerge,
  getVersion,
  load,
  setVersion,
  validate,
  write,
} from '../src/core/config.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

describe('validate', () => {
  it('accepts the repository’s own shipped config unchanged', async () => {
    const raw = await readFile(path.join(REPO_ROOT, '.autoducks/autoducks.json'), 'utf8');
    const result = validate(JSON.parse(raw));
    expect(result.errors).toEqual([]);
    expect(result.valid).toBe(true);
  });

  it('rejects an out-of-enum value', () => {
    const result = validate({ defaults: { effort: 'turbo' } });
    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.join('\n')).toContain('effort');
  });

  it('tolerates unknown top-level and nested fields (additive)', () => {
    const result = validate({ someFutureBlock: { anything: true }, defaults: { someFutureField: 1 } });
    expect(result.valid).toBe(true);
  });
});

describe('applyDefaults', () => {
  it('defaults architect.auto, engineer.auto, and reviewer.auto to true when absent', () => {
    const defaulted = applyDefaults({ reviewer: { check_name: 'X' } });
    expect(defaulted.architect?.auto).toBe(true);
    expect(defaulted.engineer?.auto).toBe(true);
    expect(defaulted.reviewer?.auto).toBe(true);
    // Preserves unrelated sibling fields.
    expect(defaulted.reviewer?.check_name).toBe('X');
  });

  it('leaves explicit false values alone', () => {
    const defaulted = applyDefaults({ architect: { auto: false } });
    expect(defaulted.architect?.auto).toBe(false);
  });
});

describe('version helpers', () => {
  it('reports the unpinned label when version is absent', () => {
    expect(getVersion({})).toBe(UNPINNED_VERSION_LABEL);
  });

  it('reads back a pinned version', () => {
    expect(getVersion({ version: 'v1.2.3' })).toBe('v1.2.3');
  });

  it('setVersion is a pure transform that only touches version', () => {
    const original = { command: '', version: undefined };
    const updated = setVersion(original, 'v1.2.3');
    expect(updated.version).toBe('v1.2.3');
    expect(updated.command).toBe('');
    expect(original.version).toBeUndefined();
  });
});

describe('deepMerge', () => {
  it('never drops or reorders unrelated existing keys', () => {
    const base = { a: 1, b: { c: 2, d: 3 }, e: 4 };
    const merged = deepMerge(base, { b: { c: 20 } });
    expect(Object.keys(merged)).toEqual(['a', 'b', 'e']);
    expect(Object.keys(merged.b)).toEqual(['c', 'd']);
    expect(merged).toEqual({ a: 1, b: { c: 20, d: 3 }, e: 4 });
  });
});

describe('load / write round-trip', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'autoducks-config-test-'));
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('loads a config lacking version/*.auto with correct defaults', async () => {
    await mkdir(path.join(dir, '.autoducks'), { recursive: true });
    await writeFile(path.join(dir, '.autoducks/autoducks.json'), JSON.stringify({ command: '' }, null, 2), 'utf8');

    const { config } = await load(dir);
    expect(getVersion(config)).toBe(UNPINNED_VERSION_LABEL);
    expect(config.architect?.auto).toBe(true);
    expect(config.engineer?.auto).toBe(true);
    expect(config.reviewer?.auto).toBe(true);
  });

  it('write() preserves untouched fields through a load → write round-trip', async () => {
    await mkdir(path.join(dir, '.autoducks'), { recursive: true });
    const initial = {
      command: '',
      providers: { its: 'github', git: 'github', llm: 'claude' },
      defaults: { model: 'claude-sonnet-5', effort: 'high' },
      product: { enabled: true, schedule: '0 9 * * *' },
    };
    await writeFile(path.join(dir, '.autoducks/autoducks.json'), JSON.stringify(initial, null, 2), 'utf8');

    const merged = await write(dir, { orchestrator: { mode: 'sequential' } });
    expect(merged.orchestrator?.mode).toBe('sequential');
    expect(merged.providers).toEqual(initial.providers);
    expect(merged.defaults).toEqual(initial.defaults);
    expect(merged.product).toEqual(initial.product);

    const raw = await readFile(path.join(dir, '.autoducks/autoducks.json'), 'utf8');
    const onDisk = JSON.parse(raw);
    expect(onDisk.providers).toEqual(initial.providers);
    expect(onDisk.command).toBe('');
  });

  it('write() refuses to persist an invalid merge', async () => {
    await mkdir(path.join(dir, '.autoducks'), { recursive: true });
    await writeFile(path.join(dir, '.autoducks/autoducks.json'), JSON.stringify({ command: '' }, null, 2), 'utf8');

    await expect(write(dir, { defaults: { effort: 'turbo' as never } })).rejects.toThrow();
  });
});
