import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { Select } from '../../src/ui/Select.js';

const OPTIONS = [
  { label: 'One', value: 'one' },
  { label: 'Two', value: 'two' },
  { label: 'Three', value: 'three' },
];

describe('Select', () => {
  it('under non-interactive mode, resolves to initialValue immediately without blocking', () => {
    const submitted: string[] = [];
    const { lastFrame } = render(
      <Select options={OPTIONS} initialValue="two" isInteractive={false} onSubmit={(value) => submitted.push(value)} />,
    );
    expect(submitted).toEqual(['two']);
    expect(lastFrame()).toContain('Two');
  });

  it('under non-interactive mode with no initialValue, resolves to the first option', () => {
    const submitted: string[] = [];
    render(<Select options={OPTIONS} isInteractive={false} onSubmit={(value) => submitted.push(value)} />);
    expect(submitted).toEqual(['one']);
  });

  it('under interactive mode, moves the pointer with arrow keys and submits on enter', async () => {
    const submitted: string[] = [];
    const { stdin } = render(<Select options={OPTIONS} isInteractive onSubmit={(value) => submitted.push(value)} />);
    const tick = () => new Promise((resolve) => setImmediate(resolve));

    stdin.write('[B'); // down arrow
    await tick();
    stdin.write('[B'); // down arrow
    await tick();
    stdin.write('\r'); // enter
    await tick();

    expect(submitted).toEqual(['three']);
  });
});
