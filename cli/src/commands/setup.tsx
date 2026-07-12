import React from 'react';
import { render } from 'ink';
import type { CheckResult, CommandModule } from '../types.js';
import { dispatchCommand } from '../core/registry.js';
import {
  checkActionsPermissions,
  checkGithubApp,
  checkSecrets,
  fixActionsPermissions,
  fixSecret,
  runAll,
  type CheckContext,
} from '../core/checks.js';
import { CheckList } from '../ui/CheckList.js';
import { Confirm } from '../ui/Confirm.js';
import { TextInput } from '../ui/TextInput.js';

/** Checks with a known idempotent auto-fix that setup can offer interactively. */
const REFRESH_AFTER_FIX: Record<string, (ctx: CheckContext) => Promise<CheckResult>> = {
  secrets: checkSecrets,
  'actions-permissions': checkActionsPermissions,
  'github-app': checkGithubApp,
};

function renderChecks(checks: CheckResult[]): void {
  const instance = render(<CheckList checks={checks} />, { patchConsole: false });
  instance.unmount();
}

function confirmPrompt(message: string, defaultValue: boolean, isInteractive: boolean): Promise<boolean> {
  return new Promise((resolve) => {
    const instance = render(
      <Confirm
        message={message}
        defaultValue={defaultValue}
        isInteractive={isInteractive}
        onConfirm={(value) => {
          instance.unmount();
          resolve(value);
        }}
      />,
      { patchConsole: false },
    );
  });
}

function textPrompt(message: string, isInteractive: boolean, mask: boolean): Promise<string> {
  return new Promise((resolve) => {
    const instance = render(
      <TextInput
        message={message}
        mask={mask}
        isInteractive={isInteractive}
        onSubmit={(value) => {
          instance.unmount();
          resolve(value);
        }}
      />,
      { patchConsole: false },
    );
  });
}

/** Applies the interactive fix for `check`, if one exists and the user opts in. Returns true if a fix was applied. */
async function attemptFix(checkCtx: CheckContext, check: CheckResult, promptable: boolean): Promise<boolean> {
  if (check.id === 'secrets') {
    const attempt = await confirmPrompt('Set the ANTHROPIC_API_KEY secret now?', false, promptable);
    if (!attempt) return false;
    const value = await textPrompt('ANTHROPIC_API_KEY:', promptable, true);
    if (!value) return false;
    return fixSecret(checkCtx, 'ANTHROPIC_API_KEY', value);
  }
  if (check.id === 'actions-permissions') {
    const attempt = await confirmPrompt('Apply the required Actions workflow permissions now (needs admin)?', false, promptable);
    if (!attempt) return false;
    return fixActionsPermissions(checkCtx);
  }
  if (check.id === 'github-app') {
    const attempt = await confirmPrompt('Install the Claude Code GitHub App, then press enter to re-check', true, promptable);
    return attempt;
  }
  return false;
}

export const run: CommandModule['run'] = async (ctx) => {
  const cwd = process.cwd();
  const checkCtx: CheckContext = { cwd, repo: ctx.options.repo };
  const promptable = ctx.isInteractive && !ctx.options.yes;

  const results = await runAll(checkCtx);
  renderChecks(results);

  if (promptable) {
    for (let i = 0; i < results.length; i++) {
      const check = results[i];
      if (!check || check.status === 'pass') continue;
      const refresh = REFRESH_AFTER_FIX[check.id];
      if (!refresh) continue;

      const fixed = await attemptFix(checkCtx, check, promptable);
      if (fixed) {
        results[i] = await refresh(checkCtx);
      }
    }
    renderChecks(results);
  }

  return dispatchCommand('wizard', ctx);
};
