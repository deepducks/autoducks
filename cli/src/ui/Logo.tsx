import React, { type ReactNode } from 'react';
import { Box, Text } from 'ink';
import { theme } from './theme.js';
import { renderBlockText } from './asciiFont.js';

const WORDMARK = 'AUTODUCKS';

/** Full block-letter banner, used for `version`/splash headers. */
function StaticFullLogo() {
  return (
    <Box flexDirection="column">
      {renderBlockText(WORDMARK).map((line, index) => (
        // eslint-disable-next-line react/no-array-index-key
        <Text key={index} color={theme.colors.primary}>
          {line}
        </Text>
      ))}
    </Box>
  );
}

/** Single-line wordmark, used for `help` headers and tight spaces. */
function StaticCompactLogo() {
  return <Text color={theme.colors.primary}>▲ autoducks</Text>;
}

export interface LogoProps {
  /** True when the animated path is viable: a real TTY, not `--no-input`, and not too slow to draw frames. */
  isTTY: boolean;
  /**
   * Optional injected animated renderer (e.g. an ASCII Motion sequence). Kept
   * as a slot rather than a hard dependency: `Logo` never imports an
   * animation library directly, and any renderer that throws or returns
   * nothing degrades to the static logo.
   */
  renderAnimated?: () => ReactNode;
  variant?: 'full' | 'compact';
}

/** Bit-style static ASCII logo, with an optional animated slot that falls back to it on non-TTY/slow terminals. */
export function Logo({ isTTY, renderAnimated, variant = 'full' }: LogoProps) {
  if (isTTY && renderAnimated) {
    try {
      const animated = renderAnimated();
      if (animated) {
        return <>{animated}</>;
      }
    } catch {
      // Fall through to the static logo below.
    }
  }

  return variant === 'compact' ? <StaticCompactLogo /> : <StaticFullLogo />;
}
