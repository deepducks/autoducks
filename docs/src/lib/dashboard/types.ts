export interface RepoView {
  id: number;
  name: string;
  color: string; // hex, e.g. "#0075ca"
  icon: string; // icon identifier, e.g. "rocket" or "label"
  filter: string; // GitHub filter query, e.g. "is:open label:Work:progress"
}

export interface IssueCard {
  number: number;
  title: string;
  bodyExcerpt: string; // first 120 chars of body, Markdown stripped
  labels: Array<{ name: string; color: string }>;
  htmlUrl: string;
}

export interface BoardColumn {
  view: RepoView;
  issues: IssueCard[];
  totalCount: number;
  loading: boolean;
  error: string | null;
}

// Handle returned by createColumn (313) and driven by the board (314).
export interface ColumnHandle {
  root: HTMLElement; // board appends this
  setLoading(): void; // show skeleton shimmer
  setIssues(cards: HTMLElement[], totalCount: number): void; // [] → empty state
  setError(message: string, onRetry: () => void): void;
  setPulsing(on: boolean): void; // refresh indicator dot
}

// Factory signatures the board (314) imports — implemented in 312 / 313.
export type CreateIssueCard = (issue: IssueCard) => HTMLElement;
export type CreateColumn = (view: RepoView) => ColumnHandle;

export interface RateLimit {
  remaining: number | null;
  resetAt: Date | null;
}

export interface FetchResult<T> {
  data: T;
  rateLimit: RateLimit;
}
