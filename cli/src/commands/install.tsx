import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandModule } from '../types.js';
import { dispatchCommand } from '../core/registry.js';
import { resolveRef, resolveSourceDir } from '../core/release.js';
import { install as installEngine, isFreshInstall, readRecordedVersion } from '../core/installer.js';
import { bakeTriggers } from '../core/triggers.js';
import { theme } from '../ui/theme.js';

export interface InstallStep {
  id: string;
  label: string;
  status: 'pending' | 'done' | 'error';
  detail?: string;
}

function InstallProgress({ steps, message }: { steps: InstallStep[]; message?: string }) {
  const glyph = (status: InstallStep['status']) =>
    status === 'pending' ? theme.glyphs.uncheckedBox : status === 'error' ? theme.glyphs.fail : theme.glyphs.pass;
  const color = (status: InstallStep['status']) =>
    status === 'pending' ? theme.colors.muted : status === 'error' ? theme.colors.error : theme.colors.success;

  return (
    <Box flexDirection="column">
      {steps.map((step) => (
        <Text key={step.id}>
          <Text color={color(step.status)}>{glyph(step.status)}</Text> {step.label}
          {step.detail ? <Text color={theme.colors.muted}> — {step.detail}</Text> : null}
        </Text>
      ))}
      {message ? <Text>{message}</Text> : null}
    </Box>
  );
}

/**
 * Pure: decides whether a completed install/update should continue into
 * `setup` and the hint line to print. Fresh installs continue unless
 * `--no-setup` was passed; updates always stop with a re-run hint.
 */
export function describeInstallOutcome(opts: { freshInstall: boolean; noSetup: boolean; version: string }): {
  continueToSetup: boolean;
  message: string;
} {
  if (opts.freshInstall) {
    if (opts.noSetup) {
      return { continueToSetup: false, message: 'Skipping setup (--no-setup). Run `autoducks setup` to configure your repo.' };
    }
    return { continueToSetup: true, message: 'Continuing into setup...' };
  }
  return { continueToSetup: false, message: `Updated to ${opts.version}. Run \`autoducks setup\` to re-run setup checks.` };
}

// Also resolved for the `update` command name (see core/registry.ts).
export const run: CommandModule['run'] = async (ctx) => {
  const cwd = process.cwd();
  const steps: InstallStep[] = [
    { id: 'resolve', label: 'Resolving version to install', status: 'pending' },
    { id: 'source', label: 'Fetching autoducks source', status: 'pending' },
    { id: 'install', label: 'Installing .autoducks + .github files', status: 'pending' },
    { id: 'triggers', label: 'Baking custom trigger aliases', status: 'pending' },
  ];
  let message: string | undefined;
  const instance = render(<InstallProgress steps={steps} message={message} />, { patchConsole: false });
  const redraw = () => instance.rerender(<InstallProgress steps={steps} message={message} />);
  const finish = (id: string, status: InstallStep['status'], detail?: string) => {
    const step = steps.find((s) => s.id === id);
    if (step) {
      step.status = status;
      step.detail = detail;
    }
    redraw();
  };

  try {
    const freshInstall = await isFreshInstall(cwd);
    const recordedVersion = await readRecordedVersion(cwd);
    const resolved = await resolveRef({ version: ctx.options.version, freshInstall, recordedVersion });
    finish('resolve', 'done', resolved.ref);
    if (resolved.warning) message = resolved.warning;

    const source = await resolveSourceDir(resolved.ref);
    try {
      finish('source', 'done');

      const result = await installEngine({ cwd, sourceDir: source.dir, version: resolved.ref });
      finish('install', 'done');

      const triggerResult = await bakeTriggers(cwd);
      finish('triggers', 'done', triggerResult && triggerResult.code !== 0 ? triggerResult.stderr : undefined);

      const outcome = describeInstallOutcome({ freshInstall: result.freshInstall, noSetup: ctx.options.noSetup, version: resolved.ref });
      message = message ? `${message}\n${outcome.message}` : outcome.message;
      redraw();
      instance.unmount();

      if (outcome.continueToSetup) {
        return dispatchCommand('setup', ctx);
      }
      return 0;
    } finally {
      await source.cleanup();
    }
  } catch (err) {
    message = err instanceof Error ? err.message : String(err);
    redraw();
    instance.unmount();
    return 1;
  }
};
