// Shared GitHub API client for the dashboard. Talks REST v3 and GraphQL v4
// directly from the browser. All requests carry the PAT from storage; GraphQL
// requires it (no anonymous access), REST tolerates its absence at a lower
// rate limit.
import { getToken } from './storage';
import type { RateLimit } from './types';

export const API_ROOT = 'https://api.github.com';
export const GRAPHQL_ROOT = 'https://api.github.com/graphql';

export class GitHubError extends Error {
  status: number;
  rateLimit: RateLimit;
  constructor(message: string, status: number, rateLimit: RateLimit) {
    super(message);
    this.name = 'GitHubError';
    this.status = status;
    this.rateLimit = rateLimit;
  }
}

export function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    ...extra,
  };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

export function parseRateLimit(response: Response): RateLimit {
  const remainingHeader = response.headers.get('X-RateLimit-Remaining');
  const resetHeader = response.headers.get('X-RateLimit-Reset');
  const remaining = remainingHeader === null ? null : Number(remainingHeader);
  const resetAt = resetHeader === null ? null : new Date(Number(resetHeader) * 1000);
  return {
    remaining: remaining === null || Number.isNaN(remaining) ? null : remaining,
    resetAt: resetAt && !Number.isNaN(resetAt.getTime()) ? resetAt : null,
  };
}

function describeStatus(status: number, rateLimit: RateLimit, context: string): string {
  if (status === 401) return `${context}: unauthorized (401). Check your token.`;
  if (status === 404) return `${context}: not found (404). Check the repository.`;
  if (status === 403) {
    const reset = rateLimit.resetAt ? ` Rate limit resets at ${rateLimit.resetAt.toISOString()}.` : '';
    return `${context}: forbidden / rate-limited (403).${reset}`;
  }
  return `${context}: unexpected response (${status}).`;
}

/** REST GET returning parsed JSON plus rate-limit headers. */
export async function ghGet<T>(
  path: string,
  context: string,
): Promise<{ data: T; rateLimit: RateLimit }> {
  const response = await fetch(`${API_ROOT}${path}`, { headers: authHeaders() });
  const rateLimit = parseRateLimit(response);
  if (!response.ok) {
    throw new GitHubError(describeStatus(response.status, rateLimit, context), response.status, rateLimit);
  }
  return { data: (await response.json()) as T, rateLimit };
}

/** REST POST with a JSON body. */
export async function ghPost<T>(path: string, body: unknown, context: string): Promise<T> {
  const response = await fetch(`${API_ROOT}${path}`, {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body),
  });
  const rateLimit = parseRateLimit(response);
  if (!response.ok) {
    throw new GitHubError(describeStatus(response.status, rateLimit, context), response.status, rateLimit);
  }
  return (await response.json()) as T;
}

/** GraphQL POST. Throws on transport errors AND on GraphQL `errors[]`. */
export async function ghGraphQL<T>(
  query: string,
  variables: Record<string, unknown>,
  context: string,
): Promise<{ data: T; rateLimit: RateLimit }> {
  const token = getToken();
  if (!token) {
    throw new GitHubError(`${context}: a token is required for GraphQL.`, 401, {
      remaining: null,
      resetAt: null,
    });
  }
  const response = await fetch(GRAPHQL_ROOT, {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify({ query, variables }),
  });
  const rateLimit = parseRateLimit(response);
  if (!response.ok) {
    throw new GitHubError(describeStatus(response.status, rateLimit, context), response.status, rateLimit);
  }
  const payload = (await response.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (payload.errors && payload.errors.length > 0) {
    throw new GitHubError(
      `${context}: ${payload.errors.map((e) => e.message).join('; ')}`,
      200,
      rateLimit,
    );
  }
  if (!payload.data) {
    throw new GitHubError(`${context}: empty GraphQL response.`, 200, rateLimit);
  }
  return { data: payload.data, rateLimit };
}

/** Validate a token by resolving the authenticated viewer's login. */
export async function validateToken(): Promise<string> {
  const { data } = await ghGraphQL<{ viewer: { login: string } }>(
    'query { viewer { login } }',
    {},
    'Validate token',
  );
  return data.viewer.login;
}

/** Best-effort viewer login (null if unavailable). Used to correlate runs. */
export async function fetchViewerLogin(): Promise<string | null> {
  try {
    return await validateToken();
  } catch {
    return null;
  }
}
