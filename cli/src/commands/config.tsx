import React, { useEffect, useMemo, useState } from 'react';
import { render, useApp, Box, Text } from 'ink';
import type { CommandContext, CommandModule } from '../types.js';
import * as configStore from '../core/config.js';
import type { AutoducksConfig } from '../core/config.js';
import { bakeTriggers } from '../core/triggers.js';
import {
  buildFieldDefs,
  buildPatch,
  formatFieldValue,
  formatListForEdit,
  getByPath,
  setByPath,
  shouldRebakeTriggers,
  validateFieldInput,
  type FieldDef,
} from '../core/config-fields.js';
import { Select, type SelectOption } from '../ui/Select.js';
import { Confirm } from '../ui/Confirm.js';
import { TextInput } from '../ui/TextInput.js';
import { theme } from '../ui/theme.js';

const SAVE_ACTION = '__save__';
const DISCARD_ACTION = '__discard__';

type Screen =
  | { kind: 'loading' }
  | { kind: 'menu' }
  | { kind: 'edit'; field: FieldDef; error?: string }
  | { kind: 'saving' }
  | { kind: 'done'; saved: boolean; rebaked: boolean }
  | { kind: 'error'; message: string };

interface ConfigEditorProps {
  root: string;
  isInteractive: boolean;
  onExit: (code: number) => void;
}

/** Exported for direct component-level testing; `run()` below is the command entrypoint. */
export function ConfigEditor({ root, isInteractive, onExit }: ConfigEditorProps) {
  const { exit } = useApp();
  const [draft, setDraft] = useState<Record<string, unknown>>({});
  const [changed, setChanged] = useState<Record<string, unknown>>({});
  const [screen, setScreen] = useState<Screen>({ kind: 'loading' });

  useEffect(() => {
    configStore
      .load(root)
      .then(({ config }) => {
        setDraft(config as Record<string, unknown>);
        setScreen({ kind: 'menu' });
      })
      .catch(() => {
        // No config file yet (or it's unreadable) — start from an empty draft.
        setDraft({});
        setScreen({ kind: 'menu' });
      });
    // Loads exactly once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const fields = useMemo(() => buildFieldDefs(draft as AutoducksConfig), [draft]);

  async function handleSave() {
    setScreen({ kind: 'saving' });
    const patch = buildPatch(changed);
    try {
      await configStore.write(root, patch);
    } catch (err) {
      setScreen({ kind: 'error', message: err instanceof Error ? err.message : String(err) });
      onExit(1);
      exit();
      return;
    }

    const rebake = shouldRebakeTriggers(Object.keys(changed));
    if (rebake) {
      await bakeTriggers(root);
    }

    setScreen({ kind: 'done', saved: true, rebaked: rebake });
    onExit(0);
    exit();
  }

  function handleMenuSubmit(value: string) {
    if (value === SAVE_ACTION) {
      void handleSave();
      return;
    }
    if (value === DISCARD_ACTION) {
      setScreen({ kind: 'done', saved: false, rebaked: false });
      onExit(0);
      exit();
      return;
    }
    const field = fields.find((candidate) => candidate.path === value);
    if (field) setScreen({ kind: 'edit', field });
  }

  function handleFieldSubmit(field: FieldDef, raw: unknown) {
    const outcome = validateFieldInput(field, raw);
    if (!outcome.valid) {
      setScreen({ kind: 'edit', field, error: outcome.error });
      return;
    }
    setDraft((current) => setByPath(current, field.path, outcome.value));
    setChanged((current) => ({ ...current, [field.path]: outcome.value }));
    setScreen({ kind: 'menu' });
  }

  if (screen.kind === 'loading') {
    return <Text color={theme.colors.muted}>Loading .autoducks/autoducks.json…</Text>;
  }

  if (screen.kind === 'saving') {
    return <Text color={theme.colors.muted}>Saving…</Text>;
  }

  if (screen.kind === 'error') {
    return <Text color={theme.colors.error}>{screen.message}</Text>;
  }

  if (screen.kind === 'done') {
    if (!screen.saved) return <Text color={theme.colors.muted}>Discarded changes.</Text>;
    return (
      <Text color={theme.colors.success}>
        Saved .autoducks/autoducks.json.{screen.rebaked ? ' Re-baked triggers.' : ''}
      </Text>
    );
  }

  if (screen.kind === 'edit') {
    const { field, error } = screen;
    return (
      <Box flexDirection="column">
        <Text bold>{field.label}</Text>
        {field.description ? <Text color={theme.colors.muted}>{field.description}</Text> : null}
        {error ? <Text color={theme.colors.error}>{error}</Text> : null}
        {renderFieldControl(field, draft, isInteractive, (raw) => handleFieldSubmit(field, raw))}
      </Box>
    );
  }

  // screen.kind === 'menu'
  const options: Array<SelectOption<string>> = [
    ...fields.map((field) => ({
      label: `${field.label}: ${formatFieldValue(field, getByPath(draft, field.path))}`,
      value: field.path,
    })),
    { label: 'Save and exit', value: SAVE_ACTION },
    { label: 'Discard and exit', value: DISCARD_ACTION },
  ];

  return (
    <Box flexDirection="column">
      <Text bold>autoducks config</Text>
      <Select message="Select a field to edit:" options={options} isInteractive={isInteractive} onSubmit={handleMenuSubmit} />
    </Box>
  );
}

function renderFieldControl(
  field: FieldDef,
  draft: Record<string, unknown>,
  isInteractive: boolean,
  onSubmit: (raw: unknown) => void,
) {
  const currentValue = getByPath(draft, field.path);

  switch (field.control) {
    case 'select':
      return (
        <Select
          options={(field.options ?? []).map((option) => ({ label: option, value: option }))}
          initialValue={currentValue !== undefined ? String(currentValue) : undefined}
          isInteractive={isInteractive}
          onSubmit={onSubmit}
        />
      );
    case 'toggle':
      return <Confirm message="Enabled?" defaultValue={Boolean(currentValue)} isInteractive={isInteractive} onConfirm={onSubmit} />;
    case 'number':
      return (
        <TextInput
          initialValue={currentValue !== undefined && currentValue !== null ? String(currentValue) : ''}
          isInteractive={isInteractive}
          onSubmit={onSubmit}
        />
      );
    case 'list':
      return (
        <TextInput
          placeholder="comma-separated"
          initialValue={formatListForEdit(currentValue)}
          isInteractive={isInteractive}
          onSubmit={onSubmit}
        />
      );
    case 'text':
    default:
      return (
        <TextInput initialValue={currentValue !== undefined ? String(currentValue) : ''} isInteractive={isInteractive} onSubmit={onSubmit} />
      );
  }
}

function NonInteractiveNotice() {
  return <Text color={theme.colors.muted}>autoducks config requires an interactive terminal; re-run without --no-input.</Text>;
}

/** Schema-driven TUI editor over `.autoducks/autoducks.json`; re-bakes triggers on save when `command`/`triggers.*` changed. */
export const run: CommandModule['run'] = async (ctx: CommandContext) => {
  const root = process.cwd();

  if (!ctx.isInteractive) {
    const { waitUntilExit } = render(<NonInteractiveNotice />);
    await waitUntilExit();
    return 0;
  }

  let exitCode = 0;
  const { waitUntilExit } = render(
    <ConfigEditor
      root={root}
      isInteractive={ctx.isInteractive}
      onExit={(code) => {
        exitCode = code;
      }}
    />,
  );
  await waitUntilExit();
  return exitCode;
};
