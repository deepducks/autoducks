import mri from 'mri';
import type { GlobalOptions } from '../types.js';

export interface ParsedArgv {
  command: string | undefined;
  args: string[];
  options: GlobalOptions;
}

/**
 * Parses argv (already stripped of `node`/script path) into a command name,
 * its remaining positional args, and the global options every command
 * receives. Pure function so it's unit-testable without spawning the CLI.
 */
export function parseArgv(argv: string[]): ParsedArgv {
  const parsed = mri(argv, {
    string: ['repo', 'version'],
    boolean: ['no-input', 'yes', 'help'],
    alias: { h: 'help' },
  });

  const [command, ...rest] = parsed._.map(String);

  return {
    command,
    args: rest,
    options: {
      repo: typeof parsed.repo === 'string' ? parsed.repo : undefined,
      version: typeof parsed.version === 'string' ? parsed.version : undefined,
      noInput: Boolean(parsed['no-input']),
      yes: Boolean(parsed.yes),
      help: Boolean(parsed.help),
    },
  };
}
