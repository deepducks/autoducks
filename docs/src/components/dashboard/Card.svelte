<script lang="ts">
  import Donut from './Donut.svelte';
  import { domainLabels, priorityGlyph, typeChip } from '../../lib/dashboard/classify';
  import { runColor, runLabel } from '../../lib/dashboard/runs';
  import type { BoardIssue, PanelId, PullRequestState } from '../../lib/dashboard/types';

  interface MoveTarget {
    id: PanelId;
    title: string;
  }
  interface Props {
    issue: BoardIssue;
    draggable?: boolean;
    pendingCommand?: string | null;
    moveTargets?: MoveTarget[];
    onmove?: (issue: BoardIssue, target: PanelId) => void;
    ondragstart?: (issue: BoardIssue, event: DragEvent) => void;
    ondragend?: () => void;
  }
  let {
    issue,
    draggable = false,
    pendingCommand = null,
    moveTargets = [],
    onmove,
    ondragstart,
    ondragend,
  }: Props = $props();

  let menuOpen = $state(false);
  let showMenu = $derived(draggable && moveTargets.length > 0);

  function pickTarget(target: PanelId) {
    menuOpen = false;
    onmove?.(issue, target);
  }

  let labels = $derived(domainLabels(issue.labels));
  let chip = $derived(typeChip(issue));

  const PR_COLORS: Record<PullRequestState, string> = {
    OPEN: '#1a7f37',
    MERGED: '#8250df',
    CLOSED: '#cf222e',
  };
  let prColor = $derived(issue.pr ? (issue.pr.isDraft ? '#6e7781' : PR_COLORS[issue.pr.state]) : '');
  let prTitle = $derived(
    issue.pr ? `PR #${issue.pr.number} — ${issue.pr.isDraft ? 'draft' : issue.pr.state.toLowerCase()}` : '',
  );

  function onDragStart(event: DragEvent) {
    ondragstart?.(issue, event);
  }
</script>

<div
  class="card"
  class:card--draggable={draggable}
  class:card--pending={Boolean(pendingCommand)}
  draggable={draggable}
  ondragstart={onDragStart}
  ondragend={() => ondragend?.()}
  role="listitem"
