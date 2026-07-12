import type { CommandModule } from '../types.js';

/**
 * Static name -> lazy module registry the dispatcher resolves commands
 * through. Later tasks add their own command modules without editing the
 * dispatcher (`index.tsx`) or this map's callers — only this list grows.
 */
export const COMMANDS: Record<string, () => Promise<CommandModule>> = {
  install: () => import('../commands/install.js'),
  update: () => import('../commands/install.js'),
  setup: () => import('../commands/setup.js'),
  wizard: () => import('../commands/wizard.js'),
  config: () => import('../commands/config.js'),
  plugin: () => import('../commands/plugin/index.js'),
  version: () => import('../commands/version.js'),
  help: () => import('../commands/help.js'),
};

export function resolveCommand(name: string): (() => Promise<CommandModule>) | undefined {
  return COMMANDS[name];
}
