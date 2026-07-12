import React, { useEffect, useRef, useState } from 'react';
import { Text, useInput } from 'ink';
import { theme } from './theme.js';

export interface TextInputProps {
  message?: string;
  initialValue?: string;
  placeholder?: string;
  /** Renders typed characters as `*`, for secrets. */
  mask?: boolean;
  /** True when stdout is a TTY and the user can type into this field. */
  isInteractive: boolean;
  onSubmit: (value: string) => void;
}

/** Free-text field. Under non-interactive mode it resolves to `initialValue` (or `''`) without blocking. */
export function TextInput({ message, initialValue = '', placeholder, mask = false, isInteractive, onSubmit }: TextInputProps) {
  const [value, setValue] = useState(initialValue);
  // `useInput`'s listener re-subscribes asynchronously, so a handler can still be
  // running with a stale `value` closure; a ref is always current regardless of
  // which render's closure receives the keypress.
  const valueRef = useRef(initialValue);

  useEffect(() => {
    if (!isInteractive) {
      onSubmit(initialValue);
    }
    // Non-interactive resolution happens once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useInput(
    (input, key) => {
      if (key.return) {
        onSubmit(valueRef.current);
      } else if (key.backspace || key.delete) {
        setValue((current) => {
          const next = current.slice(0, -1);
          valueRef.current = next;
          return next;
        });
      } else if (input && !key.ctrl && !key.meta) {
        setValue((current) => {
          const next = current + input;
          valueRef.current = next;
          return next;
        });
      }
    },
    { isActive: isInteractive },
  );

  const displayValue = isInteractive ? value : initialValue;
  const rendered = mask ? '*'.repeat(displayValue.length) : displayValue;

  return (
    <Text>
      {message ? `${message} ` : ''}
      {rendered.length > 0 ? rendered : <Text color={theme.colors.muted}>{placeholder ?? ''}</Text>}
    </Text>
  );
}
