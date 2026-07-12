import { CONFIG_SCHEMA } from './schema.js';
import type { AutoducksConfig } from './config.js';

/** Which UI control a field renders as. */
export type FieldControl = 'select' | 'toggle' | 'text' | 'number' | 'list';

export interface FieldDef {
  /** Dot path into the config object, e.g. `defaults.model`. */
  path: string;
  label: string;
  control: FieldControl;
  description?: string;
  /** For `select` fields. */
  options?: string[];
  /** For `number` fields. */
  min?: number;
  max?: number;
  /** For `text` fields. */
  pattern?: RegExp;
}

/** Falls back to this agent list when `triggers` is absent/empty (matches the shipped config). */
const DEFAULT_TRIGGER_AGENTS = [
  'architect',
  'engineer',
  'execute',
  'fix',
  'revert',
  'close',
  'review',
  'rework',
  'defer',
  'resolve',
  'triage',
  'merge',
];

/** Reads `properties.<keys[0]>.properties.<keys[1]>...description` out of the schema, tolerating gaps. */
function describe(...keys: string[]): string | undefined {
  let node: unknown = CONFIG_SCHEMA;
  for (const key of keys) {
    node = (node as { properties?: Record<string, unknown> } | undefined)?.properties?.[key];
    if (!node) return undefined;
  }
  return (node as { description?: string } | undefined)?.description;
}

const STATIC_FIELD_DEFS: FieldDef[] = [
  // --- Selects (enums) ---
  {
    path: 'defaults.model',
    label: 'Default model',
    control: 'select',
    options: ['claude-sonnet-5', 'opus', 'haiku'],
    description: describe('defaults', 'model'),
  },
  {
    path: 'defaults.effort',
    label: 'Default effort',
    control: 'select',
    options: ['low', 'medium', 'high', 'max'],
    description: describe('defaults', 'effort'),
  },
  {
    path: 'orchestrator.mode',
    label: 'Orchestrator mode',
    control: 'select',
    options: ['waves', 'sequential'],
    description: describe('orchestrator', 'mode'),
  },
  {
    path: 'defaults.merge_method',
    label: 'Merge method',
    control: 'select',
    options: ['auto', 'merge', 'squash', 'rebase'],
    description: describe('defaults', 'merge_method'),
  },
  {
    path: 'product.confidence_threshold',
    label: 'Duplicate-close confidence threshold',
    control: 'select',
    options: ['high', 'medium', 'low'],
    description: describe('product', 'confidence_threshold'),
  },
  {
    path: 'product.priority_backend',
    label: 'Priority backend',
    control: 'select',
    options: ['auto', 'project', 'labels', 'off'],
    description: describe('product', 'priority_backend'),
  },

  // --- Toggles (booleans) ---
  {
    path: 'reviewer.required_check',
    label: 'Require Reviewer check to merge',
    control: 'toggle',
    description: describe('reviewer', 'required_check'),
  },
  { path: 'resolver.auto', label: 'Auto Resolve', control: 'toggle', description: describe('resolver', 'auto') },
  { path: 'checks.enabled', label: 'Auto Checks', control: 'toggle', description: describe('checks', 'enabled') },
  { path: 'product.enabled', label: 'Auto Groom', control: 'toggle', description: describe('product', 'enabled') },
  {
    path: 'product.auto_merge_duplicates',
    label: 'Auto-merge duplicate closes',
    control: 'toggle',
    description: describe('product', 'auto_merge_duplicates'),
  },
  {
    path: 'review.auto_rework',
    label: 'Auto Rework',
    control: 'toggle',
    description: describe('review', 'auto_rework'),
  },
  {
    path: 'product.provisional_classification',
    label: 'Provisional Bug/Feature classification',
    control: 'toggle',
    description: describe('product', 'provisional_classification'),
  },
  {
    path: 'security.codeowners',
    label: 'Honor CODEOWNERS',
    control: 'toggle',
    description: describe('security', 'codeowners'),
  },

  // --- Text / number (scalars) ---
  {
    path: 'command',
    label: 'Command namespace',
    control: 'text',
    pattern: /^$|^\/?[a-z0-9-]+$/,
    description: describe('command'),
  },
  {
    path: 'defaults.base_branch',
    label: 'Base branch',
    control: 'text',
    description: describe('defaults', 'base_branch'),
  },
  {
    path: 'defaults.integration_branch',
    label: 'Integration branch',
    control: 'text',
    description: describe('defaults', 'integration_branch'),
  },
  {
    path: 'product.schedule',
    label: 'Backlog sweep schedule (cron)',
    control: 'text',
    description: describe('product', 'schedule'),
  },
  {
    path: 'review.max_iterations',
    label: 'Max Review/Rework iterations',
    control: 'number',
    min: 1,
    max: 10,
    description: describe('review', 'max_iterations'),
  },
  {
    path: 'checks.max_iterations',
    label: 'Max Developer check-fix attempts',
    control: 'number',
    min: 1,
    max: 10,
    description: describe('checks', 'max_iterations'),
  },
  {
    path: 'product.max_closes_per_run',
    label: 'Max duplicate closes per sweep',
    control: 'number',
    min: 0,
    description: describe('product', 'max_closes_per_run'),
  },
  {
    path: 'product.max_issues_per_run',
    label: 'Max issues pulled per sweep',
    control: 'number',
    min: 1,
    description: describe('product', 'max_issues_per_run'),
  },

  // --- List editors (arrays) ---
  {
    path: 'security.trusted_associations',
    label: 'Trusted associations',
    control: 'list',
    description: 'Comma-separated author associations (e.g. OWNER, MEMBER, COLLABORATOR) allowed to trigger agents.',
  },
  { path: 'security.allow', label: 'Allow list', control: 'list', description: 'Comma-separated usernames/teams always allowed.' },
  { path: 'security.deny', label: 'Deny list', control: 'list', description: 'Comma-separated usernames/teams always denied.' },
];

