import React from 'react';
import { render, Box, Text } from 'ink';
import type { CommandModule } from '../types.js';
import { dispatchCommand } from '../core/registry.js';
import { AUTOS, applyAuto, type AutoId, type AutoMapping } from '../core/autos.js';
import { deepMerge, load, write, type AutoducksConfig } from '../core/config.js';
import { bakeTriggers } from '../core/triggers.js';
import { MultiSelect } from '../ui/MultiSelect.js';
import { Select } from '../ui/Select.js';
import { theme } from '../ui/theme.js';

type SettingsChoice = 'recommended' | 'customize';

const DOC_LINK = 'https://autoducks.openvibes.tech/reference/configuration/';

/** Verbatim autos copy from the design "wizard/Choose your autos" section. */
const AUTO_COPY: Record<AutoId, { description: string; manual: string }> = {
  auto_groom: {
    description: '(scheduled Product Manager).',
    manual: 'Manual: "Run /triage manually".',
  },
  auto_spec: {
    description: '(any implementation or execution plan depends on an architect).',
    manual: 'Manual: "Run /design or /architect manually".',
  },
  auto_plan: {
    description: '(any execution depends on an implementation plan - architect+engineer).',
    manual: 'Manual: "Run /tactics or /engineer manually".',
  },
  orchestration_mode: {
    description: '(waved || sequential/iterative).',
    manual:
      '"Waved: /run or /execute will parallelize subtask execution based on the tactical plan. Sequential: /run or /execute will execute subtasks in the order of the tactical plan, one after another, over the same codebase/branch - more similar to an agent with a task plan."',
  },
  auto_checks: {
    description: '(backpressured loops - subtasks are executed until all checks pass).',
    manual: 'Manual: "Subtasks are auto merged without waiting for the checks to pass."',
  },
  auto_resolve: {
    description: '(conflicts).',
    manual: 'Manual: "Run /resolve manually".',
  },
  auto_review: {
    description: '(PR review when moved from draft to ready).',
    manual: 'Manual: "Run /review manually".',
  },
  auto_rework: {
    description: '(refactors code according when an unsuccessful review happens).',
    manual: 'Manual: "Run /rework manually".',
  },
};

/** Falls back to this repo's shipped schema defaults (`core/schema.ts`) when a key is unset. */
const AUTO_SCHEMA_DEFAULT: Record<AutoId, boolean> = {
  auto_groom: true,
  orchestration_mode: true,
  auto_checks: false,
  auto_resolve: true,
  auto_rework: true,
  auto_spec: true,
  auto_plan: true,
  auto_review: true,
};

/** Recommended settings written by "Use recommended settings" (design "wizard/settings"). */
export const RECOMMENDED_DEFAULTS: Partial<AutoducksConfig> = {
  defaults: { model: 'claude-sonnet-5', effort: 'high' },
  orchestrator: { mode: 'waves' },
  review: { max_iterations: 3 },
};

function getByPath(obj: Record<string, unknown>, dottedKey: string): unknown {
  return dottedKey.split('.').reduce<unknown>((acc, segment) => {
    if (acc && typeof acc === 'object') return (acc as Record<string, unknown>)[segment];
    return undefined;
  }, obj);
}

/** Pure: whether `auto` is currently enabled in `config`, falling back to its shipped schema default. */
export function isAutoEnabled(config: AutoducksConfig, auto: AutoMapping): boolean {
  const value = getByPath(config as Record<string, unknown>, auto.configKey);
  if (value === undefined) return AUTO_SCHEMA_DEFAULT[auto.id];
  return value === auto.enabledValue;
}

/** Pure: maps a set of selected auto ids to the config keys each one writes (design T2 table). */
export function buildAutosUpdates(selectedIds: AutoId[]): Partial<AutoducksConfig> {
  const selected = new Set(selectedIds);
  let updates: AutoducksConfig = {};
  for (const auto of AUTOS) {
    updates = applyAuto(updates, auto.id, selected.has(auto.id));
  }
  return updates;
}

