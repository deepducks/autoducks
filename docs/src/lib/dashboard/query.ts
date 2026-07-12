// One GraphQL query pulls every open issue with the data each card needs:
// labels, native type, body, subtask summary, linked PRs, and the Projects-v2
// priority value. This is what makes a 5s refresh affordable — no per-card
// N+1 REST calls. Workflow runs are fetched separately (Actions is REST-only).
import { ghGraphQL } from './github';
import { resolvePriority } from './classify';
import { getPriorityField } from './storage';
import type { BoardIssue, Label, PullRequestRef, RateLimit, SubtaskSummary } from './types';

const PAGE_SIZE = 50;
const MAX_PAGES = 6; // safety cap: up to 300 open issues

interface GqlLabel {
  name: string;
  color: string;
}
interface GqlPr {
  number: number;
  url: string;
  state: string;
  isDraft: boolean;
  headRefName: string | null;
}
interface GqlComment {
  body: string;
}
interface GqlIssue {
  number: number;
  title: string;
  url: string;
  body: string | null;
  issueType: { name: string } | null;
  labels: { nodes: GqlLabel[] } | null;
  subIssuesSummary: { total: number; completed: number } | null;
  closedByPullRequestsReferences: { nodes: GqlPr[] } | null;
  projectItems: {
    nodes: Array<{ priority: { name: string } | null }>;
  } | null;
  comments: { nodes: GqlComment[] } | null;
}
interface QueryResult {
  repository: {
    issues: {
      pageInfo: { hasNextPage: boolean; endCursor: string | null };
      nodes: GqlIssue[];
    };
  } | null;
}

function buildQuery(): string {
  return `
    query BoardData($owner: String!, $name: String!, $cursor: String, $priorityField: String!) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: ${PAGE_SIZE}, after: $cursor, orderBy: { field: UPDATED_AT, direction: DESC }) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number
            title
            url
            body
            issueType { name }
            labels(first: 30) { nodes { name color } }
            subIssuesSummary { total completed }
            closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
              nodes { number url state isDraft headRefName }
            }
            projectItems(first: 10) {
              nodes {
                priority: fieldValueByName(name: $priorityField) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
            comments(last: 10) { nodes { body } }
          }
        }
      }
    }
  `;
}

function pickPr(nodes: GqlPr[]): PullRequestRef | null {
  if (nodes.length === 0) return null;
  // Prefer a live PR (merged or open) over a stale closed one.
  const ranked = [...nodes].sort((a, b) => prRank(b.state) - prRank(a.state));
  const pr = ranked[0];
  const state = pr.state === 'MERGED' ? 'MERGED' : pr.state === 'CLOSED' ? 'CLOSED' : 'OPEN';
  return { number: pr.number, url: pr.url, state, isDraft: pr.isDraft, headRefName: pr.headRefName };
}

function prRank(state: string): number {
  if (state === 'MERGED') return 3;
  if (state === 'OPEN') return 2;
  return 1; // CLOSED
}

// Fallback subtask progress from a "## Progress" checklist in the issue body,
// used when native sub-issues are unavailable (summary comes back empty).
function parseProgressChecklist(body: string): SubtaskSummary | null {
  const section = body.match(/##\s+Progress\b([\s\S]*?)(?:\n#{1,6}\s|$)/i);
  if (!section) return null;
  const text = section[1];
  const done = (text.match(/^\s*[-*]\s*\[x\]/gim) ?? []).length;
  const todo = (text.match(/^\s*[-*]\s*\[ \]/gim) ?? []).length;
  const total = done + todo;
  return total > 0 ? { total, completed: done } : null;
}

// Marker strings must stay in sync with the source of truth in
// .autoducks/core/feedback/notify-failure.sh (failure category, "run failed")
// and status-comment.sh ("finished" status).
const MAX_TURNS_MARKER = /\*\*Category:\*\*\s*`max_turns`/;
const RUN_FAILED = /\*\*Agent run failed\.\*\*|\*\*Task #\d+ failed\.\*\*/;
const RUN_FINISHED = /✅ \*\*`[^`]+`\*\*: finished/;

// True when the newest terminal-status comment (a failure or a "finished"
// status) is a max_turns failure — i.e. the most recent run stalled on turns
// and nothing has since resumed and finished. Scans newest→oldest.
export function detectMaxTurns(comments: string[]): boolean {
  for (let i = comments.length - 1; i >= 0; i -= 1) {
    const body = comments[i];
    if (RUN_FINISHED.test(body)) return false; // resolved since
    if (RUN_FAILED.test(body)) return MAX_TURNS_MARKER.test(body);
  }
  return false;
}

function normalize(node: GqlIssue): BoardIssue {
  const labels: Label[] = (node.labels?.nodes ?? []).map((l) => ({ name: l.name, color: l.color }));
  const type = node.issueType?.name?.toLowerCase() ?? null;
  const isTask = type === 'task' || labels.some((l) => l.name.toLowerCase() === 'task');
  const body = node.body ?? '';

  let subtasks: SubtaskSummary | null = null;
  const summary = node.subIssuesSummary;
  if (summary && summary.total > 0) {
    subtasks = { total: summary.total, completed: summary.completed };
  } else {
    subtasks = parseProgressChecklist(body);
  }

  const projectPriority =
    node.projectItems?.nodes.map((n) => n.priority?.name).find((v): v is string => Boolean(v)) ?? null;

  const pr = pickPr(node.closedByPullRequestsReferences?.nodes ?? []);

  return {
    number: node.number,
    title: node.title,
    url: node.url,
    body,
    type,
    labels,
    isTask,
    pr,
    subtasks,
    priority: resolvePriority(labels, projectPriority),
    branch: pr?.headRefName ?? null,
    run: null,
    maxTurnsWarning: detectMaxTurns((node.comments?.nodes ?? []).map((c) => c.body ?? '')),
  };
}

/** Fetch and normalize all open issues for a repo (paginated). */
export async function fetchBoardData(
  repo: string,
): Promise<{ issues: BoardIssue[]; rateLimit: RateLimit }> {
  const [owner, name] = repo.split('/');
  const query = buildQuery();
  const issues: BoardIssue[] = [];
  let cursor: string | null = null;
  let lastRateLimit: RateLimit = { remaining: null, resetAt: null };

  const priorityField = getPriorityField();
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const result: { data: QueryResult; rateLimit: RateLimit } = await ghGraphQL<QueryResult>(
      query,
      { owner, name, cursor, priorityField },
      'Load issues',
    );
    lastRateLimit = result.rateLimit;
    const conn = result.data.repository?.issues;
    if (!conn) break;
    for (const node of conn.nodes) issues.push(normalize(node));
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }

  return { issues, rateLimit: lastRateLimit };
}
