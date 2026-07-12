import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandContext, CommandModule } from '../types.js';
import { USAGE } from '../core/usage.js';
import { Logo } from '../ui/Logo.js';

interface CommandHelp {
  summary: string;
  detail: string;
}

const COMMAND_HELP: Record<string, CommandHelp> = {
  install: {
    summary: 'Install (or update) .autoducks + .github files; runs setup on fresh install.',
    detail: 'Usage: autoducks install [--repo OWNER/REPO] [--version <tag>] [--no-input] [--yes]',
  },
  update: {
    summary: 'Alias for `install`.',
    detail: 'Usage: autoducks update [--repo OWNER/REPO] [--version <tag>] [--no-input] [--yes]',
  },
  setup: {
    summary: 'Run setup checks and launch the wizard.',
    detail: 'Usage: autoducks setup [--repo OWNER/REPO] [--no-input] [--yes]',
  },
  wizard: {
    summary: 'Choose which autos to enable and pick recommended/custom settings.',
    detail: 'Usage: autoducks wizard [--repo OWNER/REPO] [--no-input] [--yes]',
  },
  config: {
    summary: 'Open the visual configuration editor (TUI) over .autoducks/autoducks.json.',
    detail: 'Usage: autoducks config\n\nRequires an interactive terminal. Changing the command namespace or a\ntriggers.* alias list re-bakes the workflow guards on save.',
  },
  plugin: {
    summary: 'Manage plugins: list | install | uninstall | install-recommended.',
    detail: 'Usage: autoducks plugin <list|install|uninstall|install-recommended> [args]',
  },
  version: {
    summary: 'Print the CLI version and the pinned autoducks version.',
    detail: 'Usage: autoducks version',
  },
  help: {
    summary: 'Show help.',
    detail: 'Usage: autoducks help [command]',
  },
};

/** Exported for direct component-level testing; `run()` below is the command entrypoint. */
export function Help({ command }: { command?: string }) {
  const entry = command ? COMMAND_HELP[command] : undefined;

  return (
    <Box flexDirection="column">
      <Logo isTTY={false} variant="compact" />
      {command ? (
        entry ? (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>autoducks {command}</Text>
            <Text>{entry.summary}</Text>
            <Text></Text>
            <Text>{entry.detail}</Text>
          </Box>
        ) : (
          <Box marginTop={1}>
            <Text color="yellow">Unknown command: {command}</Text>
          </Box>
        )
      ) : (
        <Box marginTop={1}>
          <Text>{USAGE}</Text>
        </Box>
      )}
    </Box>
  );
}

/** `help` prints the full usage block; `help <command>` prints that command's detail, both under a `Logo` header. */
export const run: CommandModule['run'] = async (ctx: CommandContext) => {
  const [command] = ctx.args;
  const { waitUntilExit } = render(<Help command={command} />);
  await waitUntilExit();
  return 0;
};
