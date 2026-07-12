import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { TextInput } from '../../src/ui/TextInput.js';

describe('TextInput', () => {
  it('under non-interactive mode, resolves to initialValue immediately without blocking', () => {
    const submitted: string[] = [];
    const { lastFrame } = render(
      <TextInput initialValue="prefilled" isInteractive={false} onSubmit={(value) => submitted.push(value)} />,
    );
    expect(submitted).toEqual(['prefilled']);
    expect(lastFrame()).toContain('prefilled');
  });

  it('under non-interactive mode with no initialValue, resolves to an empty string', () => {
    const submitted: string[] = [];
    render(<TextInput isInteractive={false} onSubmit={(value) => submitted.push(value)} />);
    expect(submitted).toEqual(['']);
  });

  it('masks the rendered value when mask is set', () => {
    const { lastFrame } = render(
      <TextInput initialValue="secret" mask isInteractive={false} onSubmit={() => {}} />,
    );
    expect(lastFrame()).toContain('******');
    expect(lastFrame()).not.toContain('secret');
  });

  it('under interactive mode, types characters and submits on enter', async () => {
    const submitted: string[] = [];
    const { stdin } = render(<TextInput isInteractive onSubmit={(value) => submitted.push(value)} />);
    const tick = () => new Promise((resolve) => setImmediate(resolve));

    stdin.write('hi');
    await tick();
    stdin.write('\r');
    await tick();

    expect(submitted).toEqual(['hi']);
  });
});
