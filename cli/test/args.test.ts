import { describe, expect, it } from 'vitest';
import { parseArgv } from '../src/core/args.js';

describe('parseArgv', () => {
  it('parses the command and remaining positional args', () => {
    const result = parseArgv(['plugin', 'install', 'foo']);
    expect(result.command).toBe('plugin');
    expect(result.args).toEqual(['install', 'foo']);
  });

  it('parses global options', () => {
    const result = parseArgv(['install', '--repo', 'owner/repo', '--version', 'v1.2.3', '--no-input', '--yes']);
    expect(result.options).toEqual({
      repo: 'owner/repo',
      version: 'v1.2.3',
      noInput: true,
      yes: true,
      help: false,
    });
  });

  it('treats -h as an alias for --help', () => {
    expect(parseArgv(['-h']).options.help).toBe(true);
    expect(parseArgv(['--help']).options.help).toBe(true);
  });

  it('returns an undefined command and default options when argv is empty', () => {
    const result = parseArgv([]);
    expect(result.command).toBeUndefined();
    expect(result.args).toEqual([]);
    expect(result.options.noInput).toBe(false);
    expect(result.options.help).toBe(false);
  });
});
