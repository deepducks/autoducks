// Data model for the phase-based dashboard.

export interface Label {
  name: string;
  color: string; // hex without '#', e.g. "0E8A16"
}

export type PullRequestState = 'OPEN' | 'CLOSED' | 'MERGED';

export interface PullRequestRef {
  number: number;
  url: string;
  state: PullRequestState;
  isDraft: boolean;
  headRefName: string | null;
}

export interface SubtaskSummary {
  total: number;
  completed: number;
}

export interface Priority {
  value: string; // Critical | High | Medium | Low (or custom)
  color: string; // hex without '#'
}

export interface WorkflowRun {
  id: number;
  url: string;
  status: string; // queued | in_progress | completed
  conclusion: string | null; // success | failure | cancelled | ...
}

/** One open, board-relevant issue after normalization + enrichment. */
export interface BoardIssue {
  number: number;
  title: string;
  url: string;
  body: string;
  type: string | null; // native issue type name, lowercased
  labels: Label[];
  isTask: boolean; // excluded from the board (aggregated into parent donut)
  pr: PullRequestRef | null;
  subtasks: SubtaskSummary | null;
  priority: Priority | null;
  branch: string | null; // head branch (from PR) for workflow-run matching
  run: WorkflowRun | null; // filled after runs are matched
  maxTurnsWarning: boolean; // latest agent status on this issue is a max_turns stall
}

export type PanelId = 'inbox' | 'design' | 'tactics' | 'delivery' | 'review';
export type LaneId = 'progress' | 'changes' | 'done';

export interface Classification {
  panel: PanelId;
  lane: LaneId;
}

export interface PanelData {
  id: PanelId;
  title: string;
  progress: BoardIssue[];
  changes: BoardIssue[]; // populated only for the review panel
  done: BoardIssue[];
}

export interface RateLimit {
  remaining: number | null;
  resetAt: Date | null;
}
