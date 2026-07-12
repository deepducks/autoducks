/**
 * Shared visual tokens for the `src/ui/` component kit: colors and glyphs
 * every component pulls from instead of hard-coding its own.
 */
export const theme = {
  colors: {
    primary: 'cyan',
    success: 'green',
    error: 'red',
    warning: 'yellow',
    muted: 'gray',
    accent: 'magenta',
  },
  glyphs: {
    pass: '✅',
    fail: '❌',
    manual: '⚠️',
    pointer: '❯',
    checkedBox: '◉',
    uncheckedBox: '◯',
    radioSelected: '●',
    radioUnselected: '○',
  },
} as const;

export type Theme = typeof theme;
export type StatusColor = keyof Theme['colors'];
