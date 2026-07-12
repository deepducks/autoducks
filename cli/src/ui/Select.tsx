import React, { useEffect, useRef, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { theme } from './theme.js';

export interface SelectOption<T extends string = string> {
  label: string;
  value: T;
  hint?: string;
}

export interface SelectProps<T extends string = string> {
  message?: string;
  options: Array<SelectOption<T>>;
  /** Value highlighted first, and the one auto-submitted under `--no-input`. Defaults to the first option. */
  initialValue?: T;
  /** True when stdout is a TTY and the user can drive this with arrow keys. */
  isInteractive: boolean;
  onSubmit: (value: T) => void;
}

/** Single-choice list. Under non-interactive mode it resolves to `initialValue` (or the first option) without blocking. */
export function Select<T extends string = string>({ message, options, initialValue, isInteractive, onSubmit }: SelectProps<T>) {
  const defaultIndex = Math.max(
    0,
    options.findIndex((option) => option.value === initialValue),
  );
  const [index, setIndex] = useState(defaultIndex);
  // `useInput`'s listener re-subscribes asynchronously, so a handler can still be
  // running with a stale `index` closure; a ref is always current regardless of
  // which render's closure receives the keypress.
  const indexRef = useRef(defaultIndex);

  useEffect(() => {
    if (!isInteractive && options.length > 0) {
      onSubmit(options[defaultIndex]!.value);
    }
    // Non-interactive resolution happens once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useInput(
    (_input, key) => {
      if (key.upArrow) {
        setIndex((current) => {
          const next = (current - 1 + options.length) % options.length;
          indexRef.current = next;
          return next;
        });
      } else if (key.downArrow) {
        setIndex((current) => {
          const next = (current + 1) % options.length;
          indexRef.current = next;
          return next;
        });
      } else if (key.return) {
        const selected = options[indexRef.current];
        if (selected) onSubmit(selected.value);
      }
    },
    { isActive: isInteractive && options.length > 0 },
  );

  return (
    <Box flexDirection="column">
      {message ? <Text>{message}</Text> : null}
      {options.map((option, position) => {
        const active = isInteractive ? position === index : option.value === initialValue;
        return (
          <Text key={option.value} color={active ? theme.colors.primary : undefined}>
            {active ? theme.glyphs.pointer : ' '} {option.label}
            {option.hint ? <Text color={theme.colors.muted}> ({option.hint})</Text> : null}
          </Text>
        );
      })}
    </Box>
  );
}
