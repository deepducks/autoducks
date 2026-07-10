<script lang="ts">
  import { REPO_PATTERN, MIN_INTERVAL_MS } from '../../lib/dashboard/storage';

  interface Props {
    repos: string[];
    repo: string;
    hasToken: boolean;
    loading: boolean;
    lastUpdated: Date | null;
    autoRefresh: boolean;
    intervalSeconds: number;
    onselectrepo: (repo: string) => void;
    onaddrepo: (repo: string) => void;
    onedit: () => void;
    ontoggleautorefresh: () => void;
    oncommitinterval: (seconds: number) => void;
  }
  let {
    repos,
    repo,
    hasToken,
    loading,
    lastUpdated,
    autoRefresh,
    intervalSeconds,
    onselectrepo,
    onaddrepo,
    onedit,
    ontoggleautorefresh,
    oncommitinterval,
  }: Props = $props();

  let repoOpen = $state(false);
  let adding = $state(false);
  let newRepo = $state('');
  let addError = $state('');
  let popoverOpen = $state(false);
  let seconds = $state(intervalSeconds);

  $effect(() => {
    seconds = intervalSeconds;
  });

  function selectRepo(r: string) {
    repoOpen = false;
    if (r !== repo) onselectrepo(r);
  }

  function submitAdd(event: Event) {
    event.preventDefault();
    const value = newRepo.trim();
    if (!REPO_PATTERN.test(value)) {
      addError = 'Use "org/repo".';
      return;
    }
    onaddrepo(value);
    newRepo = '';
    addError = '';
    adding = false;
    repoOpen = false;
  }

  function commitSeconds() {
    oncommitinterval(seconds);
  }
</script>

