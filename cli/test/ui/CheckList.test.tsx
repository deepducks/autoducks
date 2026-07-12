import React from 'react';
import { render } from 'ink-testing-library';
import { describe, expect, it } from 'vitest';
import { CheckList } from '../../src/ui/CheckList.js';
import type { CheckResult } from '../../src/types.js';

const CHECKS: CheckResult[] = [
  { id: 'node', title: 'Node.js version', status: 'pass' },
  { id: 'gh-auth', title: 'GitHub CLI auth', status: 'fail', message: 'not logged in', remediation: 'run `gh auth login`' },
  { id: 'branch-protection', title: 'Branch protection', status: 'manual', remediation: 'verify in repo settings' },
];

describe('CheckList', () => {
  it('renders a status glyph per check', () => {
    const { lastFrame } = render(<CheckList checks={CHECKS} />);
    const output = lastFrame();
    expect(output).toContain('✅');
    expect(output).toContain('❌');
    expect(output).toContain('⚠️');
  });

  it('renders remediation for failing/manual checks but not passing ones', () => {
    const { lastFrame } = render(<CheckList checks={CHECKS} />);
    const output = lastFrame();
    expect(output).toContain('run `gh auth login`');
    expect(output).toContain('verify in repo settings');
  });

  it('renders deterministically for an empty list', () => {
    const { lastFrame } = render(<CheckList checks={[]} />);
    expect(lastFrame()).toBe('');
  });
});
