import React from 'react';
import { Text } from 'ink';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { Logo } from '../../src/ui/Logo.js';

describe('Logo', () => {
  it('renders the static full logo when not a TTY', () => {
    const { lastFrame } = render(<Logo isTTY={false} />);
    expect(lastFrame()).toMatch(/█/);
  });

  it('renders the static compact logo when not a TTY and variant is compact', () => {
    const { lastFrame } = render(<Logo isTTY={false} variant="compact" />);
    expect(lastFrame()).toContain('autoducks');
  });

  it('renders the animated slot when isTTY and a renderer is provided', () => {
    const { lastFrame } = render(<Logo isTTY renderAnimated={() => <Text>ANIMATED</Text>} />);
    expect(lastFrame()).toContain('ANIMATED');
  });

  it('falls back to the static logo when isTTY but no renderer is provided', () => {
    const { lastFrame } = render(<Logo isTTY />);
    expect(lastFrame()).toMatch(/█/);
  });

  it('falls back to the static logo when the animated renderer throws', () => {
    const { lastFrame } = render(
      <Logo
        isTTY
        renderAnimated={() => {
          throw new Error('animation unavailable');
        }}
      />,
    );
    expect(lastFrame()).toMatch(/█/);
  });

  it('falls back to the static logo when the animated renderer returns nothing', () => {
    const { lastFrame } = render(<Logo isTTY renderAnimated={() => null} />);
    expect(lastFrame()).toMatch(/█/);
  });
});
