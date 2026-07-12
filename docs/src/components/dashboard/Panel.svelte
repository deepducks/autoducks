<script lang="ts">
  import Lane from './Lane.svelte';
  import { PANEL_COLORS } from '../../lib/dashboard/classify';
  import type { BoardIssue, PanelData, PanelId } from '../../lib/dashboard/types';

  interface MoveTarget {
    id: PanelId;
    title: string;
  }
  interface Props {
    panel: PanelData;
    pending?: Map<number, string>;
    dropState?: 'idle' | 'valid' | 'invalid';
    moveTargets?: MoveTarget[];
    onmove?: (issue: BoardIssue, target: PanelId) => void;
    ondragstartcard?: (issue: BoardIssue, event: DragEvent) => void;
    ondragendcard?: () => void;
    ondragoverpanel?: (event: DragEvent) => void;
    ondragleavepanel?: () => void;
    ondroppanel?: (event: DragEvent) => void;
  }
  let {
    panel,
    pending = new Map(),
    dropState = 'idle',
    moveTargets = [],
    onmove,
    ondragstartcard,
    ondragendcard,
    ondragoverpanel,
    ondragleavepanel,
    ondroppanel,
  }: Props = $props();

  let color = $derived(PANEL_COLORS[panel.id]);
</script>

<section class="panel" class:panel--drop-valid={dropState === 'valid'} class:panel--drop-invalid={dropState === 'invalid'}>
  <header class="panel__header" style={`--accent:${color}`}>
    <span class="panel__title">{panel.title}</span>
    <span class="panel__badge" title="in progress / done">
      {panel.progress.length}{panel.changes.length > 0 ? `/${panel.changes.length}` : ''}/{panel.done.length}
    </span>
  </header>

  <div
    class="panel__body"
    ondragover={ondragoverpanel}
    ondragleave={ondragleavepanel}
    ondrop={ondroppanel}
    role="group"
  >
    <Lane
      panel={panel.id}
      lane="progress"
      issues={panel.progress}
      {pending}
      {ondragstartcard}
      {ondragendcard}
    />
    {#if panel.id === 'review'}
      <Lane
        panel={panel.id}
        lane="changes"
        issues={panel.changes}
        {pending}
        {ondragstartcard}
        {ondragendcard}
      />
    {/if}
    <Lane
      panel={panel.id}
      lane="done"
      issues={panel.done}
      {pending}
      {moveTargets}
      {onmove}
      {ondragstartcard}
      {ondragendcard}
    />
  </div>
</section>

<style>
  .panel {
    display: flex;
    flex-direction: column;
    flex: 0 0 clamp(240px, 22vw, 300px);
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.6rem;
    background: var(--sl-color-gray-7);
    overflow: hidden;
    transition: box-shadow 0.12s ease;
  }
  .panel--drop-valid {
    box-shadow: 0 0 0 2px var(--sl-color-accent, #3b82f6);
  }
  .panel--drop-invalid {
    box-shadow: 0 0 0 2px var(--sl-color-red, #f85149);
  }

  .panel__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    padding: 0.6rem 0.75rem;
    border-bottom: 1px solid var(--sl-color-gray-5);
    border-top: 3px solid var(--accent);
  }
  .panel__title {
    font-size: 0.95rem;
    font-weight: 700;
    color: var(--sl-color-white);
  }
  .panel__badge {
    padding: 0.1rem 0.5rem;
    border-radius: 1rem;
    font-size: 0.75rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--sl-color-gray-1);
    background: var(--sl-color-gray-5);
  }

  .panel__body {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding: 0.5rem;
    overflow-y: auto;
    flex: 1 1 auto;
  }
</style>
