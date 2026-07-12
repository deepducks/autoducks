import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { MultiSelect } from '../../src/ui/MultiSelect.js';

const OPTIONS = [
  { label: 'One', value: 'one' },
  { label: 'Two', value: 'two' },
  { label: 'Three', value: 'three' },
];

describe('MultiSelect', () => {
  it('under non-interactive mode, resolves to initialValues immediately without blocking', () => {
    const submitted: string[][] = [];
    const { lastFrame } = render(
      <MultiSelect
        options={OPTIONS}
        initialValues={['two']}
        isInteractive={false}
        onSubmit={(values) => submitted.push(values)}
      />,
    );
    expect(submitted).toEqual([['two']]);
    expect(lastFrame()).toContain('Two');
  });

  it('under non-interactive mode with no initialValues, resolves to an empty selection', () => {
    const submitted: string[][] = [];
    render(<MultiSelect options={OPTIONS} isInteractive={false} onSubmit={(values) => submitted.push(values)} />);
    expect(submitted).toEqual([[]]);
  });

  it('under interactive mode, toggles a checkbox with space and submits the selection on enter', async () => {
    const submitted: string[][] = [];
    const { stdin } = render(
      <MultiSelect options={OPTIONS} isInteractive onSubmit={(values) => submitted.push(values)} />,
    );
    const tick = () => new Promise((resolve) => setImmediate(resolve));

    stdin.write(' '); // toggle "One"
    await tick();
    stdin.write('\x1B[B'); // down arrow
    await tick();
    stdin.write(' '); // toggle "Two"
    await tick();
    stdin.write('\r'); // enter
    await tick();

    expect(submitted).toEqual([['one', 'two']]);
  });
});
