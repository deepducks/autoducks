import React from 'react';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { render } from 'ink-testing-library';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildFieldDefs } from '../../src/core/config-fields.js';

const { bakeTriggersMock } = vi.hoisted(() => ({
  bakeTriggersMock: vi.fn(async () => ({ code: 0, stdout: '', stderr: '' })),
}));
vi.mock('../../src/core/triggers.js', () => ({
  bakeTriggers: bakeTriggersMock,
}));

// Imported after the mock so config.tsx picks up the mocked bakeTriggers.
const { ConfigEditor } = await import('../../src/commands/config.js');

const INITIAL_CONFIG = {
  command: '',
  defaults: { model: 'claude-sonnet-5', effort: 'high', base_branch: 'main', merge_method: 'auto' },
  review: { max_iterations: 3 },
  triggers: { architect: [], engineer: [] },
};

let dir: string;

// A real macrotask, not just `setImmediate`: Ink's `useInput` subscribes its listener in a
// passive effect, which is flushed by React's scheduler on its own timer. Ticking via
// `setImmediate` alone can race ahead of that flush right after a screen transition remounts
// a component, silently dropping the next keypress. A short real timer reliably outlasts it.
const tick = () => new Promise((resolve) => setTimeout(resolve, 20));

async function waitUntil(predicate: () => boolean, attempts = 50): Promise<void> {
  for (let i = 0; i < attempts; i += 1) {
    if (predicate()) {
      // The frame can repaint before Ink's `useInput` finishes subscribing its listener in a
      // passive effect (React flushes those on its own schedule, after commit) — give it a
      // few more real ticks to settle before the caller fires the next keypress, or that
      // keypress can land on the still-active previous screen and land nowhere at all.
      await tick();
      await tick();
      await tick();
      return;
    }
    await tick();
  }
  throw new Error('waitUntil: condition never became true');
}

beforeEach(async () => {
  bakeTriggersMock.mockClear();
  dir = await mkdtemp(path.join(tmpdir(), 'autoducks-config-cmd-test-'));
  await mkdir(path.join(dir, '.autoducks'), { recursive: true });
  await writeFile(path.join(dir, '.autoducks/autoducks.json'), JSON.stringify(INITIAL_CONFIG, null, 2), 'utf8');
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

function fieldIndex(path: string): number {
  const fields = buildFieldDefs(INITIAL_CONFIG);
  const index = fields.findIndex((field) => field.path === path);
  if (index === -1) throw new Error(`no such field: ${path}`);
  return index;
}

async function navigateMenuTo(stdin: { write: (data: string) => void }, downPresses: number): Promise<void> {
  for (let i = 0; i < downPresses; i += 1) {
    stdin.write('[B');
    await tick();
  }
  stdin.write('\r');
  await tick();
}

async function readConfig(): Promise<Record<string, unknown>> {
  const raw = await readFile(path.join(dir, '.autoducks/autoducks.json'), 'utf8');
  return JSON.parse(raw) as Record<string, unknown>;
}

describe('config command (ConfigEditor)', () => {
  it('editing an unrelated field saves it and does not re-bake triggers', async () => {
    let exitCode: number | undefined;
    const { lastFrame, stdin } = render(
      <ConfigEditor root={dir} isInteractive onExit={(code) => { exitCode = code; }} />,
    );

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));

    // Open the `defaults.model` select field (first field) and pick "opus".
    await navigateMenuTo(stdin, fieldIndex('defaults.model'));
    await waitUntil(() => (lastFrame() ?? '').includes('Default model'));
    stdin.write('[B'); // move off claude-sonnet-5 to opus
    await tick();
    stdin.write('\r');
    await tick();

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));

    // Save and exit is the second-to-last menu entry (after "Discard and exit").
    const totalFields = buildFieldDefs(INITIAL_CONFIG).length;
    await navigateMenuTo(stdin, totalFields);
    await waitUntil(() => exitCode !== undefined);

    expect(exitCode).toBe(0);
    expect(bakeTriggersMock).not.toHaveBeenCalled();

    const onDisk = await readConfig();
    expect((onDisk.defaults as Record<string, unknown>).model).toBe('opus');
    // Untouched fields survive the round-trip.
    expect((onDisk.defaults as Record<string, unknown>).base_branch).toBe('main');
    expect(onDisk.command).toBe('');
    expect(onDisk.triggers).toEqual(INITIAL_CONFIG.triggers);
  });

  it('editing a triggers.* field re-bakes triggers on save', async () => {
    let exitCode: number | undefined;
    const { lastFrame, stdin } = render(
      <ConfigEditor root={dir} isInteractive onExit={(code) => { exitCode = code; }} />,
    );

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));

    await navigateMenuTo(stdin, fieldIndex('triggers.architect'));
    await waitUntil(() => (lastFrame() ?? '').includes('Custom trigger aliases: architect'));
    stdin.write('spec');
    await tick();
    stdin.write('\r');
    await tick();

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));

    const totalFields = buildFieldDefs(INITIAL_CONFIG).length;
    await navigateMenuTo(stdin, totalFields);
    await waitUntil(() => exitCode !== undefined);

    expect(exitCode).toBe(0);
    expect(bakeTriggersMock).toHaveBeenCalledTimes(1);
    expect(bakeTriggersMock).toHaveBeenCalledWith(dir);

    const onDisk = await readConfig();
    expect((onDisk.triggers as Record<string, string[]>).architect).toEqual(['spec']);
  });

  it('rejects an invalid number before writing, and accepts the corrected value', async () => {
    const { lastFrame, stdin } = render(<ConfigEditor root={dir} isInteractive onExit={() => {}} />);

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));

    await navigateMenuTo(stdin, fieldIndex('review.max_iterations'));
    await waitUntil(() => (lastFrame() ?? '').includes('Max Review/Rework iterations'));

    // "99" exceeds the max of 10 — rejected inline, still on the edit screen.
    stdin.write('99');
    await tick();
    stdin.write('\r');
    await tick();
    await waitUntil(() => (lastFrame() ?? '').includes('must be'));
    expect(lastFrame()).toContain('Max Review/Rework iterations');

    // Correct it: erase the rejected "399" (initial "3" + typed "99") and retype.
    // Backspaces must be written one at a time — Ink's input parser only splits a
    // multi-character chunk on ESC bytes, so a batched '\b\b\b' would be parsed as one
    // literal (non-escape) run and appended verbatim instead of triggering 3 deletes.
    for (let i = 0; i < 3; i += 1) {
      stdin.write('\b');
      await tick();
    }
    stdin.write('5');
    await tick();
    stdin.write('\r');
    await tick();

    await waitUntil(() => (lastFrame() ?? '').includes('Select a field to edit'));
    expect(lastFrame()).not.toContain('must be');
  });
});
