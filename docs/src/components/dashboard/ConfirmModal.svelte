<script lang="ts">
  import { buildCommand } from '../../lib/dashboard/commands';
  import { PANEL_TITLES } from '../../lib/dashboard/classify';
  import type { BoardIssue, PanelId } from '../../lib/dashboard/types';

  interface Props {
    open: boolean;
    issue: BoardIssue | null;
    target: PanelId | null;
    busy?: boolean;
    onconfirm: (command: string) => void;
    oncancel: () => void;
  }
  let { open, issue, target, busy = false, onconfirm, oncancel }: Props = $props();

  let showAdvanced = $state(false);
  let model = $state('');
  let effort = $state('');
  let turns = $state('');
  let auto = $state('');

  $effect(() => {
    if (open) {
      showAdvanced = false;
      model = '';
      effort = '';
      turns = '';
      auto = '';
    }
  });

  let command = $derived(
    target
      ? buildCommand(target, {
          model: model.trim() || undefined,
          effort: effort.trim() || undefined,
          turns: turns.trim() ? Number(turns) : undefined,
          auto: auto.trim() || undefined,
        })
      : '',
  );

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') oncancel();
  }
</script>

<svelte:window onkeydown={open ? onKeydown : undefined} />

{#if open && issue && target}
  <div class="backdrop" onclick={oncancel} role="presentation">
    <div
      class="modal"
      role="dialog"
      aria-modal="true"
      aria-label="Confirm command"
      onclick={(e) => e.stopPropagation()}
    >
      <h2 class="modal__title">Move to {PANEL_TITLES[target]}?</h2>
      <p class="modal__lead">
        This posts a comment on <strong>#{issue.number}</strong> — {issue.title} — which triggers a
        real agent run.
      </p>

      <pre class="modal__cmd">{command}</pre>

      <button class="modal__adv-toggle" type="button" onclick={() => (showAdvanced = !showAdvanced)}>
        {showAdvanced ? '▾' : '▸'} Advanced options
      </button>

      {#if showAdvanced}
        <div class="modal__adv">
          <label>model <input bind:value={model} placeholder="claude-sonnet-5" /></label>
          <label>effort <input bind:value={effort} placeholder="high" /></label>
          <label>turns <input bind:value={turns} type="number" min="1" placeholder="—" /></label>
          <label>#auto <input bind:value={auto} placeholder="engineer+execute" /></label>
        </div>
      {/if}

      <div class="modal__actions">
        <button class="btn btn--ghost" type="button" onclick={oncancel}>Cancel</button>
        <button class="btn btn--primary" type="button" onclick={() => onconfirm(command)} disabled={busy}>
          {busy ? 'Posting…' : 'Post command'}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    z-index: 1000;
  }
  .modal {
    width: min(28rem, 100%);
    background: var(--sl-color-gray-7);
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.6rem;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .modal__title {
    margin: 0;
    font-size: 1.1rem;
  }
  .modal__lead {
    margin: 0;
    font-size: 0.85rem;
    color: var(--sl-color-gray-2);
  }
  .modal__cmd {
    margin: 0;
    padding: 0.6rem 0.8rem;
    background: var(--sl-color-gray-6);
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.4rem;
    font-family: var(--sl-font-mono);
    font-size: 0.9rem;
    color: var(--sl-color-white);
    white-space: pre-wrap;
    word-break: break-word;
  }
  .modal__adv-toggle {
    align-self: flex-start;
    background: none;
    border: none;
    padding: 0;
    color: var(--sl-color-gray-3);
    font-size: 0.8rem;
    cursor: pointer;
  }
  .modal__adv {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.5rem;
  }
  .modal__adv label {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    font-size: 0.72rem;
    color: var(--sl-color-gray-3);
  }
  .modal__adv input {
    padding: 0.35rem 0.5rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.3rem;
    background: var(--sl-color-gray-6);
    color: var(--sl-color-gray-1);
    font-size: 0.8rem;
  }
  .modal__actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    margin-top: 0.4rem;
  }
  .btn {
    padding: 0.45rem 0.95rem;
    border-radius: 0.4rem;
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    border: 1px solid var(--sl-color-gray-4);
  }
  .btn--ghost {
    background: transparent;
    color: var(--sl-color-gray-1);
  }
  .btn--primary {
    background: var(--sl-color-accent, #3b82f6);
    color: var(--sl-color-text-invert, #fff);
    border-color: transparent;
  }
  .btn--primary:disabled {
    opacity: 0.6;
    cursor: default;
  }
</style>
