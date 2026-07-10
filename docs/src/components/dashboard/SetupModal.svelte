<script lang="ts">
  import { validateToken } from '../../lib/dashboard/github';
  import {
    getToken,
    setToken,
    getPriorityField,
    setPriorityField,
    DEFAULT_PRIORITY_FIELD,
  } from '../../lib/dashboard/storage';

  interface Props {
    open: boolean;
    repo: string;
    onclose: () => void;
    onsaved: () => void;
    ondeleterepo: (repo: string) => void;
  }
  let { open, repo, onclose, onsaved, ondeleterepo }: Props = $props();

  let token = $state('');
  let priorityField = $state(DEFAULT_PRIORITY_FIELD);
  let status = $state<'idle' | 'checking' | 'ok' | 'error'>('idle');
  let message = $state('');
  let confirmDelete = $state(false);

  // Re-seed fields whenever the modal is opened.
  $effect(() => {
    if (open) {
      token = getToken() ?? '';
      priorityField = getPriorityField();
      status = 'idle';
      message = '';
      confirmDelete = false;
    }
  });

  async function save() {
    setToken(token.trim() || null);
    setPriorityField(priorityField.trim() || DEFAULT_PRIORITY_FIELD);
    if (!token.trim()) {
      status = 'idle';
      onsaved();
      onclose();
      return;
    }
    status = 'checking';
    message = '';
    try {
      const login = await validateToken();
      status = 'ok';
      message = `Authenticated as ${login}.`;
      onsaved();
    } catch (e) {
      status = 'error';
      message = e instanceof Error ? e.message : String(e);
    }
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') onclose();
  }
</script>

<svelte:window onkeydown={open ? onKeydown : undefined} />

{#if open}
  <div class="backdrop" onclick={onclose} role="presentation">
    <div
      class="modal"
      role="dialog"
      aria-modal="true"
      aria-label="Dashboard setup"
      onclick={(e) => e.stopPropagation()}
    >
      <h2 class="modal__title">Dashboard setup</h2>
      <p class="modal__lead">
        The board reads issues via the GitHub GraphQL API and posts commands on your behalf, so a
        token is required. It is stored in this browser's <code>localStorage</code>.
      </p>

      <label class="modal__label" for="setup-token">Personal access token</label>
      <input
        id="setup-token"
        class="modal__input"
        type="password"
        bind:value={token}
        placeholder="github_pat_… or ghp_…"
        autocomplete="off"
        spellcheck="false"
      />
      <p class="modal__hint">
        Recommended: a <strong>fine-grained PAT</strong> scoped to your repo with
        <em>Issues: Read&nbsp;and&nbsp;write</em>, <em>Contents: Read</em>,
        <em>Pull requests: Read</em>, <em>Actions: Read</em>, <em>Metadata: Read</em>. A localStorage
        token is readable by scripts on this page — keep the scope minimal and the expiry short.
      </p>

      <label class="modal__label" for="setup-priority">Priority field name (Projects&nbsp;v2)</label>
      <input
        id="setup-priority"
        class="modal__input"
        type="text"
        bind:value={priorityField}
        placeholder="Priority"
        autocomplete="off"
      />
      <p class="modal__hint">
        Only used when the Product agent stores priority in a Project field instead of a
        <code>Priority:*</code> label. Default is <code>Priority</code>.
      </p>

      {#if message}
        <p class="modal__status" class:modal__status--ok={status === 'ok'} class:modal__status--err={status === 'error'}>
          {message}
        </p>
      {/if}

      <div class="modal__danger">
        {#if confirmDelete}
          <span class="modal__danger-q">Remove <code>{repo}</code> from the board?</span>
          <button class="btn btn--danger" type="button" onclick={() => ondeleterepo(repo)}>Confirm</button>
          <button class="btn btn--ghost btn--sm" type="button" onclick={() => (confirmDelete = false)}>No</button>
        {:else}
          <button class="btn btn--danger-ghost" type="button" onclick={() => (confirmDelete = true)}>
            Remove repository
          </button>
        {/if}
      </div>

      <div class="modal__actions">
        <button class="btn btn--ghost" type="button" onclick={onclose}>Close</button>
        <button class="btn btn--primary" type="button" onclick={save} disabled={status === 'checking'}>
          {status === 'checking' ? 'Validating…' : 'Save'}
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
    width: min(30rem, 100%);
    max-height: 90vh;
    overflow-y: auto;
    background: var(--sl-color-gray-7);
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.6rem;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .modal__title {
    margin: 0;
    font-size: 1.1rem;
  }
  .modal__lead {
    margin: 0 0 0.4rem;
    font-size: 0.85rem;
    color: var(--sl-color-gray-2);
  }
  .modal__label {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--sl-color-gray-2);
    margin-top: 0.35rem;
  }
  .modal__input {
    padding: 0.45rem 0.7rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.35rem;
    background: var(--sl-color-gray-6);
    color: var(--sl-color-gray-1);
    font-family: var(--sl-font-mono);
    font-size: 0.85rem;
  }
  .modal__hint {
    margin: 0;
    font-size: 0.73rem;
    line-height: 1.4;
    color: var(--sl-color-gray-3);
  }
  .modal__status {
    margin: 0.3rem 0 0;
    font-size: 0.8rem;
  }
  .modal__status--ok {
    color: var(--sl-color-green-high, #3fb950);
  }
  .modal__status--err {
    color: var(--sl-color-red-high, #f85149);
  }
  .modal__actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    margin-top: 0.6rem;
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
  .btn--sm {
    padding: 0.35rem 0.7rem;
    font-size: 0.8rem;
  }
  .btn--danger {
    background: var(--sl-color-red, #cf222e);
    color: #fff;
    border-color: transparent;
    padding: 0.35rem 0.8rem;
    font-size: 0.8rem;
  }
  .btn--danger-ghost {
    background: transparent;
    color: var(--sl-color-red-high, #f85149);
    border-color: color-mix(in srgb, var(--sl-color-red, #f85149) 40%, transparent);
    font-size: 0.8rem;
    padding: 0.4rem 0.8rem;
  }

  .modal__danger {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem;
    margin-top: 0.6rem;
    padding-top: 0.7rem;
    border-top: 1px solid var(--sl-color-gray-5);
  }
  .modal__danger-q {
    font-size: 0.82rem;
    color: var(--sl-color-gray-2);
  }
</style>