>
  <!-- Line 1: id · title · priority -->
  <div class="card__line card__line--head">
    <span class="card__id">#{issue.number}</span>
    <a class="card__title" href={issue.url} target="_blank" rel="noopener noreferrer" title={issue.title}>
      {issue.title}
    </a>
    {#if issue.priority}
      {@const glyph = priorityGlyph(issue.priority.value)}
      <svg
        class="card__priority"
        viewBox="0 0 16 16"
        style={`--pri:#${issue.priority.color}`}
        title={`Priority: ${issue.priority.value}`}
        aria-label={`Priority ${issue.priority.value}`}
      >
        {#if glyph === 'critical'}
          <path fill="currentColor" d="M8 2.6 L12.6 6.2 L12.6 4.7 L8 4.1 L3.4 4.7 L3.4 6.2 Z" />
          <path fill="currentColor" d="M8 6 L12.6 9.6 L12.6 8.1 L8 7.5 L3.4 8.1 L3.4 9.6 Z" />
          <path fill="currentColor" d="M8 9.4 L12.6 13 L12.6 11.5 L8 10.9 L3.4 11.5 L3.4 13 Z" />
        {:else if glyph === 'high'}
          <path fill="currentColor" d="M8 4 L12.6 7.6 L12.6 6.1 L8 5.5 L3.4 6.1 L3.4 7.6 Z" />
          <path fill="currentColor" d="M8 7.4 L12.6 11 L12.6 9.5 L8 8.9 L3.4 9.5 L3.4 11 Z" />
        {:else if glyph === 'medium'}
          <path fill="currentColor" d="M8 6.2 L12.6 9.8 L12.6 8.3 L8 7.7 L3.4 8.3 L3.4 9.8 Z" />
        {:else if glyph === 'low'}
          <path fill="currentColor" d="M8 9.8 L12.6 6.2 L12.6 7.7 L8 8.3 L3.4 7.7 L3.4 6.2 Z" />
        {:else}
          <path
            fill="currentColor"
            d="M4.2 7.2H11.8A0.8 0.8 0 0 1 11.8 8.8H4.2A0.8 0.8 0 0 1 4.2 7.2Z"
          />
        {/if}
      </svg>
    {/if}

    {#if issue.maxTurnsWarning}
      <span
        class="card__warn"
        title="Agent hit its turn limit — re-run with a larger turns=<n> budget"
        aria-label="Turn-limit stall"
      >⚠️</span>
    {/if}

    {#if showMenu}
      <div class="card__menu">
        <button
          type="button"
          class="card__menu-btn"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          aria-label={`Move issue #${issue.number}`}
          onclick={() => (menuOpen = !menuOpen)}
        >⋯</button>
        {#if menuOpen}
          <button
            type="button"
            class="card__menu-backdrop"
            aria-label="Close menu"
            onclick={() => (menuOpen = false)}
          ></button>
          <div class="card__menu-list" role="menu">
            <span class="card__menu-head">Move to…</span>
            {#each moveTargets as t (t.id)}
              <button type="button" role="menuitem" onclick={() => pickTarget(t.id)}>{t.title}</button>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <!-- Line 2: type chip · domain labels -->
  {#if chip || labels.length > 0}
    <div class="card__line card__line--labels">
      {#if chip}
        <span class="card__type" class:card__type--bug={chip === 'Bug'}>{chip}</span>
      {/if}
      {#each labels as label (label.name)}
        <span class="card__label" style={`--c:#${label.color}`}>{label.name}</span>
      {/each}
    </div>
  {/if}

  <!-- Line 3: PR · subtask donut · workflow run -->
  {#if issue.pr || issue.subtasks || issue.run || pendingCommand}
    <div class="card__line card__line--meta">
      {#if issue.pr}
        <a
          class="card__pr"
          href={issue.pr.url}
          target="_blank"
          rel="noopener noreferrer"
          title={prTitle}
          style={`--pr:${prColor}`}
        >
          <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
            <path
              fill="currentColor"
              d="M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
            />
          </svg>
          <span>#{issue.pr.number}</span>
        </a>
      {/if}

      {#if issue.subtasks}
        <Donut total={issue.subtasks.total} completed={issue.subtasks.completed} />
      {/if}

      {#if issue.run}
        <a
          class="card__run"
          href={issue.run.url}
          target="_blank"
          rel="noopener noreferrer"
          title={`Workflow #${issue.run.id} — ${runLabel(issue.run)}`}
          style={`--rc:${runColor(issue.run)}`}
        >
          <svg class="card__run-icon" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
            <path
              fill="currentColor"
              d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM6.379 5.227A.25.25 0 0 0 6 5.442v5.117a.25.25 0 0 0 .379.214l4.264-2.559a.25.25 0 0 0 0-.428Z"
            />
          </svg>
          <span class="card__run-id">{issue.run.id}</span>
        </a>
      {/if}

      {#if pendingCommand}
        <span class="card__pending" title="Command posted — will move when the agent picks it up">
          ⏳ {pendingCommand}
        </span>
      {/if}
    </div>
  {/if}
</div>

<style>
  .card {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 0.65rem 0.7rem;
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.5rem;
    background: var(--sl-color-gray-6);
    /* Cards are UI, not selectable content — kills the text I-beam that made
       the whole card read as selectable, and keeps drag clean. */
    user-select: none;
    cursor: default;
  }

  .card__menu {
    position: relative;
    flex: none;
  }
  .card__menu-btn {
    border: none;
    background: transparent;
    color: var(--sl-color-gray-3);
    font-size: 1rem;
    line-height: 1;
    padding: 0 0.15rem;
    cursor: pointer;
    border-radius: 0.25rem;
  }
  .card__menu-btn:hover {
    background: var(--sl-color-gray-5);
    color: var(--sl-color-white);
  }
  .card__menu-backdrop {
    position: fixed;
    inset: 0;
    background: transparent;
    border: none;
    padding: 0;
    z-index: 40;
    cursor: default;
  }
  .card__menu-list {
    position: absolute;
    top: 1.4rem;
    right: 0;
    z-index: 50;
    display: flex;
    flex-direction: column;
    min-width: 8rem;
    padding: 0.25rem;
    background: var(--sl-color-gray-6);
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.4rem;
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
  }
  .card__menu-head {
    padding: 0.2rem 0.45rem;
    font-size: 0.65rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--sl-color-gray-3);
  }
  .card__menu-list button[role='menuitem'] {
    text-align: left;
    padding: 0.35rem 0.45rem;
    border: none;
    background: transparent;
    color: var(--sl-color-gray-1);
    font-size: 0.82rem;
    border-radius: 0.3rem;
    cursor: pointer;
  }
  .card__menu-list button[role='menuitem']:hover {
    background: var(--sl-color-accent, #3b82f6);
    color: var(--sl-color-text-invert, #fff);
  }
  .card--draggable {
    cursor: grab;
  }
  .card--draggable:active {
    cursor: grabbing;
  }
  .card--pending {
    border-color: var(--sl-color-orange, #d18616);
    animation: card-pending-pulse 1.9s ease-in-out infinite;
  }
  @keyframes card-pending-pulse {
    0%,
    100% {
      border-color: color-mix(in srgb, var(--sl-color-orange, #d18616) 30%, var(--sl-color-gray-5));
      box-shadow: none;
    }
    50% {
      border-color: var(--sl-color-orange, #d18616);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--sl-color-orange, #d18616) 55%, transparent);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .card--pending {
      animation: none;
    }
  }

  .card__line {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    min-width: 0;
  }
  .card__line--labels {
    flex-wrap: wrap;
  }

  .card__id {
    font-family: var(--sl-font-mono);
    font-size: 0.72rem;
    color: var(--sl-color-gray-3);
    flex: none;
  }
  .card__title {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--sl-color-white);
    text-decoration: none;
  }
  .card__title {
    cursor: pointer;
  }
  .card__title:hover {
    text-decoration: underline;
  }
  .card__priority {
    flex: none;
    width: 0.75rem;
    height: 0.75rem;
    color: var(--pri);
    cursor: help;
  }
  .card__warn {
    flex: none;
    cursor: help;
    color: var(--sl-color-orange, #d18616);
    font-size: 0.75rem;
    line-height: 1;
  }

  .card__type {
    flex: none;
    padding: 0.05rem 0.4rem;
    border-radius: 0.25rem;
    font-size: 0.68rem;
    font-weight: 700;
    letter-spacing: 0.02em;
    color: #fff;
    background: #1f6feb;
  }
  .card__type--bug {
    background: #d73a4a;
  }
  .card__label {
    padding: 0.05rem 0.4rem;
    border-radius: 0.25rem;
    font-size: 0.68rem;
    color: var(--c);
    background: color-mix(in srgb, var(--c) 14%, transparent);
    white-space: nowrap;
  }

  .card__line--meta {
    gap: 0.7rem;
    font-size: 0.72rem;
  }
  .card__pr,
  .card__run {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    text-decoration: none;
    font-variant-numeric: tabular-nums;
    cursor: pointer;
  }
  .card__pr {
    color: var(--pr);
  }
  .card__run {
    color: var(--sl-color-gray-2);
    max-width: 6.5rem;
  }
  .card__pr:hover,
  .card__run:hover {
    text-decoration: underline;
  }
  .card__run-icon {
    color: var(--rc);
    flex: none;
  }
  .card__run-id {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .card__pending {
    color: var(--sl-color-orange-high, #e2a336);
    font-weight: 600;
  }
</style>
