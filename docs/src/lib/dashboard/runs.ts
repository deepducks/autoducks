// Workflow runs. GitHub Actions has no "runs for issue N" filter, so we pull
// the latest 100 runs in one call and map them back to issues via the branch
// convention feature/<N>-slug | fix/<N>-slug (branch-prefix.sh:35-39).
import { ghGet } from './github';
import type { RateLimit, WorkflowRun } from './types';

const BRANCH_ISSUE = /^(?:feature|fix)\/(\d+)/;

interface RestRun {
  id: number;
  html_url: string;
  status: string;
  conclusion: string | null;
  head_branch: string | null;
  event: string;
  run_started_at: string | null;
  created_at: string;
  triggering_actor: { login: string } | null;
}

/** A recent run with the metadata needed to correlate a just-triggered agent. */
export interface RecentRun extends WorkflowRun {
  event: string;
  actor: string | null;
  createdAt: number;
  branch: string | null;
}

/**
 * Fetch the latest 100 runs once. Returns both the branch→issue map (reliable
 * for Delivery-phase runs on feature/fix branches) and the raw recent list
 * (used to correlate a run just triggered by an issue_comment, which runs on
 * the default branch and so cannot be matched by branch name).
 */
export async function fetchRuns(
  repo: string,
): Promise<{ byBranch: Map<number, WorkflowRun>; recent: RecentRun[]; rateLimit: RateLimit }> {
  const { data, rateLimit } = await ghGet<{ workflow_runs: RestRun[] }>(
    `/repos/${repo}/actions/runs?per_page=100`,
    'Load workflow runs',
  );

  const latest = new Map<number, { at: number; run: WorkflowRun }>();
  const recent: RecentRun[] = [];
  for (const run of data.workflow_runs ?? []) {
    const at = new Date(run.run_started_at ?? run.created_at).getTime();
    recent.push({
      id: run.id,
      url: run.html_url,
      status: run.status,
      conclusion: run.conclusion,
      event: run.event,
      actor: run.triggering_actor?.login ?? null,
      createdAt: at,
      branch: run.head_branch ?? null,
    });

    const match = BRANCH_ISSUE.exec(run.head_branch ?? '');
    if (!match) continue;
    const issue = Number(match[1]);
    const existing = latest.get(issue);
    if (!existing || at > existing.at) {
      latest.set(issue, {
        at,
        run: { id: run.id, url: run.html_url, status: run.status, conclusion: run.conclusion },
      });
    }
  }

  const byBranch = new Map<number, WorkflowRun>();
  for (const [issue, { run }] of latest) byBranch.set(issue, run);
  return { byBranch, recent, rateLimit };
}

/**
 * Correlate an active run to an issue whose command was just posted. The
 * comment fires several issue_comment workflows; the non-matching ones exit in
 * seconds, so the one still queued/in-progress a moment later is the real
 * agent. We match by actor (the poster) and start time (after the post).
 */
export function correlateTriggeredRun(
  recent: RecentRun[],
  postedAt: number,
  actor: string | null,
  usedRunIds: Set<number>,
): WorkflowRun | null {
  const SKEW_MS = 10_000;
  const candidates = recent
    .filter((r) => !usedRunIds.has(r.id))
    .filter((r) => r.event === 'issue_comment' || r.event === 'workflow_dispatch' || r.event === 'dynamic')
    .filter((r) => r.status !== 'completed') // still queued or in_progress
    .filter((r) => r.createdAt >= postedAt - SKEW_MS)
    .filter((r) => !actor || r.actor === null || r.actor === actor)
    .sort((a, b) => b.createdAt - a.createdAt);
  const chosen = candidates[0];
  if (!chosen) return null;
  usedRunIds.add(chosen.id);
  return { id: chosen.id, url: chosen.url, status: chosen.status, conclusion: chosen.conclusion };
}

/** Bullet color mirroring the label palette (progress-labels.sh). */
export function runColor(run: WorkflowRun): string {
  if (run.status !== 'completed') return '#FBCA04'; // queued / in_progress
  switch (run.conclusion) {
    case 'success':
      return '#0E8A16';
    case 'failure':
    case 'timed_out':
    case 'startup_failure':
      return '#D93F0B';
    case 'cancelled':
    case 'skipped':
    case 'stale':
      return '#8B949E';
    default:
      return '#8B949E';
  }
}

export function runLabel(run: WorkflowRun): string {
  if (run.status !== 'completed') return run.status.replace('_', ' ');
  return run.conclusion ?? 'completed';
}
