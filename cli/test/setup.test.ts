import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { CommandContext } from '../src/types.js';

const runAllMock = vi.fn();
const checkSecretsMock = vi.fn();
const checkActionsPermissionsMock = vi.fn();
const checkGithubAppMock = vi.fn();
const fixSecretMock = vi.fn();
const fixActionsPermissionsMock = vi.fn();

vi.mock('../src/core/checks.js', () => ({
  runAll: (...args: unknown[]) => runAllMock(...args),
  checkSecrets: (...args: unknown[]) => checkSecretsMock(...args),
  checkActionsPermissions: (...args: unknown[]) => checkActionsPermissionsMock(...args),
  checkGithubApp: (...args: unknown[]) => checkGithubAppMock(...args),
  fixSecret: (...args: unknown[]) => fixSecretMock(...args),
  fixActionsPermissions: (...args: unknown[]) => fixActionsPermissionsMock(...args),
}));

const dispatchCommandMock = vi.fn(async () => 0);
vi.mock('../src/core/registry.js', () => ({
  dispatchCommand: (...args: unknown[]) => dispatchCommandMock(...args),
}));

const { run } = await import('../src/commands/setup.js');

describe('setup run()', () => {
  beforeEach(() => {
    runAllMock.mockReset();
    checkSecretsMock.mockReset();
    checkActionsPermissionsMock.mockReset();
    checkGithubAppMock.mockReset();
    fixSecretMock.mockReset();
    fixActionsPermissionsMock.mockReset();
    dispatchCommandMock.mockReset();
    dispatchCommandMock.mockResolvedValue(0);
  });

  it('under --no-input, reports checks without attempting any fix, then dispatches to wizard', async () => {
    runAllMock.mockResolvedValue([
      { id: 'gh-auth', title: 'GitHub CLI authentication', status: 'pass', message: 'ok' },
      { id: 'secrets', title: 'Required secrets', status: 'manual', message: 'missing', remediation: 'set it' },
      { id: 'actions-permissions', title: 'Actions workflow permissions', status: 'manual', message: 'wrong' },
    ]);

    const ctx: CommandContext = {
      command: 'setup',
      args: [],
      options: { noInput: true, noSetup: false, yes: false, help: false },
      isInteractive: false,
    };

    const code = await run(ctx);

    expect(code).toBe(0);
    expect(runAllMock).toHaveBeenCalledTimes(1);
    expect(fixSecretMock).not.toHaveBeenCalled();
    expect(fixActionsPermissionsMock).not.toHaveBeenCalled();
    expect(checkSecretsMock).not.toHaveBeenCalled();
    expect(checkActionsPermissionsMock).not.toHaveBeenCalled();
    expect(dispatchCommandMock).toHaveBeenCalledTimes(1);
    expect(dispatchCommandMock).toHaveBeenCalledWith('wizard', ctx);
  });

  it('under --yes on a TTY, also skips fixes without blocking', async () => {
    runAllMock.mockResolvedValue([{ id: 'gh-auth', title: 'GitHub CLI authentication', status: 'pass', message: 'ok' }]);

    const ctx: CommandContext = {
      command: 'setup',
      args: [],
      options: { noInput: false, noSetup: false, yes: true, help: false },
      isInteractive: true,
    };

    const code = await run(ctx);

    expect(code).toBe(0);
    expect(dispatchCommandMock).toHaveBeenCalledWith('wizard', ctx);
  });
});
