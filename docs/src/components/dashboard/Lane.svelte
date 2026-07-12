<script lang="ts">
  import Card from './Card.svelte';
  import type { BoardIssue, LaneId, PanelId } from '../../lib/dashboard/types';

  interface MoveTarget {
    id: PanelId;
    title: string;
  }
  interface Props {
    panel: PanelId;
    lane: LaneId;
    issues: BoardIssue[];
    pending?: Map<number, string>;
    dropState?: 'idle' | 'valid' | 'invalid';
    moveTargets?: MoveTarget[];
    onmove?: (issue: BoardIssue, target: PanelId) => void;
    ondragstartcard?: (issue: BoardIssue, event: DragEvent) => void;
    ondragendcard?: () => void;
    ondragover?: (event: DragEvent) => void;
    ondragleave?: () => void;
    ondrop?: (event: DragEvent) => void;
  }
  let {
    panel,
    lane,
    issues,
    pending = new Map(),
    dropState = 'idle',
    moveTargets = [],
    onmove,
    ondragstartcard,
    ondragendcard,
    ondragover,
    ondragleave,
    ondrop,
  }: Props = $props();

  let title = $derived(
    lane === 'progress' ? 'In progress' : lane === 'changes' ? 'Changes requested' : 'Done',
  );
  let draggable = $derived(lane === 'done');
</script>

<div
  class="lane"
  class:lane--done={lane === 'done'}
  class:lane--changes={lane === 'changes'}
  class:lane--drop-valid={dropState === 'valid'}
  class:lane--drop-invalid={dropState === 'invalid'}
  ondragover={ondragover}
  ondragleave={ondragleave}
  ondrop={ondrop}
  role="list"
  aria-label={`${panel} ${title}`}
>
  <div class="lane__head">
    <span class="lane__title">{title}</span>
    <span class="lane__count">{issues.length}</span>
  </div>

  {#if issues.length === 0}
    <p class="lane__empty">—</p>
  {:else}
    {#each issues as issue (issue.number)}
      <Card
        {issue}
        draggable={draggable && !pending.has(issue.number)}
        moveTargets={draggable && !pending.has(issue.number) ? moveTargets : []}
        {onmove}
        pendingCommand={pending.get(issue.number) ?? null}
        ondragstart={ondragstartcard}
        ondragend={ondragendcard}
      />
    {/each}
  {/if}
</div>

<style>
  .lane {
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
    padding: 0.5rem;
    border-radius: 0.45rem;
    background: color-mix(in srgb, var(--sl-color-gray-6) 55%, transparent);
    min-height: 3rem;
    transition: box-shadow 0.12s ease, background 0.12s ease;
  }
  .lane--done {
    background: color-mix(in srgb, var(--sl-color-green, #3fb950) 6%, transparent);
  }
  .lane--changes {
    background: color-mix(in srgb, #d93f0b 8%, transparent);
  }
  .lane--drop-valid {
    box-shadow: inset 0 0 0 2px var(--sl-color-accent, #3b82f6);
    background: color-mix(in srgb, var(--sl-color-accent, #3b82f6) 10%, transparent);
  }
  .lane--drop-invalid {
    box-shadow: inset 0 0 0 2px var(--sl-color-red, #f85149);
    background: color-mix(in srgb, var(--sl-color-red, #f85149) 8%, transparent);
    cursor: not-allowed;
  }

  .lane__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 0.15rem;
  }
  .lane__title {
    font-size: 0.68rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--sl-color-gray-3);
  }
  .lane__count {
    font-size: 0.68rem;
    color: var(--sl-color-gray-3);
    font-variant-numeric: tabular-nums;
  }
  .lane__empty {
    margin: 0;
    padding: 0.35rem 0.15rem;
    color: var(--sl-color-gray-4);
    font-size: 0.8rem;
  }
</style>
