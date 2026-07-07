import { toExcerpt } from './transforms';
import type { FetchResult, IssueCard, RateLimit, RepoView } from './types';

const TOKEN_KEY = 'autoducks.dashboard.token';
const API_ROOT = 'https://api.github.com';

/** Reads the dashboard's PAT from sessionStorage. Never touches localStorage. */
export function getToken(): string | null {
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function authHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
  };
  const token = getToken();
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}

function parseRateLimit(response: Response): RateLimit {
  const remainingHeader = response.headers.get('X-RateLimit-Remaining');
  const resetHeader = response.headers.get('X-RateLimit-Reset');
  const remaining = remainingHeader === null ? null : Number(remainingHeader);
  const resetAt =
    resetHeader === null ? null : new Date(Number(resetHeader) * 1000);
  return {
    remaining: remaining === null || Number.isNaN(remaining) ? null : remaining,
    resetAt: resetAt && !Number.isNaN(resetAt.getTime()) ? resetAt : null,
  };
}

async function handleErrorResponse(
  response: Response,
  context: string,
): Promise<never> {
  const rateLimit = parseRateLimit(response);

  if (response.status === 404) {
    throw new Error(`${context}: not found (404). Check the repo and endpoint.`);
  }

  if (response.status === 403) {
    const resetMessage = rateLimit.resetAt
      ? ` Rate limit resets at ${rateLimit.resetAt.toISOString()}.`
      : '';
    throw new Error(`${context}: rate-limited (403).${resetMessage}`);
  }

  throw new Error(`${context}: unexpected response (${response.status}).`);
}

const viewsCache = new Map<string, Promise<FetchResult<RepoView[]>>>();

export function invalidateViewsCache(repo?: string): void {
  if (repo) {
    viewsCache.delete(repo);
  } else {
    viewsCache.clear();
  }
}

export async function fetchViews(repo: string): Promise<FetchResult<RepoView[]>> {
  const cached = viewsCache.get(repo);
  if (cached) return cached;

  const promise = (async (): Promise<FetchResult<RepoView[]>> => {
    const response = await fetch(`${API_ROOT}/repos/${repo}/issues/views`, {
      headers: authHeaders(),
    });

    if (!response.ok) {
      await handleErrorResponse(response, `fetchViews(${repo})`);
    }

    const rateLimit = parseRateLimit(response);
    const body = await response.json();

    if (!Array.isArray(body)) {
      throw new Error(`fetchViews(${repo}): unexpected response shape.`);
    }

    const data: RepoView[] = body.map((view) => ({
      id: view.id,
      name: view.name,
      color: view.color,
      icon: view.icon,
      filter: view.filter,
    }));

    return { data, rateLimit };
  })();

  viewsCache.set(repo, promise);

  promise.catch(() => {
    viewsCache.delete(repo);
  });

  return promise;
}

export async function fetchColumnIssues(
  view: RepoView,
  repo: string,
): Promise<FetchResult<{ issues: IssueCard[]; totalCount: number }>> {
  const encodedFilter = encodeURIComponent(view.filter);
  const url = `${API_ROOT}/search/issues?q=${encodedFilter}+repo:${repo}&per_page=50&sort=updated&order=desc`;

  const response = await fetch(url, { headers: authHeaders() });

  if (!response.ok) {
    await handleErrorResponse(response, `fetchColumnIssues(${view.name})`);
  }

  const rateLimit = parseRateLimit(response);
  const body = await response.json();

  if (!body || !Array.isArray(body.items)) {
    throw new Error(`fetchColumnIssues(${view.name}): unexpected response shape.`);
  }

  const issues: IssueCard[] = body.items.map((issue: any) => ({
    number: issue.number,
    title: issue.title,
    bodyExcerpt: toExcerpt(issue.body ?? null),
    labels: (issue.labels ?? []).map((label: any) => ({
      name: label.name,
      color: label.color,
    })),
    htmlUrl: issue.html_url,
  }));

  return {
    data: { issues, totalCount: body.total_count ?? issues.length },
    rateLimit,
  };
}