/**
 * Builds the full field list for a loaded config: the static fields above,
 * plus one `list` field per `triggers.<agent>` and `security.per_agent.<agent>.trusted_associations`
 * key actually present in `config` (falling back to the shipped agent set when `triggers` is empty).
 */
export function buildFieldDefs(config: AutoducksConfig): FieldDef[] {
  const triggerAgents = Object.keys(config.triggers ?? {});
  const agents = triggerAgents.length > 0 ? triggerAgents : DEFAULT_TRIGGER_AGENTS;
  const triggerFields: FieldDef[] = agents.map((agent) => ({
    path: `triggers.${agent}`,
    label: `Custom trigger aliases: ${agent}`,
    control: 'list',
    description: 'Comma-separated extra slash-command aliases that dispatch this agent, alongside its built-in trigger.',
  }));

  const perAgentKeys = Object.keys(config.security?.per_agent ?? {});
  const perAgentFields: FieldDef[] = perAgentKeys.map((agent) => ({
    path: `security.per_agent.${agent}.trusted_associations`,
    label: `Trusted associations override: ${agent}`,
    control: 'list',
    description: 'Per-agent override of the top-level trusted-associations policy.',
  }));

  return [...STATIC_FIELD_DEFS, ...triggerFields, ...perAgentFields];
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Reads the value at a dot `path` out of `source`, or `undefined` if any segment is missing. */
export function getByPath(source: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((acc, key) => {
    if (isPlainObject(acc) && key in acc) return acc[key];
    return undefined;
  }, source);
}

/** Pure: returns a new object with `value` set at `path`, without mutating `source`. */
export function setByPath<T extends Record<string, unknown>>(source: T, path: string, value: unknown): T {
  const [head, ...rest] = path.split('.');
  if (!head) return source;
  if (rest.length === 0) {
    return { ...source, [head]: value };
  }
  const nested = isPlainObject(source[head]) ? source[head] : {};
  return { ...source, [head]: setByPath(nested, rest.join('.'), value) } as T;
}

/** Builds a minimal nested patch object from a flat map of dot-path -> value, suitable for `core/config`'s `write()`. */
export function buildPatch(changes: Record<string, unknown>): Record<string, unknown> {
  let patch: Record<string, unknown> = {};
  for (const [path, value] of Object.entries(changes)) {
    patch = setByPath(patch, path, value);
  }
  return patch;
}

export interface ValidationOutcome {
  valid: boolean;
  value?: unknown;
  error?: string;
}

/**
 * Validates and coerces a raw control value (string from `TextInput`/`Select`,
 * boolean from `Confirm`) against `field`'s control type before it's applied
 * to the draft — invalid input is rejected here, before anything is written.
 */
export function validateFieldInput(field: FieldDef, raw: unknown): ValidationOutcome {
  switch (field.control) {
    case 'toggle':
      return { valid: true, value: Boolean(raw) };

    case 'select': {
      const value = String(raw);
      if (field.options && !field.options.includes(value)) {
        return { valid: false, error: `${field.label}: "${value}" is not one of ${field.options.join(', ')}.` };
      }
      return { valid: true, value };
    }

    case 'number': {
      const raw_ = String(raw).trim();
      if (!/^-?\d+$/.test(raw_)) {
        return { valid: false, error: `${field.label}: "${raw_}" is not a whole number.` };
      }
      const value = Number(raw_);
      if (field.min !== undefined && value < field.min) {
        return { valid: false, error: `${field.label}: must be >= ${field.min}.` };
      }
      if (field.max !== undefined && value > field.max) {
        return { valid: false, error: `${field.label}: must be <= ${field.max}.` };
      }
      return { valid: true, value };
    }

    case 'text': {
      const value = String(raw);
      if (field.pattern && !field.pattern.test(value)) {
        return { valid: false, error: `${field.label}: "${value}" doesn't match the expected format.` };
      }
      return { valid: true, value };
    }

    case 'list': {
      const values = Array.isArray(raw) ? raw.map(String) : String(raw).split(',');
      const cleaned = values.map((value) => value.trim()).filter((value) => value.length > 0);
      return { valid: true, value: cleaned };
    }

    default:
      return { valid: true, value: raw };
  }
}

/** Formats a field's current value for display in the field menu. */
export function formatFieldValue(field: FieldDef, value: unknown): string {
  switch (field.control) {
    case 'toggle':
      return value ? 'Yes' : 'No';
    case 'list':
      return Array.isArray(value) && value.length > 0 ? value.join(', ') : '(none)';
    default:
      return value === undefined || value === null || value === '' ? '(unset)' : String(value);
  }
}

/** Formats an array field's value for editing in a comma-separated `TextInput`. */
export function formatListForEdit(value: unknown): string {
  return Array.isArray(value) ? value.join(', ') : '';
}

/**
 * True when any of `changedPaths` should trigger a trigger re-bake:
 * the command namespace (`command`) or any `triggers.*` alias list.
 */
export function shouldRebakeTriggers(changedPaths: Iterable<string>): boolean {
  for (const path of changedPaths) {
    if (path === 'command' || path.startsWith('triggers.')) return true;
  }
  return false;
}
