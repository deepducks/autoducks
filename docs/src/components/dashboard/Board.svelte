<script lang="ts">
  import { onMount } from 'svelte';
  import Navbar from './Navbar.svelte';
  import Panel from './Panel.svelte';
  import SetupModal from './SetupModal.svelte';
  import ConfirmModal from './ConfirmModal.svelte';
  import { loadBoard, assemblePanels } from '../../lib/dashboard/board';
  import { classify, PANEL_ORDER, PANEL_TITLES } from '../../lib/dashboard/classify';
  import { canDrop, postComment } from '../../lib/dashboard/commands';
  import { correlateTriggeredRun, type RecentRun } from '../../lib/dashboard/runs';
  import { fetchViewerLogin } from '../../lib/dashboard/github';
  import type { PanelId, WorkflowRun } from '../../lib/dashboard/types';

  interface MoveTarget {
    id: PanelId;
    title: string;
  }
  interface TriggeredInfo {
    postedAt: number;
    runId?: number;
    sawCompleted?: boolean;
  }
  import {
    getRepo,
    setRepo,
    getRepos,
    addRepo,
    removeRepo,
    getToken,
    getInterval,
    setInterval as saveInterval,
    getAutoRefresh,
    setAutoRefresh as saveAutoRefresh,
    MIN_INTERVAL_MS,
  } from '../../lib/dashboard/storage';
  import type { BoardIssue } from '../../lib/dashboard/types';

  const RATE_LIMIT_THRESHOLD = 5;

  let repo = $state(getRepo());
  let repos = $state<string[]>(getRepos());
  let issues = $state<BoardIssue[]>([]);
  let panels = $derived(assemblePanels(issues));

  let hasToken = $state(false);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let banner = $state<string | null>(null);
  let lastUpdated = $state<Date | null>(null);

  let autoRefresh = $state(true);
  let intervalMs = $state(getInterval());
  let intervalSeconds = $state(Math.round(getInterval() / 1000));

  let setupOpen = $state(false);

  // Drag → command write state
  let draggedIssue = $state<BoardIssue | null>(null);
  let isDragging = $state(false);
  let confirmOpen = $state(false);
  let confirmIssue = $state<BoardIssue | null>(null);
  let confirmTarget = $state<PanelId | null>(null);
  let posting = $state(false);
  let pending = $state<Map<number, string>>(new Map());
  let triggered = $state<Map<number, TriggeredInfo>>(new Map());
  let me = $state<string | null>(null);
  let toast = $state<string | null>(null);
  let toastTimer: ReturnType<typeof setTimeout> | null = null;

  const TRIGGER_EXPIRY_MS = 15 * 60 * 1000;

  async function ensureViewer() {
    if (me !== null || !getToken()) return;
    me = await fetchViewerLogin();
  }

  // Attach a just-triggered agent run to its issue. The comment fires several
  // workflows on the default branch (no feature/fix branch yet), so branch
  // matching can't see them — we correlate by poster + start time instead, and
  // keep showing the same run (by id) until it finishes or a branch run wins.
  function resolveTriggeredRuns(recent: RecentRun[]) {
    if (triggered.size === 0) return;
    const byNumber = new Map(issues.map((i) => [i.number, i]));
    const recentById = new Map(recent.map((r) => [r.id, r]));
    const used = new Set<number>();
    for (const iss of issues) if (iss.run) used.add(iss.run.id);

    const next = new Map(triggered);
    const now = Date.now();
    const entries = [...triggered.entries()].sort((a, b) => a[1].postedAt - b[1].postedAt);

    for (const [num, info] of entries) {
      const iss = byNumber.get(num);
      if (!iss || iss.run || now - info.postedAt > TRIGGER_EXPIRY_MS) {
        next.delete(num); // gone, branch-run took over, or expired
        continue;
      }
      let run: WorkflowRun | null = null;
      if (info.runId != null && recentById.has(info.runId)) {
        const r = recentById.get(info.runId)!;
        run = { id: r.id, url: r.url, status: r.status, conclusion: r.conclusion };
        used.add(r.id);
      } else if (info.runId == null) {
        run = correlateTriggeredRun(recent, info.postedAt, me, used);
        if (run) next.set(num, { ...info, runId: run.id });
      }
      if (!run) continue;
      iss.run = run;
      if (run.status === 'completed') {
        if (info.sawCompleted) next.delete(num); // showed the final state once
        else next.set(num, { ...(next.get(num) ?? info), sawCompleted: true });
      }
    }
    triggered = next;
    issues = [...issues];
  }

  function showToast(message: string) {
    toast = message;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast = null), 6000);
  }

  // Drop the pending badge once an issue has actually left its done lane.
  function reconcilePending() {
    if (pending.size === 0) return;
    const byNumber = new Map(issues.map((i) => [i.number, i]));
    const next = new Map<number, string>();
    for (const [num, cmd] of pending) {
      const iss = byNumber.get(num);
      if (!iss) continue;
      const c = classify(iss);
      if (c && c.lane === 'done') next.set(num, cmd);
    }
    pending = next;
  }

  function dropStateFor(id: PanelId): 'idle' | 'valid' | 'invalid' {
    if (!draggedIssue) return 'idle';
    const src = classify(draggedIssue);
    if (!src || src.panel === id) return 'idle';
    return canDrop(src.panel, id) ? 'valid' : 'invalid';
  }

  function onCardDragStart(issue: BoardIssue, event: DragEvent) {
    draggedIssue = issue;
    isDragging = true;
    if (event.dataTransfer) {
      event.dataTransfer.setData('text/plain', String(issue.number));
      event.dataTransfer.effectAllowed = 'move';
    }
  }

  function onCardDragEnd() {
    draggedIssue = null;
    isDragging = false;
  }

  function onPanelDragOver(id: PanelId, event: DragEvent) {
    if (!draggedIssue) return;
    const src = classify(draggedIssue);
    if (src && src.panel !== id && canDrop(src.panel, id)) {
      event.preventDefault(); // signal a droppable target
    }
  }

  function openConfirm(issue: BoardIssue, target: PanelId) {
    confirmIssue = issue;
    confirmTarget = target;
    confirmOpen = true;
  }

  function onPanelDrop(id: PanelId, event: DragEvent) {
    event.preventDefault();
    const dragged = draggedIssue;
    onCardDragEnd();
    if (!dragged) return;
    const src = classify(dragged);
    if (!src || src.panel === id || !canDrop(src.panel, id)) return;
    openConfirm(dragged, id);
  }

  // Keyboard/click alternative to drag: valid destinations for a done card.
  function targetsFor(source: PanelId): MoveTarget[] {
    return PANEL_ORDER.filter((id) => id !== source && canDrop(source, id)).map((id) => ({
      id,
      title: PANEL_TITLES[id],
    }));
  }

  async function confirmCommand(command: string) {
    if (!confirmIssue) return;
    posting = true;
    try {
      await postComment(repo, confirmIssue.number, command);
      pending = new Map(pending).set(confirmIssue.number, command);
      triggered = new Map(triggered).set(confirmIssue.number, { postedAt: Date.now() });
      showToast(`Posted ${command} to #${confirmIssue.number}`);
      confirmOpen = false;
      confirmIssue = null;
      confirmTarget = null;
    } catch (e) {
      showToast(`Failed to post: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      posting = false;
    }
  }

  function cancelConfirm() {
    confirmOpen = false;
    confirmIssue = null;
    confirmTarget = null;
  }

  async function refresh() {
    if (!getToken()) {
      hasToken = false;
      return;
    }
    hasToken = true;
    loading = true;
    error = null;
    try {
      await ensureViewer();
      const res = await loadBoard(repo);
      issues = res.issues;
      reconcilePending();
      resolveTriggeredRuns(res.recentRuns);
      lastUpdated = new Date();
      if (
        res.rateLimit.remaining !== null &&
        res.rateLimit.remaining <= RATE_LIMIT_THRESHOLD
      ) {
        autoRefresh = false;
        saveAutoRefresh(false);
        banner = 'Auto-refresh paused — GitHub API rate limit nearly reached.';
      } else {
        banner = null;
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  function switchRepo(value: string) {
    if (value === repo) return;
    repo = value;
    setRepo(value);
    issues = [];
    pending = new Map();
    triggered = new Map();
    refresh();
  }

  function addRepoHandler(value: string) {
    repos = addRepo(value);
    switchRepo(value);
  }

  function deleteRepoHandler(value: string) {
    repos = removeRepo(value);
    setupOpen = false;
    // removeRepo may have switched the current selection away from `value`.
    switchRepo(getRepo());
  }

  function toggleAutoRefresh() {
    autoRefresh = !autoRefresh;
    saveAutoRefresh(autoRefresh);
  }

  function commitInterval(seconds: number) {
    const ms = Math.max(MIN_INTERVAL_MS, Math.round(seconds * 1000));
    intervalSeconds = Math.round(ms / 1000);
    intervalMs = ms;
    saveInterval(ms);
  }

  // Auto-refresh timer — restarts whenever its inputs change. Paused during a
  // drag or while the confirm modal is open so live data never yanks a card.
  $effect(() => {
    if (!autoRefresh || !hasToken || isDragging || confirmOpen) return;
    const id = window.setInterval(() => {
      if (!document.hidden && !loading) refresh();
    }, intervalMs);
    return () => window.clearInterval(id);
  });

  onMount(() => {
    autoRefresh = getAutoRefresh();
    hasToken = Boolean(getToken());
    if (hasToken) refresh();
  });
</script>

<div class="board-app">
  <Navbar
    {repos}
    {repo}
    {hasToken}
    {loading}
    {lastUpdated}
    {autoRefresh}
    {intervalSeconds}
    onselectrepo={switchRepo}
    onaddrepo={addRepoHandler}
    onedit={() => (setupOpen = true)}
    ontoggleautorefresh={toggleAutoRefresh}
    oncommitinterval={commitInterval}
  />

  <div class="board-body">
    {#if banner}
      <p class="board-banner" role="status">{banner}</p>
    {/if}

    {#if !hasToken}
      <div class="board-empty">
        <h2>Add a token to begin</h2>
        <p>
          This dashboard reads issues over the GitHub GraphQL API and posts phase commands, both of
          which need a personal access token.
        </p>
        <button class="board-empty__cta" type="button" onclick={() => (setupOpen = true)}>
          Set up token
        </button>
      </div>
    {:else if error}
      <div class="board-error">
        <p>{error}</p>
        <button type="button" onclick={refresh}>Retry</button>
      </div>
    {:else}
      <div class="board-columns">
        {#each panels as panel (panel.id)}
          <Panel
            {panel}
            {pending}
            dropState={dropStateFor(panel.id)}
            moveTargets={targetsFor(panel.id)}
            onmove={openConfirm}
            ondragstartcard={onCardDragStart}
            ondragendcard={onCardDragEnd}
            ondragoverpanel={(e) => onPanelDragOver(panel.id, e)}
            ondragleavepanel={() => {}}
            ondroppanel={(e) => onPanelDrop(panel.id, e)}
          />
        {/each}
      </div>
    {/if}
  </div>

  {#if toast}
    <div class="board-toast" role="status">{toast}</div>
  {/if}
</div>

<SetupModal
  open={setupOpen}
  {repo}
  onclose={() => (setupOpen = false)}
  ondeleterepo={deleteRepoHandler}
  onsaved={() => {
    setupOpen = false;
    hasToken = Boolean(getToken());
    if (hasToken) refresh();
  }}
/>

<ConfirmModal
  open={confirmOpen}
  issue={confirmIssue}
  target={confirmTarget}
  busy={posting}
  onconfirm={confirmCommand}
  oncancel={cancelConfirm}
/>

<style>
  .board-app {
    display: flex;
    flex-direction: column;
    min-height: 100vh;
  }

  .board-body {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1rem 1.25rem;
    flex: 1 1 auto;
    min-height: 0;
  }

  .board-banner {
    margin: 0;
    padding: 0.6rem 0.9rem;
    border-radius: 0.4rem;
    background: var(--sl-color-orange-low, #3a2d13);
    color: var(--sl-color-orange-high, #e2a336);
    font-size: 0.85rem;
  }

  .board-columns {
    display: flex;
    gap: 0.85rem;
    overflow-x: auto;
    padding-bottom: 0.75rem;
    align-items: stretch;
    min-height: 60vh;
  }

  .board-empty,
  .board-error {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.6rem;
    padding: 2rem;
    border: 1px dashed var(--sl-color-gray-5);
    border-radius: 0.6rem;
    color: var(--sl-color-gray-2);
    max-width: 34rem;
  }
  .board-empty h2 {
    margin: 0;
    font-size: 1.15rem;
    color: var(--sl-color-white);
  }
  .board-empty p {
    margin: 0;
    font-size: 0.9rem;
  }
  .board-empty__cta,
  .board-error button {
    padding: 0.5rem 1.1rem;
    border: none;
    border-radius: 0.4rem;
    background: var(--sl-color-accent, #3b82f6);
    color: var(--sl-color-text-invert, #fff);
    font-weight: 600;
    font-size: 0.88rem;
    cursor: pointer;
  }

  .board-toast {
    position: fixed;
    bottom: 1.25rem;
    left: 50%;
    transform: translateX(-50%);
    padding: 0.65rem 1.1rem;
    border-radius: 0.5rem;
    background: var(--sl-color-gray-5);
    color: var(--sl-color-white);
    border: 1px solid var(--sl-color-gray-4);
    font-size: 0.85rem;
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
    z-index: 1100;
    max-width: 90vw;
  }
</style>
