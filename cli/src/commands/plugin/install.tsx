import React from 'react';
import { render, Text } from 'ink';
import type { CommandModule } from '../../types.js';
import { theme } from '../../ui/theme.js';
import { fetchIndex, resolvePluginBundle, install as installPlugin, uninstall as uninstallPlugin } from '../../core/plugins.js';

interface OutcomeProps {
  ok: boolean;
  message: string;
}

function Outcome({ ok, message }: OutcomeProps) {
  return (
    <Text color={ok ? theme.colors.success : theme.colors.error}>
      {ok ? theme.glyphs.pass : theme.glyphs.fail} {message}
    </Text>
  );
}

async function runInstall(name: string): Promise<OutcomeProps> {
  let index;
  try {
    index = await fetchIndex(process.cwd());
  } catch (err) {
    return { ok: false, message: `Failed to load the plugin marketplace index: ${err instanceof Error ? err.message : String(err)}` };
  }

  const entry = index.find((candidate) => candidate.name === name);
  if (!entry) {
    return { ok: false, message: `Unknown plugin: ${name}` };
  }

  const bundle = await resolvePluginBundle(entry);
  try {
    const result = await installPlugin({ cwd: process.cwd(), entry, bundleDir: bundle.dir });
    const verb = result.alreadyInstalled ? 'Updated' : 'Installed';
    return { ok: true, message: `${verb} ${name}@${entry.version} into .autoducks/custom/plugins/${name}/` };
  } finally {
    await bundle.cleanup();
  }
}

async function runUninstall(name: string): Promise<OutcomeProps> {
  const result = await uninstallPlugin(process.cwd(), name);
  return {
    ok: true,
    message: result.removed ? `Uninstalled ${name}.` : `${name} is not installed; nothing to do.`,
  };
}

// Also resolved for the `plugin uninstall` subcommand (see index.ts).
export const run: CommandModule['run'] = async (ctx) => {
  const [name] = ctx.args;
  const isUninstall = ctx.command === 'plugin uninstall';

  if (!name) {
    process.stderr.write(`Usage: autoducks plugin ${isUninstall ? 'uninstall' : 'install'} <name>\n`);
    return 1;
  }

  const result = isUninstall ? await runUninstall(name) : await runInstall(name);
  const { waitUntilExit } = render(<Outcome ok={result.ok} message={result.message} />);
  await waitUntilExit();
  return result.ok ? 0 : 1;
};
