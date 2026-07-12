import { describe, expect, it } from 'vitest';
import { dispatchCommand, resolveCommand } from '../src/core/registry.js';
import type { CommandContext } from '../src/types.js';

const EXPECTED_COMMANDS = ['install', 'update', 'setup', 'wizard', 'config', 'plugin', 'version', 'help'];

describe('resolveCommand', () => {
  it('resolves every command listed in the usage block to a module', async () => {
    for (const name of EXPECTED_COMMANDS) {
      const resolve = resolveCommand(name);
      expect(resolve, `expected "${name}" to resolve`).toBeTypeOf('function');
      const mod = await resolve!();
      expect(mod.run, `expected "${name}" module to export run()`).toBeTypeOf('function');
    }
  });

  it('maps update to the same module as install', async () => {
    const install = await resolveCommand('install')!();
    const update = await resolveCommand('update')!();
    expect(update.run).toBe(install.run);
  });

  it('returns undefined for an unknown command', () => {
    expect(resolveCommand('frobnicate')).toBeUndefined();
  });
});

describe('dispatchCommand', () => {
  it('throws on an unknown command instead of hanging', async () => {
    const ctx: CommandContext = {
      command: 'install',
      args: [],
      options: { noInput: true, noSetup: false, yes: false, help: false },
      isInteractive: false,
    };
    await expect(dispatchCommand('frobnicate', ctx)).rejects.toThrow('Unknown command: frobnicate');
  });
});
