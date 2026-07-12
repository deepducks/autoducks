import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { formatCommand, git, redactArgs } from '../src/core/gh.js';

describe('redactArgs', () => {
  it('replaces exact matches with a placeholder', () => {
    expect(redactArgs(['secret', 'set', 'TOKEN'], [])).toEqual(['secret', 'set', 'TOKEN']);
    expect(redactArgs(['secret', 'set', 'TOKEN', 'sk-super-secret-value'], ['sk-super-secret-value'])).toEqual([
      'secret',
      'set',
      'TOKEN',
      '***',
    ]);
  });

  it('leaves args untouched when nothing is redacted', () => {
    const args = ['issue', 'view', '123'];
    expect(redactArgs(args)).toBe(args);
  });
});

describe('formatCommand', () => {
  it('never includes a redacted secret value in the formatted string', () => {
    const formatted = formatCommand('gh', ['secret', 'set', 'ANTHROPIC_API_KEY', 'sk-super-secret-value'], [
      'sk-super-secret-value',
    ]);
    expect(formatted).not.toContain('sk-super-secret-value');
    expect(formatted).toBe('gh secret set ANTHROPIC_API_KEY ***');
  });
});

describe('debug logging', () => {
  const secretValue = 'sk-super-secret-value';
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    process.env.AUTODUCKS_DEBUG = '1';
    errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
  });

  afterEach(() => {
    delete process.env.AUTODUCKS_DEBUG;
    errorSpy.mockRestore();
  });

  it('never logs a redacted secret argument value', async () => {
    // `log --grep` is read-only; only the debug-logged command line matters here.
    await git(['log', '-1', '--grep', secretValue], { redact: [secretValue] });

    const loggedOutput = errorSpy.mock.calls.map((call) => call.join(' ')).join('\n');
    expect(loggedOutput).not.toContain(secretValue);
    expect(loggedOutput).toContain('***');
  });
});
