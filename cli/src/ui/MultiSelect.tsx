import React, { useEffect, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { theme } from './theme.js';

export interface MultiSelectOption<T extends string = string> {
  label: string;
  value: T;
  hint?: string;
}

export interface MultiSelectProps<T extends string = string> {
  message?: string;
  options: Array<MultiSelectOption<T>>;
  /** Values checked first, and the ones auto-submitted under `--no-input`. Defaults to none. */
  initialValues?: T[];
  /** True when stdout is a TTY and the user can drive this with arrow/space keys. */
  isInteractive: boolean;
  onSubmit: (values: T[]) => void;
}

/** Multi-choice checklist. Under non-interactive mode it resolves to `initialValues` (or none) without blocking. */
export function MultiSelect<T extends string = string>({
  message,
  options,
  initialValues = [],
  isInteractive,
  onSubmit,
}: MultiSelectProps<T>) {
  const [cursor, setCursor] = useState(0);
  const [selected, setSelected] = useState<Set<T>>(() => new Set(initialValues));

  useEffect(() => {
    if (!isInteractive) {
      onSubmit([...selected]);
    }
    // Non-interactive resolution happens once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useInput(
    (input, key) => {
      if (key.upArrow) {
        setCursor((current) => (current - 1 + options.length) % options.length);
      } else if (key.downArrow) {
        setCursor((current) => (current + 1) % options.length);
      } else if (input === ' ') {
        const option = options[cursor];
        if (!option) return;
        setSelected((current) => {
          const next = new Set(current);
          if (next.has(option.value)) {
            next.delete(option.value);
          } else {
            next.add(option.value);
          }
          return next;
        });
      } else if (key.return) {
        onSubmit([...selected]);
      }
    },
    { isActive: isInteractive && options.length > 0 },
  );

  return (
    <Box flexDirection="column">
      {message ? <Text>{message}</Text> : null}
      {options.map((option, position) => {
        const isChecked = isInteractive ? selected.has(option.value) : initialValues.includes(option.value);
        const isCursor = isInteractive && position === cursor;
        return (
          <Text key={option.value} color={isCursor ? theme.colors.primary : undefined}>
            {isCursor ? theme.glyphs.pointer : ' '} {isChecked ? theme.glyphs.checkedBox : theme.glyphs.uncheckedBox} {option.label}
            {option.hint ? <Text color={theme.colors.muted}> ({option.hint})</Text> : null}
          </Text>
        );
      })}
    </Box>
  );
}
