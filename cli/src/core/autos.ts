import { deepMerge, type AutoducksConfig } from './config.js';

export type AutoId =
  | 'auto_groom'
  | 'orchestration_mode'
  | 'auto_checks'
  | 'auto_resolve'
  | 'auto_rework'
  | 'auto_spec'
  | 'auto_plan'
  | 'auto_review';

export type OrchestratorMode = 'waves' | 'sequential';

export interface AutoMapping {
  readonly id: AutoId;
  readonly label: string;
  /** Dotted path into `AutoducksConfig`, e.g. `"product.enabled"`. */
  readonly configKey: string;
  readonly enabledValue: boolean | OrchestratorMode;
  readonly manualValue: boolean | OrchestratorMode;
}

/**
 * Single source of truth for auto ⇄ config-key mapping (design "wizard/Choose
 * your autos"). Both the wizard and `applyAuto` below derive from this table
 * so the two can never drift apart.
 */
export const AUTOS: readonly AutoMapping[] = [
  { id: 'auto_groom', label: 'Auto Groom', configKey: 'product.enabled', enabledValue: true, manualValue: false },
  {
    id: 'orchestration_mode',
    label: 'Orchestration Mode',
    configKey: 'orchestrator.mode',
    enabledValue: 'waves',
    manualValue: 'sequential',
  },
  { id: 'auto_checks', label: 'Auto Checks', configKey: 'checks.enabled', enabledValue: true, manualValue: false },
  { id: 'auto_resolve', label: 'Auto Resolve', configKey: 'resolver.auto', enabledValue: true, manualValue: false },
  { id: 'auto_rework', label: 'Auto Rework', configKey: 'review.auto_rework', enabledValue: true, manualValue: false },
  { id: 'auto_spec', label: 'Auto Spec', configKey: 'architect.auto', enabledValue: true, manualValue: false },
  { id: 'auto_plan', label: 'Auto Plan', configKey: 'engineer.auto', enabledValue: true, manualValue: false },
  { id: 'auto_review', label: 'Auto Review', configKey: 'reviewer.auto', enabledValue: true, manualValue: false },
] as const;

/** Default `product.schedule` written when Auto Groom is enabled and no schedule exists yet. */
const DEFAULT_PRODUCT_SCHEDULE = '0 9 * * *';

export function getAuto(id: AutoId): AutoMapping {
  const mapping = AUTOS.find((auto) => auto.id === id);
  if (!mapping) throw new Error(`Unknown auto: ${id}`);
  return mapping;
}

/** Builds `{ a: { b: value } }` from dotted key `"a.b"`. */
function pathToUpdate(dottedKey: string, value: unknown): Record<string, unknown> {
  const segments = dottedKey.split('.');
  return segments.reduceRight<unknown>((acc, segment) => ({ [segment]: acc }), value) as Record<string, unknown>;
}

/**
 * Pure transform: applies an auto's enabled/manual value to `config`,
 * returning a new config with every other key untouched. `value` is
 * normally a boolean (on/off); `orchestration_mode` also accepts an
 * explicit `"waves" | "sequential"` mode directly.
 */
export function applyAuto(config: AutoducksConfig, id: AutoId, value: boolean | OrchestratorMode): AutoducksConfig {
  const mapping = getAuto(id);
  const resolvedValue = typeof value === 'boolean' ? (value ? mapping.enabledValue : mapping.manualValue) : value;

  let next = deepMerge(config, pathToUpdate(mapping.configKey, resolvedValue) as Partial<AutoducksConfig>);

  if (id === 'auto_groom' && resolvedValue === true && !next.product?.schedule) {
    next = deepMerge(next, { product: { schedule: DEFAULT_PRODUCT_SCHEDULE } });
  }

  return next;
}
