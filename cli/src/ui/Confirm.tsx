import React, { useEffect, useState } from 'react';
import { Text, useInput } from 'ink';
import { theme } from './theme.js';

export interface ConfirmProps {
  message: string;
  /** Answer used when the user just presses enter, and the one auto-submitted under `--no-input`. */
  defaultValue?: boolean;
  /** True when stdout is a TTY and the user can answer with y/n. */
  isInteractive: boolean;
  onConfirm: (value: boolean) => void;
}

/** Yes/no prompt. Under non-interactive mode it resolves to `defaultValue` (or `true`) without blocking. */
export function Confirm({ message, defaultValue = true, isInteractive, onConfirm }: ConfirmProps) {
  const [answer, setAnswer] = useState<boolean | undefined>(isInteractive ? undefined : defaultValue);

  useEffect(() => {
    if (!isInteractive) {
      onConfirm(defaultValue);
    }
    // Non-interactive resolution happens once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useInput(
    (input, key) => {
      if (input === 'y' || input === 'Y') {
        setAnswer(true);
        onConfirm(true);
      } else if (input === 'n' || input === 'N') {
        setAnswer(false);
        onConfirm(false);
      } else if (key.return) {
        setAnswer(defaultValue);
        onConfirm(defaultValue);
      }
    },
    { isActive: isInteractive },
  );

  const hint = defaultValue ? 'Y/n' : 'y/N';
  const resolved = answer === undefined ? '' : answer ? 'Yes' : 'No';

  return (
    <Text>
      {message} <Text color={theme.colors.muted}>({hint})</Text>
      {resolved ? ` ${resolved}` : ''}
    </Text>
  );
}
