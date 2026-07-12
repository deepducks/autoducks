import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandModule } from '../../types.js';
import { theme } from '../../ui/theme.js';
import {
  fetchIndex,
  resolvePluginBundle,
  detectRepoTags,
  installRecommended as installRecommendedPlugins,
  type RecommendedOutcome,
} from '../../core/plugins.js';
import { detectRepo } from '../../core/gh.js';

interface SummaryProps {
  selected: RecommendedOutcome[];
  skipped: RecommendedOutcome[];
}

/** Explicitly renders every selected AND skipped entry — install-recommended never selects silently. */
function Summary({ selected, skipped }: SummaryProps) {
  return (
    <Box flexDirection="column">
      {selected.map((entry) => (
        <Text key={`selected-${entry.name}`} color={theme.colors.success}>
          {theme.glyphs.pass} Installed {entry.name} — {entry.reason}
        </Text>
      ))}
      {skipped.map((entry) => (
        <Text key={`skipped-${entry.name}`} color={theme.colors.muted}>
          {theme.glyphs.uncheckedBox} Skipped {entry.name} — {entry.reason}
        </Text>
      ))}
      {selected.length === 0 ? <Text color={theme.colors.muted}>No recommended plugins matched this repo.</Text> : null}
    </Box>
  );
}

export const run: CommandModule['run'] = async (ctx) => {
  let index;
  try {
    index = await fetchIndex(process.cwd());
  } catch (err) {
    process.stderr.write(`Failed to load the plugin marketplace index: ${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }

  const cwd = process.cwd();
  const [detectedSlug, tags] = await Promise.all([detectRepo(cwd), detectRepoTags(cwd)]);

  const result = await installRecommendedPlugins({
    cwd,
    index,
    detection: { slug: ctx.options.repo ?? detectedSlug, tags },
    resolveBundle: resolvePluginBundle,
  });

  const { waitUntilExit } = render(<Summary selected={result.selected} skipped={result.skipped} />);
  await waitUntilExit();
  return 0;
};
