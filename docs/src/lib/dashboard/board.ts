// Orchestrates a full board load: issues (GraphQL) + workflow runs (REST),
// then buckets into the five phase panels.
import { fetchBoardData } from './query';
import { fetchRuns, type RecentRun } from './runs';
import { classify, PANEL_ORDER, PANEL_TITLES } from './classify';
import type { BoardIssue, PanelData, PanelId, RateLimit } from './types';

export interface BoardLoad {
  issues: BoardIssue[];
  recentRuns: RecentRun[];
  rateLimit: RateLimit;
}

function tighter(a: RateLimit, b: RateLimit): RateLimit {
  if (a.remaining === null) return b;
  if (b.remaining === null) return a;
  return a.remaining <= b.remaining ? a : b;
}

/** Fetch issues + runs and attach each issue's branch-matched run. */
export async function loadBoard(repo: string): Promise<BoardLoad> {
  const { issues, rateLimit } = await fetchBoardData(repo);

  // Runs are best-effort — a failure (e.g. Actions disabled) must not blank
  // the board, just leave workflow bullets empty.
  let rate = rateLimit;
  let recentRuns: RecentRun[] = [];
  try {
    const { byBranch, recent, rateLimit: runsRate } = await fetchRuns(repo);
    for (const issue of issues) issue.run = byBranch.get(issue.number) ?? null;
    recentRuns = recent;
    rate = tighter(rateLimit, runsRate);
  } catch {
    /* ignore runs errors */
  }

  return { issues, recentRuns, rateLimit: rate };
}

/** Pure bucketing so the UI can recompute panels reactively. */
export function assemblePanels(issues: BoardIssue[]): PanelData[] {
  const panels = {} as Record<PanelId, PanelData>;
  for (const id of PANEL_ORDER) {
    panels[id] = { id, title: PANEL_TITLES[id], progress: [], changes: [], done: [] };
  }

  for (const issue of issues) {
    const c = classify(issue);
    if (!c) continue;
    panels[c.panel][c.lane].push(issue);
  }

  return PANEL_ORDER.map((id) => panels[id]);
}
