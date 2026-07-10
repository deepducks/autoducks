// Persistent dashboard settings. The PAT now lives in localStorage (not
// sessionStorage) so it survives reloads — required because the board's write
// actions and private-repo reads need a token, and GraphQL rejects anonymous
// requests entirely. We migrate any pre-existing sessionStorage token once.

const TOKEN_KEY = 'autoducks.dashboard.token';
const REPO_KEY = 'autoducks.dashboard.repo';
const REPOS_KEY = 'autoducks.dashboard.repos';
const INTERVAL_KEY = 'autoducks.dashboard.refreshInterval';
const AUTOREFRESH_KEY = 'autoducks.dashboard.autoRefresh';
const PRIORITY_FIELD_KEY = 'autoducks.dashboard.priorityField';

export const DEFAULT_REPO = 'deepducks/autoducks';
export const DEFAULT_INTERVAL_MS = 5000;
export const MIN_INTERVAL_MS = 3000;
export const DEFAULT_PRIORITY_FIELD = 'Priority';

export const REPO_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

function migrateToken(): void {
  try {
    const legacy = sessionStorage.getItem(TOKEN_KEY);
    if (legacy && !localStorage.getItem(TOKEN_KEY)) {
      localStorage.setItem(TOKEN_KEY, legacy);
    }
    if (legacy) sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* storage unavailable — ignore */
  }
}

export function getToken(): string | null {
  migrateToken();
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(value: string | null): void {
  try {
    if (value) localStorage.setItem(TOKEN_KEY, value);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}

export function getRepo(): string {
  try {
    const fromQuery = new URLSearchParams(location.search).get('repo');
    if (fromQuery && REPO_PATTERN.test(fromQuery)) return fromQuery;
    const stored = localStorage.getItem(REPO_KEY);
    if (stored && REPO_PATTERN.test(stored)) return stored;
  } catch {
    /* ignore */
  }
  return DEFAULT_REPO;
}

export function setRepo(value: string): void {
  try {
    localStorage.setItem(REPO_KEY, value);
  } catch {
    /* ignore */
  }
}

/** The configured repositories, always including the current one. */
export function getRepos(): string[] {
  let list: string[] = [];
  try {
    const raw = localStorage.getItem(REPOS_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        list = parsed.filter((r): r is string => typeof r === 'string' && REPO_PATTERN.test(r));
      }
    }
  } catch {
    /* ignore */
  }
  const current = getRepo();
  if (!list.includes(current)) list = [current, ...list];
  return [...new Set(list)];
}

function saveRepos(list: string[]): void {
  try {
    localStorage.setItem(REPOS_KEY, JSON.stringify([...new Set(list)]));
  } catch {
    /* ignore */
  }
}

/** Add a repository to the configured list (no-op if already present). */
export function addRepo(repo: string): string[] {
  const list = getRepos();
  if (!list.includes(repo)) list.push(repo);
  saveRepos(list);
  return list;
}

/**
 * Remove a repository. If it was the current one, switch to the first
 * remaining. Never leaves the list empty — falls back to the default repo.
 */
export function removeRepo(repo: string): string[] {
  let list = getRepos().filter((r) => r !== repo);
  if (list.length === 0) list = [DEFAULT_REPO];
  saveRepos(list);
  if (getRepo() === repo) setRepo(list[0]);
  return list;
}

export function getInterval(): number {
  try {
    const raw = Number(localStorage.getItem(INTERVAL_KEY));
    if (Number.isFinite(raw) && raw >= MIN_INTERVAL_MS) return raw;
  } catch {
    /* ignore */
  }
  return DEFAULT_INTERVAL_MS;
}

export function setInterval(ms: number): void {
  try {
    localStorage.setItem(INTERVAL_KEY, String(Math.max(MIN_INTERVAL_MS, Math.round(ms))));
  } catch {
    /* ignore */
  }
}

export function getAutoRefresh(): boolean {
  try {
    return localStorage.getItem(AUTOREFRESH_KEY) !== 'false';
  } catch {
    return true;
  }
}

export function setAutoRefresh(on: boolean): void {
  try {
    localStorage.setItem(AUTOREFRESH_KEY, String(on));
  } catch {
    /* ignore */
  }
}

/** Project-v2 single-select field name the Product agent writes priority to. */
export function getPriorityField(): string {
  try {
    return localStorage.getItem(PRIORITY_FIELD_KEY) || DEFAULT_PRIORITY_FIELD;
  } catch {
    return DEFAULT_PRIORITY_FIELD;
  }
}

export function setPriorityField(name: string): void {
  try {
    localStorage.setItem(PRIORITY_FIELD_KEY, name || DEFAULT_PRIORITY_FIELD);
  } catch {
    /* ignore */
  }
}
