/**
 * Global options accepted by every command, parsed once in `index.tsx` and
 * threaded through to whichever command module the dispatcher resolves.
 */
export interface GlobalOptions {
  repo?: string;
  version?: string;
  noInput: boolean;
  yes: boolean;
  help: boolean;
}

/** Context passed to a command's `run()` entrypoint. */
export interface CommandContext {
  /** The command name as invoked (e.g. "update", not the module it resolved to). */
  command: string;
  /** Remaining positional args after the command name. */
  args: string[];
  options: GlobalOptions;
  /** True when stdout is a TTY and `--no-input` was not passed. */
  isInteractive: boolean;
}

export type CommandRun = (ctx: CommandContext) => Promise<number>;

/** Uniform shape every command module under `src/commands/` must export. */
export interface CommandModule {
  run: CommandRun;
}

/**
 * Generic result shape for a single check/step (setup checks, install
 * steps, etc.), shared so future tasks don't invent their own variants.
 */
export interface CheckResult {
  id: string;
  title: string;
  status: 'pass' | 'fail' | 'manual';
  message?: string;
  remediation?: string;
}

/**
 * Re-export point for the `.autoducks/autoducks.json` config shape, owned
 * by `core/config.ts` — other modules should import `AutoducksConfig` from
 * here rather than reaching into `core/config.js` directly.
 */
export type { AutoducksConfig } from './core/config.js';
