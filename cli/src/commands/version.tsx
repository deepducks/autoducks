import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandModule } from '../types.js';
import { getVersion, load, type AutoducksConfig } from '../core/config.js';
import { getCliVersion } from '../core/pkg.js';

/** Exported for direct component-level testing; `run()` below is the command entrypoint. */
export function VersionInfo({ cliVersion, pinnedVersion }: { cliVersion: string; pinnedVersion: string }) {
  return (
    <Box flexDirection="column">
      <Text>autoducks CLI v{cliVersion}</Text>
      <Text>autoducks (pinned): {pinnedVersion}</Text>
    </Box>
  );
}

/** Prints the CLI's own version plus the pinned autoducks release tag (or "unpinned") from the local config. */
export const run: CommandModule['run'] = async () => {
  const cliVersion = await getCliVersion();

  let config: AutoducksConfig = {};
  try {
    config = (await load(process.cwd())).config;
  } catch {
    // No config file yet (or it's invalid) — report as unpinned.
  }
  const pinnedVersion = getVersion(config);

  const { waitUntilExit } = render(<VersionInfo cliVersion={cliVersion} pinnedVersion={pinnedVersion} />);
  await waitUntilExit();
  return 0;
};
