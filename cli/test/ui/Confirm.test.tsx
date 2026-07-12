import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { Confirm } from '../../src/ui/Confirm.js';

describe('Confirm', () => {
  it('under non-interactive mode, resolves to defaultValue immediately without blocking', () => {
    const submitted: boolean[] = [];
    const { lastFrame } = render(
      <Confirm message="Proceed?" defaultValue={false} isInteractive={false} onConfirm={(value) => submitted.push(value)} />,
    );
    expect(submitted).toEqual([false]);
    expect(lastFrame()).toContain('Proceed?');
  });

  it('under non-interactive mode with no defaultValue, resolves to true', () => {
    const submitted: boolean[] = [];
    render(<Confirm message="Proceed?" isInteractive={false} onConfirm={(value) => submitted.push(value)} />);
    expect(submitted).toEqual([true]);
  });

  it('under interactive mode, answers y/n directly', async () => {
    const submitted: boolean[] = [];
    const { stdin } = render(
      <Confirm message="Proceed?" isInteractive onConfirm={(value) => submitted.push(value)} />,
    );
    const tick = () => new Promise((resolve) => setImmediate(resolve));

    stdin.write('n');
    await tick();

    expect(submitted).toEqual([false]);
  });

  it('under interactive mode, enter resolves to defaultValue', async () => {
    const submitted: boolean[] = [];
    const { stdin } = render(
      <Confirm message="Proceed?" defaultValue={false} isInteractive onConfirm={(value) => submitted.push(value)} />,
    );
    const tick = () => new Promise((resolve) => setImmediate(resolve));

    stdin.write('\r');
    await tick();

    expect(submitted).toEqual([false]);
  });
});
