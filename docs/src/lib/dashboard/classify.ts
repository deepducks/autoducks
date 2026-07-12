// Label taxonomy + "furthest phase wins" bucketing. Source of truth:
// .autoducks/core/feedback/progress-labels.sh and .autoducks/agents/product.
import type { BoardIssue, Classification, Label, PanelId, Priority } from './types';

export const PANEL_ORDER: PanelId[] = ['inbox', 'design', 'tactics', 'delivery', 'review'];

export const PANEL_TITLES: Record<PanelId, string> = {
  inbox: 'Inbox',
  design: 'Design',
  tactics: 'Tactics',
  delivery: 'Delivery',
  review: 'Review',
};

// Phase accent colors, drawn from the label palette (progress-labels.sh).
export const PANEL_COLORS: Record<PanelId, string> = {
  inbox: '#8B949E',
  design: '#1F6FEB',
  tactics: '#D93F0B',
  delivery: '#0E8A16',
  review: '#FBCA04',
};

// The autoducks-managed label set — hidden from the card's domain-label row.
const MANAGED_LABEL_PATTERNS: RegExp[] = [
  /^design:(draft|done)$/i,
  /^tactics:(crafting|done)$/i,
  /^work:(orchestrating|coding|done)$/i,
  /^review:(reviewing|done|changes)$/i,
  /^resolve:(resolving|done|conflict|off)$/i,
  /^(feature|bug|task|draft)$/i,
  /^priority:/i,
  /^auto-resolved$/i,
];

const PRIORITY_COLORS: Record<string, string> = {
  critical: 'B60205',
  high: 'D93F0B',
  medium: 'FBCA04',
  low: '0E8A16',
};
const PRIORITY_FALLBACK_COLOR = 'CFD3D7';

function hasLabel(labels: Label[], name: string): boolean {
  const target = name.toLowerCase();
  return labels.some((l) => l.name.toLowerCase() === target);
}

export function isFeatureOrBug(issue: BoardIssue): boolean {
  return (
    issue.type === 'feature' ||
    issue.type === 'bug' ||
    hasLabel(issue.labels, 'feature') ||
    hasLabel(issue.labels, 'bug')
  );
}

/**
 * Assign an issue to exactly one (panel, lane), checking phases most-advanced
 * first so the "…sem nenhuma outra label do workflow" clauses hold implicitly.
 * Returns null for Task issues (shown only inside a parent's subtask donut).
 */
export function classify(issue: BoardIssue): Classification | null {
  // Task issues are aggregated into a parent's donut, never shown as cards.
  // Detect directly (not just via the normalized flag) so classify is correct
  // for any issue shape.
  if (issue.isTask || issue.type === 'task' || hasLabel(issue.labels, 'task')) return null;
  const l = issue.labels;

  // Review (most advanced)
  if (hasLabel(l, 'Review:changes'))   return { panel: 'review', lane: 'changes' };
  if (hasLabel(l, 'Review:reviewing')) return { panel: 'review', lane: 'progress' };
  if (hasLabel(l, 'Review:done'))      return { panel: 'review', lane: 'done' };

  // Delivery — feature/bug pipelines only
  if (isFeatureOrBug(issue)) {
    if (hasLabel(l, 'Work:orchestrating') || hasLabel(l, 'Work:coding')) {
      return { panel: 'delivery', lane: 'progress' };
    }
    if (hasLabel(l, 'Work:done')) return { panel: 'delivery', lane: 'done' };
  }

  // Tactics
  if (hasLabel(l, 'Tactics:crafting')) return { panel: 'tactics', lane: 'progress' };
  if (hasLabel(l, 'Tactics:done')) return { panel: 'tactics', lane: 'done' };

  // Design
  if (hasLabel(l, 'Design:draft')) return { panel: 'design', lane: 'progress' };
  if (hasLabel(l, 'Design:done')) return { panel: 'design', lane: 'done' };

  // Inbox — done once classified as feature/bug, else still triaging
  return { panel: 'inbox', lane: isFeatureOrBug(issue) ? 'done' : 'progress' };
}

/** Labels to show on card line 2 — everything except the managed workflow set. */
export function domainLabels(labels: Label[]): Label[] {
  return labels.filter((label) => !MANAGED_LABEL_PATTERNS.some((re) => re.test(label.name)));
}

/** The Feature/Bug type chip shown on line 2 (null for anything else). */
export function typeChip(issue: BoardIssue): 'Feature' | 'Bug' | null {
  if (issue.type === 'bug' || hasLabel(issue.labels, 'bug')) return 'Bug';
  if (issue.type === 'feature' || hasLabel(issue.labels, 'feature')) return 'Feature';
  return null;
}

/**
 * Resolve priority from either Product-agent backend: a `Priority:<Value>`
 * label, or a Projects-v2 single-select value. Label wins if both present.
 */
export function resolvePriority(labels: Label[], projectPriority: string | null): Priority | null {
  const labelMatch = labels.find((l) => /^priority:/i.test(l.name));
  const raw = labelMatch ? labelMatch.name.split(':').slice(1).join(':').trim() : projectPriority;
  if (!raw) return null;
  const color = PRIORITY_COLORS[raw.toLowerCase()] ?? PRIORITY_FALLBACK_COLOR;
  return { value: raw, color };
}

export type PriorityGlyph = 'critical' | 'high' | 'medium' | 'low' | 'unknown';

// Map a (possibly custom) priority value to a chevron glyph. Mirrors the
// PRIORITY_COLORS keys; anything unrecognized → 'unknown' (neutral bar).
export function priorityGlyph(value: string): PriorityGlyph {
  switch (value.toLowerCase()) {
    case 'critical': return 'critical';
    case 'high':     return 'high';
    case 'medium':   return 'medium';
    case 'low':      return 'low';
    default:         return 'unknown';
  }
}