/** Pure: whether `command`/`triggers.*` changed, meaning triggers need re-baking. */
export function triggersChanged(before: AutoducksConfig, after: AutoducksConfig): boolean {
  return before.command !== after.command || JSON.stringify(before.triggers ?? {}) !== JSON.stringify(after.triggers ?? {});
}

function AutosLegend() {
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>Choose your autos (space to toggle, enter to continue):</Text>
      {AUTOS.map((auto) => {
        const copy = AUTO_COPY[auto.id];
        return (
          <Box key={auto.id} flexDirection="column">
            <Text>
              <Text bold color={theme.colors.primary}>
                {auto.label}
              </Text>{' '}
              <Text color={theme.colors.muted}>{copy.description}</Text>
            </Text>
            <Text color={theme.colors.muted}> {copy.manual}</Text>
          </Box>
        );
      })}
      <Text color={theme.colors.muted}>Docs: {DOC_LINK}</Text>
    </Box>
  );
}

function AutosStep({
  initialValues,
  isInteractive,
  onSubmit,
}: {
  initialValues: AutoId[];
  isInteractive: boolean;
  onSubmit: (values: AutoId[]) => void;
}) {
  return (
    <Box flexDirection="column">
      <AutosLegend />
      <MultiSelect<AutoId>
        options={AUTOS.map((auto) => ({ label: auto.label, value: auto.id }))}
        initialValues={initialValues}
        isInteractive={isInteractive}
        onSubmit={onSubmit}
      />
    </Box>
  );
}

function SettingsStep({ isInteractive, onSubmit }: { isInteractive: boolean; onSubmit: (value: SettingsChoice) => void }) {
  return (
    <Box flexDirection="column">
      <Text>Settings:</Text>
      <Select<SettingsChoice>
        options={[
          {
            label: 'Use recommended settings',
            value: 'recommended',
            hint: 'model=claude-sonnet-5, effort=high, orchestrator.mode=waves, review.max_iterations=3',
          },
          { label: 'Customize settings', value: 'customize', hint: 'opens the config command' },
        ]}
        initialValue="recommended"
        isInteractive={isInteractive}
        onSubmit={onSubmit}
      />
    </Box>
  );
}

export const run: CommandModule['run'] = async (ctx) => {
  const cwd = process.cwd();
  const promptable = ctx.isInteractive && !ctx.options.yes;

  let existing: AutoducksConfig = {};
  try {
    existing = (await load(cwd)).config;
  } catch {
    existing = {};
  }

  const initialSelection = AUTOS.filter((auto) => isAutoEnabled(existing, auto)).map((auto) => auto.id);

  const selectedIds = await new Promise<AutoId[]>((resolve) => {
    // `render` can invoke `onSubmit` synchronously (non-interactive auto-resolution
    // fires from a passive effect flushed before `render` returns), so `instance`
    // must not be read inside the callback until the current call stack unwinds.
    let instance: ReturnType<typeof render>;
    instance = render(
      <AutosStep
        initialValues={initialSelection}
        isInteractive={promptable}
        onSubmit={(values) => {
          resolve(values);
          queueMicrotask(() => instance.unmount());
        }}
      />,
      { patchConsole: false },
    );
  });

  const settingsChoice = await new Promise<SettingsChoice>((resolve) => {
    let instance: ReturnType<typeof render>;
    instance = render(
      <SettingsStep
        isInteractive={promptable}
        onSubmit={(value) => {
          resolve(value);
          queueMicrotask(() => instance.unmount());
        }}
      />,
      { patchConsole: false },
    );
  });

  const autosUpdates = buildAutosUpdates(selectedIds);
  const updates = settingsChoice === 'recommended' ? deepMerge(autosUpdates, RECOMMENDED_DEFAULTS) : autosUpdates;

  const written = await write(cwd, updates);

  if (triggersChanged(existing, written)) {
    await bakeTriggers(cwd);
  }

  if (settingsChoice === 'customize') {
    return dispatchCommand('config', ctx);
  }

  const summary = render(
    <Text>
      <Text color={theme.colors.success}>{theme.glyphs.pass}</Text> Configuration written to .autoducks/autoducks.json.
    </Text>,
    { patchConsole: false },
  );
  summary.unmount();
  return 0;
};
