import { promises as fs } from 'node:fs';
import path from 'node:path';
import { Ajv } from 'ajv';
import { CONFIG_SCHEMA } from './schema.js';

/** Path to the config file, relative to a repository root. */
export const CONFIG_RELATIVE_PATH = '.autoducks/autoducks.json';

/** Shown by `version` and the wizard when the config has no pinned `version`. */
export const UNPINNED_VERSION_LABEL = 'unpinned / legacy install';

export interface AutoducksConfig {
  version?: string;
  command?: string;
  providers?: {
    its?: string;
    git?: string;
    llm?: string;
    [key: string]: unknown;
  };
  defaults?: {
    model?: string;
    effort?: 'off' | 'low' | 'medium' | 'high' | 'max';
    max_turns?: number;
    base_branch?: string;
    integration_branch?: string;
    merge_method?: 'auto' | 'merge' | 'squash' | 'rebase';
    [key: string]: unknown;
  };
  orchestrator?: {
    mode?: 'waves' | 'sequential';
    [key: string]: unknown;
  };
  reviewer?: {
    required_check?: boolean;
    check_name?: string;
    auto?: boolean;
    [key: string]: unknown;
  };
  resolver?: {
    auto?: boolean;
    opt_out_label?: string;
    [key: string]: unknown;
  };
  checks?: {
    enabled?: boolean;
    setup?: string;
    commands?: Array<{ name?: string; run: string }>;
    git_hooks?: boolean;
    max_iterations?: number;
    [key: string]: unknown;
  };
  product?: {
    enabled?: boolean;
    schedule?: string;
    priority_backend?: 'auto' | 'project' | 'labels' | 'off';
    project_number?: number | null;
    priority_field?: string;
    auto_merge_duplicates?: boolean;
    max_closes_per_run?: number;
    confidence_threshold?: 'high' | 'medium' | 'low';
    max_issues_per_run?: number;
    provisional_classification?: boolean;
    [key: string]: unknown;
  };
  triggers?: Record<string, string[]>;
  architect?: {
    auto?: boolean;
    [key: string]: unknown;
  };
  engineer?: {
    auto?: boolean;
    [key: string]: unknown;
  };
  context?: Record<string, { parts?: string[]; [key: string]: unknown }>;
  review?: {
    security_guidelines?: string;
    auto_rework?: boolean;
    max_iterations?: number;
    [key: string]: unknown;
  };
  security?: {
    trusted_associations?: string[];
    allow?: string[];
    deny?: string[];
    codeowners?: boolean;
    per_agent?: Record<string, { trusted_associations?: string[]; [key: string]: unknown }>;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

export interface LoadResult {
  config: AutoducksConfig;
  path: string;
}

const ajv = new Ajv({ allErrors: true, strict: false });
const validateConfigSchema = ajv.compile(CONFIG_SCHEMA);

/** Validates `config` against the schema; never throws. */
export function validate(config: unknown): ValidationResult {
  const valid = validateConfigSchema(config);
  if (valid) return { valid: true, errors: [] };
  const errors = (validateConfigSchema.errors ?? []).map(
    (err) => `${err.instancePath || '(root)'} ${err.message ?? 'is invalid'}`,
  );
  return { valid: false, errors };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Additive merge: keys present in `updates` overwrite/recurse into `base`
 * in place (never changing an existing key's position), keys absent from
 * `updates` pass through untouched. Arrays and primitives in `updates`
 * replace the corresponding value in `base` wholesale rather than merging
 * element-by-element.
 */
export function deepMerge<T extends Record<string, unknown>>(base: T, updates: Partial<T>): T {
  const result: Record<string, unknown> = { ...base };
  for (const key of Object.keys(updates)) {
    const updateValue = (updates as Record<string, unknown>)[key];
    const baseValue = (base as Record<string, unknown>)[key];
    result[key] = isPlainObject(updateValue) && isPlainObject(baseValue) ? deepMerge(baseValue, updateValue) : updateValue;
  }
  return result as T;
}

/**
 * Fills in the additive keys this task introduces (`architect.auto`,
 * `engineer.auto`, `reviewer.auto`) when a config predates them, so older
 * configs load with today's always-on behavior made explicit.
 */
export function applyDefaults(config: AutoducksConfig): AutoducksConfig {
  return deepMerge(config, {
    architect: { auto: config.architect?.auto ?? true },
    engineer: { auto: config.engineer?.auto ?? true },
    reviewer: { auto: config.reviewer?.auto ?? true },
  });
}

/** Resolves the absolute path to `.autoducks/autoducks.json` under `root`. */
export function resolveConfigPath(root: string = process.cwd()): string {
  return path.join(root, CONFIG_RELATIVE_PATH);
}

/** Reads, parses, validates, and defaults the config at `<root>/.autoducks/autoducks.json`. */
export async function load(root: string = process.cwd()): Promise<LoadResult> {
  const configPath = resolveConfigPath(root);
  const raw = await fs.readFile(configPath, 'utf8');
  const parsed = JSON.parse(raw) as AutoducksConfig;

  const result = validate(parsed);
  if (!result.valid) {
    throw new Error(`Invalid config at ${configPath}:\n${result.errors.join('\n')}`);
  }

  return { config: applyDefaults(parsed), path: configPath };
}

/**
 * Additively merges `updates` into the config at `<root>/.autoducks/autoducks.json`
 * (or an empty object if none exists yet), validates the result, and writes
 * it back. Unrelated existing keys are never dropped or reordered. Returns
 * the merged config.
 */
export async function write(root: string, updates: Partial<AutoducksConfig>): Promise<AutoducksConfig> {
  const configPath = resolveConfigPath(root);

  let existing: AutoducksConfig = {};
  try {
    const raw = await fs.readFile(configPath, 'utf8');
    existing = JSON.parse(raw) as AutoducksConfig;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }

  const merged = deepMerge(existing, updates);
  const result = validate(merged);
  if (!result.valid) {
    throw new Error(`Refusing to write invalid config to ${configPath}:\n${result.errors.join('\n')}`);
  }

  await fs.mkdir(path.dirname(configPath), { recursive: true });
  await fs.writeFile(configPath, `${JSON.stringify(merged, null, 2)}\n`, 'utf8');

  return merged;
}

/** The pinned release tag, or {@link UNPINNED_VERSION_LABEL} when absent. */
export function getVersion(config: AutoducksConfig): string {
  return config.version ?? UNPINNED_VERSION_LABEL;
}

/** Pure transform: returns a new config with `version` set to `version`. */
export function setVersion(config: AutoducksConfig, version: string): AutoducksConfig {
  return deepMerge(config, { version });
}