<nav class="nav">
  <div class="nav__left">
    <span class="nav__logo" aria-hidden="true">
      <svg viewBox="0 0 32 32" width="26" height="26" fill="none">
        <ellipse cx="16" cy="20" rx="10" ry="7" fill="var(--sl-color-accent)" />
        <circle cx="22" cy="12" r="5" fill="var(--sl-color-accent)" />
        <path d="M27 12 L31 11 L31 13 Z" fill="#f5a623" />
        <circle cx="24" cy="11" r="1" fill="white" />
        <path d="M10 20 Q13 17 16 20" stroke="var(--sl-color-accent-high)" stroke-width="1.5" fill="none" />
      </svg>
    </span>
    <a class="nav__title" href="/">Board</a>

    <span class="nav__sep" aria-hidden="true"></span>

    <div class="nav__repo">
      <button
        type="button"
        class="nav__repo-btn"
        aria-haspopup="menu"
        aria-expanded={repoOpen}
        onclick={() => (repoOpen = !repoOpen)}
      >
        <span class="nav__repo-name">{repo}</span>
        <span class="nav__caret">▾</span>
      </button>
      {#if repoOpen}
        <button type="button" class="nav__backdrop" aria-label="Close" onclick={() => (repoOpen = false)}></button>
        <div class="nav__menu" role="menu">
          {#each repos as r (r)}
            <button type="button" role="menuitem" class:active={r === repo} onclick={() => selectRepo(r)}>
              {r}
            </button>
          {/each}
          <div class="nav__menu-sep"></div>
          {#if adding}
            <form class="nav__add" onsubmit={submitAdd}>
              <input
                type="text"
                bind:value={newRepo}
                placeholder="org/repo"
                autocomplete="off"
                spellcheck="false"
              />
              <button type="submit">Add</button>
              {#if addError}<span class="nav__add-err">{addError}</span>{/if}
            </form>
          {:else}
            <button type="button" class="nav__add-btn" onclick={() => (adding = true)}>+ Add repository</button>
          {/if}
        </div>
      {/if}
    </div>

    <button class="nav__edit" type="button" onclick={onedit} title="Settings & token" aria-label="Settings and token">
      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <path
          fill="currentColor"
          d="M11.013 1.427a1.75 1.75 0 0 1 2.474 0l1.086 1.086a1.75 1.75 0 0 1 0 2.474l-8.61 8.61c-.21.21-.47.364-.756.445l-3.251.93a.75.75 0 0 1-.927-.928l.929-3.25c.081-.286.235-.547.445-.758l8.61-8.61Zm1.414 1.06a.25.25 0 0 0-.354 0L10.811 3.75l1.439 1.44 1.263-1.263a.25.25 0 0 0 0-.354l-1.086-1.086ZM3.279 10.72l7.47-7.47 1.44 1.44-7.47 7.47-1.815.519.375-1.959Z"
        />
      </svg>
      {#if !hasToken}<span class="nav__edit-alert" title="No token set">!</span>{/if}
    </button>
  </div>

  <div class="nav__right">
    {#if loading}
      <span class="nav__updated">
        <span class="nav__spinner" aria-label="Refreshing"></span>
      </span>
    {:else if lastUpdated}
      <span class="nav__updated">Updated {lastUpdated.toLocaleTimeString()}</span>
    {/if}

    <div class="nav__ar">
      <button
        type="button"
        class="nav__switch"
        role="switch"
        aria-checked={autoRefresh}
        aria-label="Auto refresh"
        class:on={autoRefresh}
        onclick={ontoggleautorefresh}
      >
        <span class="nav__switch-knob"></span>
      </button>
      <button type="button" class="nav__ar-label" onclick={() => (popoverOpen = !popoverOpen)}>
        auto refresh <span class="nav__caret">▾</span>
      </button>
      {#if popoverOpen}
        <button type="button" class="nav__backdrop" aria-label="Close" onclick={() => (popoverOpen = false)}></button>
        <div class="nav__popover">
          <label>
            every
            <input
              type="number"
              min={MIN_INTERVAL_MS / 1000}
              step="1"
              bind:value={seconds}
              onchange={commitSeconds}
            />
            s
          </label>
        </div>
      {/if}
    </div>
  </div>
</nav>

<style>
  .nav {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.6rem 1.25rem;
    border-bottom: 1px solid var(--sl-color-gray-5);
    background: var(--sl-color-gray-6);
  }
  .nav__left,
  .nav__right {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }
  .nav__logo {
    display: inline-flex;
  }
  .nav__title {
    font-weight: 700;
    font-size: 1.05rem;
    color: var(--sl-color-white);
    text-decoration: none;
  }
  .nav__sep {
    width: 1px;
    height: 1.4rem;
    background: var(--sl-color-gray-4);
    margin: 0 0.15rem;
  }
  .nav__caret {
    font-size: 0.6rem;
    opacity: 0.7;
  }

  /* Repo dropdown */
  .nav__repo {
    position: relative;
  }
  .nav__repo-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.35rem 0.65rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.4rem;
    background: var(--sl-color-gray-7);
    color: var(--sl-color-gray-1);
    font-family: var(--sl-font-mono);
    font-size: 0.85rem;
    cursor: pointer;
  }
  .nav__backdrop {
    position: fixed;
    inset: 0;
    background: transparent;
    border: none;
    padding: 0;
    z-index: 90;
    cursor: default;
  }
  .nav__menu {
    position: absolute;
    top: 2.1rem;
    left: 0;
    z-index: 100;
    display: flex;
    flex-direction: column;
    min-width: 15rem;
    padding: 0.3rem;
    background: var(--sl-color-gray-6);
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.5rem;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }
  .nav__menu button[role='menuitem'] {
    text-align: left;
    padding: 0.4rem 0.5rem;
    border: none;
    background: transparent;
    color: var(--sl-color-gray-1);
    font-family: var(--sl-font-mono);
    font-size: 0.82rem;
    border-radius: 0.35rem;
    cursor: pointer;
  }
  .nav__menu button[role='menuitem']:hover {
    background: var(--sl-color-gray-5);
  }
  .nav__menu button[role='menuitem'].active {
    color: var(--sl-color-accent-high);
    font-weight: 600;
  }
  .nav__menu-sep {
    height: 1px;
    background: var(--sl-color-gray-5);
    margin: 0.3rem 0;
  }
  .nav__add-btn {
    text-align: left;
    padding: 0.4rem 0.5rem;
    border: none;
    background: transparent;
    color: var(--sl-color-accent-high);
    font-size: 0.82rem;
    border-radius: 0.35rem;
    cursor: pointer;
  }
  .nav__add-btn:hover {
    background: var(--sl-color-gray-5);
  }
  .nav__add {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
    padding: 0.25rem;
  }
  .nav__add input {
    flex: 1 1 auto;
    min-width: 0;
    padding: 0.35rem 0.5rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.35rem;
    background: var(--sl-color-gray-7);
    color: var(--sl-color-gray-1);
    font-family: var(--sl-font-mono);
    font-size: 0.8rem;
  }
  .nav__add button {
    padding: 0.35rem 0.7rem;
    border: none;
    border-radius: 0.35rem;
    background: var(--sl-color-accent, #3b82f6);
    color: var(--sl-color-text-invert, #fff);
    font-size: 0.8rem;
    cursor: pointer;
  }
  .nav__add-err {
    flex: 1 1 100%;
    color: var(--sl-color-red-high, #f85149);
    font-size: 0.72rem;
  }

  .nav__edit {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 2rem;
    height: 2rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.4rem;
    background: var(--sl-color-gray-7);
    color: var(--sl-color-gray-2);
    cursor: pointer;
  }
  .nav__edit:hover {
    color: var(--sl-color-white);
    background: var(--sl-color-gray-5);
  }
  .nav__edit-alert {
    position: absolute;
    top: -0.35rem;
    right: -0.35rem;
    width: 0.95rem;
    height: 0.95rem;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: var(--sl-color-orange, #d18616);
    color: #000;
    font-size: 0.65rem;
    font-weight: 700;
  }

  /* Updated + loader */
  .nav__updated {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.78rem;
    color: var(--sl-color-gray-3);
    white-space: nowrap;
    min-width: 1.5rem;
  }
  .nav__spinner {
    width: 0.9rem;
    height: 0.9rem;
    border: 2px solid var(--sl-color-gray-4);
    border-top-color: var(--sl-color-accent-high, #79b8ff);
    border-radius: 50%;
    animation: nav-spin 0.7s linear infinite;
    cursor: progress;
  }
  @keyframes nav-spin {
    to {
      transform: rotate(360deg);
    }
  }

  /* Auto-refresh switch + popover */
  .nav__ar {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
  }
  .nav__switch {
    width: 2.1rem;
    height: 1.15rem;
    border-radius: 1rem;
    border: none;
    background: var(--sl-color-gray-4);
    position: relative;
    cursor: pointer;
    transition: background 0.15s ease;
    padding: 0;
  }
  .nav__switch.on {
    background: var(--sl-color-accent, #3b82f6);
  }
  .nav__switch-knob {
    position: absolute;
    top: 0.15rem;
    left: 0.15rem;
    width: 0.85rem;
    height: 0.85rem;
    border-radius: 50%;
    background: #fff;
    transition: transform 0.15s ease;
  }
  .nav__switch.on .nav__switch-knob {
    transform: translateX(0.95rem);
  }
  .nav__ar-label {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    border: none;
    background: transparent;
    color: var(--sl-color-gray-2);
    font-size: 0.82rem;
    cursor: pointer;
    padding: 0;
  }
  .nav__popover {
    position: absolute;
    top: 2rem;
    right: 0;
    z-index: 100;
    padding: 0.7rem 0.85rem;
    background: var(--sl-color-gray-6);
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.5rem;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }
  .nav__popover label {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.82rem;
    color: var(--sl-color-gray-2);
    white-space: nowrap;
  }
  .nav__popover input {
    width: 3.5rem;
    padding: 0.3rem 0.45rem;
    border: 1px solid var(--sl-color-gray-4);
    border-radius: 0.35rem;
    background: var(--sl-color-gray-7);
    color: var(--sl-color-gray-1);
    font-size: 0.82rem;
  }

  @media (max-width: 640px) {
    .nav__repo-name {
      max-width: 8rem;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      display: inline-block;
    }
    .nav__ar-label {
      display: none;
    }
  }
</style>
