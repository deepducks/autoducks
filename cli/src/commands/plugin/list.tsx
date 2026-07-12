import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandModule } from '../../types.js';
import { theme } from '../../ui/theme.js';
import { fetchIndex, list as listPlugins, type PluginListEntry } from '../../core/plugins.js';

const STATE_LABEL: Record<PluginListEntry['state'], string> = {
  installed: 'installed',
  available: 'available',
  'update-available': 'update available',
};

const STATE_COLOR: Record<PluginListEntry['state'], string> = {
  installed: theme.colors.success,
  available: theme.colors.muted,
  'update-available': theme.colors.warning,
};

function PluginList({ entries }: { entries: PluginListEntry[] }) {
  if (entries.length === 0) {
    return <Text color={theme.colors.muted}>No plugins in the marketplace index.</Text>;
  }
  return (
    <Box flexDirection="column">
      {entries.map((entry) => {
        const version = entry.state === 'update-available' ? `${entry.installedVersion} -> ${entry.latestVersion}` : entry.latestVersion;
        return (
          <Text key={entry.name}>
            <Text color={STATE_COLOR[entry.state]}>{STATE_LABEL[entry.state].padEnd(16)}</Text>
            {entry.name} <Text color={theme.colors.muted}>({entry.type}, {version})</Text>
            {entry.recommended ? <Text color={theme.colors.accent}> recommended</Text> : null}
            {entry.description ? <Text color={theme.colors.muted}> — {entry.description}</Text> : null}
          </Text>
        );
      })}
    </Box>
  );
}

export const run: CommandModule['run'] = async () => {
  let index;
  try {
    index = await fetchIndex(process.cwd());
  } catch (err) {
    process.stderr.write(`Failed to load the plugin marketplace index: ${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }

  const entries = await listPlugins(process.cwd(), index);
  const { waitUntilExit } = render(<PluginList entries={entries} />);
  await waitUntilExit();
  return 0;
};
