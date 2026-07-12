import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AUTOS } from '../src/core/autos.js';
import type { CommandContext } from '../src/types.js';
import { RECOMMENDED_DEFAULTS, buildAutosUpdates, isAutoEnabled, run, triggersChanged } from '../src/commands/wizard.js';

function auto(id: string) {
  const found = AUTOS.find((a) => a.id === id);
  if (!found) throw new Error(`no such auto: ${id}`);
  return found;
}

describe('isAutoEnabled', () => {
  it('falls back to the shipped schema default when the key is unset', () => {
    expect(isAutoEnabled({}, auto('auto_checks'))).toBe(false);
    expect(isAutoEnabled({}, auto('auto_groom'))).toBe(true);
    expect(isAutoEnabled({}, auto('orchestration_mode'))).toBe(true);
    expect(isAutoEnabled({}, auto('auto_resolve'))).toBe(true);
  });

  it('reads the actual value when present', () => {
    expect(isAutoEnabled({ checks: { enabled: true } }, auto('auto_checks'))).toBe(true);
    expect(isAutoEnabled({ checks: { enabled: false } }, auto('auto_checks'))).toBe(false);
  });

  it('treats orchestrator.mode="sequential" as disabled and "waves" as enabled', () => {
    expect(isAutoEnabled({ orchestrator: { mode: 'sequential' } }, auto('orchestration_mode'))).toBe(false);
    expect(isAutoEnabled({ orchestrator: { mode: 'waves' } }, auto('orchestration_mode'))).toBe(true);
  });
});

describe('buildAutosUpdates', () => {
  it('writes the mapped config key for every selected auto (T2 table)', () => {
    const updates = buildAutosUpdates(['auto_groom', 'auto_checks', 'orchestration_mode']);
    expect(updates.product?.enabled).toBe(true);
    expect(updates.product?.schedule).toBe('0 9 * * *');
    expect(updates.checks?.enabled).toBe(true);
    expect(updates.orchestrator?.mode).toBe('waves');
    expect(updates.resolver?.auto).toBe(false);
    expect(updates.review?.auto_rework).toBe(false);
    expect(updates.architect?.auto).toBe(false);
    expect(updates.engineer?.auto).toBe(false);
    expect(updates.reviewer?.auto).toBe(false);
  });

  it('an empty selection writes every auto to its manual value', () => {
    const updates = buildAutosUpdates([]);
    expect(updates.product?.enabled).toBe(false);
    expect(updates.orchestrator?.mode).toBe('sequential');
    expect(updates.checks?.enabled).toBe(false);
    expect(updates.resolver?.auto).toBe(false);
    expect(updates.review?.auto_rework).toBe(false);
    expect(updates.architect?.auto).toBe(false);
    expect(updates.engineer?.auto).toBe(false);
    expect(updates.reviewer?.auto).toBe(false);
  });
});

describe('triggersChanged', () => {
  it('detects a command change', () => {
    expect(triggersChanged({ command: 'a' }, { command: 'b' })).toBe(true);
    expect(triggersChanged({ command: 'a' }, { command: 'a' })).toBe(false);
  });

  it('detects a triggers.* change', () => {
    expect(triggersChanged({ triggers: { developer: ['x'] } }, { triggers: { developer: ['x', 'y'] } })).toBe(true);
    expect(triggersChanged({ triggers: { developer: ['x'] } }, { triggers: { developer: ['x'] } })).toBe(false);
  });

  it('treats absent triggers/command on both sides as unchanged', () => {
    expect(triggersChanged({}, {})).toBe(false);
  });
});

describe('RECOMMENDED_DEFAULTS', () => {
  it('matches the documented shipped defaults', () => {
    expect(RECOMMENDED_DEFAULTS).toEqual({
      defaults: { model: 'claude-sonnet-5', effort: 'high' },
      orchestrator: { mode: 'waves' },
      review: { max_iterations: 3 },
    });
  });
});

describe('run — non-blocking resolution', () => {
  let dir: string;
  let originalCwd: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'autoducks-wizard-test-'));
    await mkdir(path.join(dir, '.autoducks'), { recursive: true });
    originalCwd = process.cwd();
    process.chdir(dir);
  });

  afterEach(async () => {
    process.chdir(originalCwd);
    await rm(dir, { recursive: true, force: true });
  });

  it('under --no-input, selects recommended defaults and the shipped auto defaults without prompting', async () => {
    const ctx: CommandContext = {
      command: 'wizard',
      args: [],
      options: { noInput: true, noSetup: false, yes: false, help: false },
      isInteractive: false,
    };

    const code = await run(ctx);
    expect(code).toBe(0);

    const written = JSON.parse(await readFile(path.join(dir, '.autoducks', 'autoducks.json'), 'utf8'));
    expect(written.defaults).toEqual({ model: 'claude-sonnet-5', effort: 'high' });
    expect(written.orchestrator?.mode).toBe('waves');
    expect(written.review?.max_iterations).toBe(3);
    expect(written.product?.enabled).toBe(true);
    expect(written.checks?.enabled).toBe(false);
  });

  it('under --yes on a TTY, also resolves to recommended defaults without prompting', async () => {
    const ctx: CommandContext = {
      command: 'wizard',
      args: [],
      options: { noInput: false, noSetup: false, yes: true, help: false },
      isInteractive: true,
    };

    const code = await run(ctx);
    expect(code).toBe(0);

    const written = JSON.parse(await readFile(path.join(dir, '.autoducks', 'autoducks.json'), 'utf8'));
    expect(written.defaults?.effort).toBe('high');
    expect(written.orchestrator?.mode).toBe('waves');
  });
});
