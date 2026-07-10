// Drag → slash-command writes. Namespace is empty ("") in this repo, so the
// bare short forms are posted (parse-directive.sh). Inbox has no command and
// is therefore not a drop target.
import { ghPost } from './github';
import { PANEL_ORDER } from './classify';
import type { PanelId } from './types';

export const PANEL_COMMAND: Record<PanelId, string | null> = {
  inbox: null,
  design: '/design',
  tactics: '/tactics',
  delivery: '/execute',
  review: '/review',
};

const DELIVERY_INDEX = PANEL_ORDER.indexOf('delivery'); // 3

/**
 * Drop permission. Cards drag only from a "done" lane (enforced at the DOM
 * layer). Forward is always allowed; backward only before Delivery; Delivery
 * and Review are locked forward-only.
 */
export function canDrop(source: PanelId, target: PanelId): boolean {
  if (PANEL_COMMAND[target] === null) return false;
  const s = PANEL_ORDER.indexOf(source);
  const t = PANEL_ORDER.indexOf(target);
  if (t > s) return true; // forward
  if (s < DELIVERY_INDEX) return true; // pre-delivery re-trigger (back or lateral)
  return false;
}

/** Whether a done-lane card in `source` has any legal destination at all. */
export function hasAnyTarget(source: PanelId): boolean {
  return PANEL_ORDER.some((p) => p !== source && canDrop(source, p)) || canDrop(source, source);
}

/** Optional directives appended to the command (parse-directive.sh grammar). */
export interface CommandOptions {
  model?: string;
  effort?: string;
  turns?: number;
  auto?: string; // e.g. "engineer+execute"
}

export function buildCommand(target: PanelId, options: CommandOptions = {}): string {
  const base = PANEL_COMMAND[target];
  if (!base) throw new Error(`Panel ${target} has no command`);
  const parts = [base];
  if (options.model) parts.push(`model:${options.model}`);
  if (options.effort) parts.push(`effort:${options.effort}`);
  if (options.turns) parts.push(`turns:${options.turns}`);
  if (options.auto) parts.push(`#auto:${options.auto}`);
  return parts.join(' ');
}

export async function postComment(repo: string, issue: number, body: string): Promise<{ html_url: string }> {
  return ghPost<{ html_url: string }>(
    `/repos/${repo}/issues/${issue}/comments`,
    { body },
    'Post command',
  );
}
