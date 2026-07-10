export interface AgentCard {
  /** Display name, e.g. "Architect" */
  name: string;
  /** Layer/role subtitle, e.g. "Design" */
  layer: string;
  /** One-sentence description (<= ~120 chars) */
  description: string;
  /** Trigger aliases WITHOUT the leading slash; the card renders the "/" prefix, e.g. ["architect", "design"] */
  aliases: string[];
  /** Link into the agent's docs page */
  href: string;
  /** Icon identifier: Starlight built-in icon name OR path/id of a local SVG */
  icon: string;
  /** Accent utility class already defined in custom.css, e.g. "agent-design" */
  accentClass: string;
}

export const AGENT_CARDS: AgentCard[] = [
  {
    name: 'Architect',
    layer: 'Design',
    description:
      'Creates or revises the design of a feature or bug directly in the issue body, classifying it as Feature or Bug.',
    aliases: ['architect', 'design'],
    href: '/agents/architect',
    icon: 'pencil',
    accentClass: 'agent-design',
  },
  {
    name: 'Engineer',
    layer: 'Tactics',
    description: 'Breaks the design into task issues organized into dependency waves.',
    aliases: ['engineer', 'tactics'],
    href: '/agents/engineer',
    icon: 'puzzle',
    accentClass: 'agent-tactical',
  },
  {
    name: 'Maestro',
    layer: 'Orchestration',
    description:
      'Owns branches and PRs and dispatches execution waves in parallel — pure bash, no LLM.',
    aliases: ['execute', 'run', 'work'],
    href: '/agents/maestro',
    icon: 'rocket',
    accentClass: 'agent-wave',
  },
  {
    name: 'Developer',
    layer: 'Build',
    description: 'Implements one task and merges its PR into the pipeline branch.',
    aliases: ['execute'],
    href: '/agents/developer',
    icon: 'laptop',
    accentClass: 'agent-exec',
  },
  {
    name: 'Reviewer',
    layer: 'Review gate',
    description:
      'Reviews a finished PR against its design and acceptance criteria — read-only, never merges.',
    aliases: ['review'],
    href: '/agents/reviewer',
    icon: 'approve-check',
    accentClass: 'agent-exec',
  },
  {
    name: 'Product Owner',
    layer: 'Backlog',
    description: 'Grooms the backlog: assigns priorities and proposes duplicate groupings.',
    aliases: ['triage', 'merge'],
    href: '/agents/product',
    icon: 'list-format',
    accentClass: 'agent-tactical',
  },
  {
    name: 'Rework',
    layer: 'Recovery',
    description:
      'Distills unresolved review feedback into one follow-up task and reverts the PR to draft.',
    aliases: ['rework'],
    href: '/agents/utilities#rework',
    icon: 'random',
    accentClass: 'agent-revert',
  },
  {
    name: 'Defer',
    layer: 'Recovery',
    description:
      'Captures unresolved review feedback as a follow-up issue so the PR can be merged or closed now.',
    aliases: ['defer'],
    href: '/agents/utilities#defer',
    icon: 'comment',
    accentClass: 'agent-revert',
  },
  {
    name: 'Revert',
    layer: 'Lifecycle',
    description: 'Undoes planning and restores the human-authored issue.',
    aliases: ['revert'],
    href: '/agents/utilities#revert',
    icon: 'left-arrow',
    accentClass: 'agent-revert',
  },
];
