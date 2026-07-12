import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { Help } from '../../src/commands/help.js';

describe('Help', () => {
  it('prints the full usage block with no command given, under a Logo header', () => {
    const { lastFrame } = render(<Help />);
    const output = lastFrame() ?? '';
    expect(output).toContain('autoducks'); // Logo header
    expect(output).toContain('Commands:');
    for (const command of ['install', 'update', 'setup', 'wizard', 'config', 'plugin', 'version', 'help']) {
      expect(output).toContain(command);
    }
    expect(output).toContain('Global options:');
  });

  it('prints per-command detail for a known command', () => {
    const { lastFrame } = render(<Help command="config" />);
    const output = lastFrame() ?? '';
    expect(output).toContain('autoducks config');
    expect(output).toContain('visual configuration editor');
  });

  it('flags an unknown command', () => {
    const { lastFrame } = render(<Help command="frobnicate" />);
    expect(lastFrame()).toContain('Unknown command: frobnicate');
  });
});
