import React from 'react';
import { Box, Text } from 'ink';
import type { CheckResult } from '../types.js';
import { theme } from './theme.js';

const STATUS_GLYPH: Record<CheckResult['status'], string> = {
  pass: theme.glyphs.pass,
  fail: theme.glyphs.fail,
  manual: theme.glyphs.manual,
};

const STATUS_COLOR: Record<CheckResult['status'], string> = {
  pass: theme.colors.success,
  fail: theme.colors.error,
  manual: theme.colors.warning,
};

export interface CheckListProps {
  checks: CheckResult[];
}

/** Renders a `CheckResult[]` as status glyphs with remediation for anything that isn't passing. */
export function CheckList({ checks }: CheckListProps) {
  return (
    <Box flexDirection="column">
      {checks.map((check) => (
        <Box key={check.id} flexDirection="column">
          <Text>
            {STATUS_GLYPH[check.status]} <Text color={STATUS_COLOR[check.status]}>{check.title}</Text>
            {check.message ? <Text color={theme.colors.muted}> — {check.message}</Text> : null}
          </Text>
          {check.status !== 'pass' && check.remediation ? (
            <Box paddingLeft={3}>
              <Text color={theme.colors.muted}>↳ {check.remediation}</Text>
            </Box>
          ) : null}
        </Box>
      ))}
    </Box>
  );
}
