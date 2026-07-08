# Documentation Revision Plan — New Topology/Taxonomy

> **Status: EXECUTED** (same PR). All phases below were implemented: terminology sweep, IA restructure with redirects, page rewrites, the four new guides, the labels reference, and build/link validation (27 pages, zero broken internal links). The dashboard needed no changes — its columns come from GitHub's issues/views API, not hardcoded labels. Kept for reference and as the spec the pages were written against.

Full revision plan for the autoducks documentation site (`docs/`, Astro + Starlight) after the topology migration (PR #433: Architect / Engineer / Maestro / Developer, `/quack` command layer, decisions D1–D15). Written for autonomous execution by a coding agent, phase by phase, with explicit file lists, checklists, and exit criteria.

**Sources of truth** (read before writing any page):
- `.autoducks/design/AGENTS.md` — canonical architecture reference (already updated)
- `README.md` — current elevator pitch and command surface
- The implementation itself: `.autoducks/core/config/parse-directive.sh` (command grammar), `core/orchestration/dispatch-chain.sh` (chaining), `core/feedback/status-comment.sh` (feedback), `scripts/update-triggers.sh` (guard baking), agent `pre/post/run` scripts (behavior)

**Non-goals:** do not document the goal-verification loop (future work, draft step 7); do not re-architect the Starlight setup.

---

## Guiding principles (didactics / practicality)

1. **Task-first navigation.** Users arrive asking "how do I make it build X?", not "what is the Tactical agent?". Every section must open with the command to type and what happens next; concepts come after.
2. **One mental model, repeated.** The pipeline picture (Architect → Engineer → Maestro → Developer, with the DoR cascade arrows pointing backwards) appears identically on the landing page, agents index, and introduction — same diagram, same names, same colors.
3. **Scannable reference.** Every reference page leads with a table (commands, labels, config keys, branch patterns). Prose explains; tables answer.
4. **Copy-pasteable everything.** Every example is a complete comment/command line a user can paste (`/quack execute`, `/quack architect model:opus #auto:engineer+execute`), never a fragment.
5. **Failure paths are first-class.** What users actually consult docs for is "it went wrong" — the failure taxonomy, the status comment states, and `/quack fix` deserve their own page, not a footnote.

---

## Phase 1 — Terminology migration sweep (mechanical)

Global find/replace across `docs/src/content/docs/**/*.mdx` and `docs/public/dashboard/**`. Do this FIRST so later phases edit already-consistent text.

| Old | New |
|---|---|
| `/agents <verb>` | `/quack <verb>` |
| `design` agent / Design Agent | Architect (agent id `architect`) |
| `tactical` agent / Tactical Agent / `devise` | Engineer (agent id `engineer`; verbs `engineer`, `tactics`) |
| Wave Orchestrator / `waveOrchestrator` | Maestro (agent id `maestro`) |
| Execution agent / `execution` | Developer (agent id `developer`) |
| `drilldown`, `specify`, `plan`, `start` (verbs) | *(removed — delete or replace with current verbs)* |
| `reasoning` (directive/config/action input) | `effort` |
| `Spec:draft` / `Spec:plan` | `Design:draft` / `Design:done` |
| `Tactics:ready` and `Ready` | `Tactics:done` (single label) |
| `Work:progress` | `Work:orchestrating` (feature) / `Work:coding` (task) |
| `Tactics:single` | *(removed — structural detection)* |
| `priority:P0..P3` | *(removed)* |
| `autoducks-design.yml`, `autoducks-tactical.yml`, `autoducks-wave.yml`, `autoducks-execute.yml` | `autoducks-architect.yml`, `autoducks-engineer.yml`, `autoducks-maestro.yml`, `autoducks-developer.yml` |
| Orphan/standalone task execution | *(retired concept — replace with the DoR cascade story)* |

**Checklist:**
- [ ] Run the sweep with per-term review (not blind sed — several terms appear in prose with different casing).
- [ ] Update `docs/public/dashboard` (issue-board tool from #356): label names, workflow filenames, command strings it renders or queries.
- [ ] Check `docs/astro.config.mjs` sidebar labels/slugs for old names.

**Exit criteria:** `grep -rn '/agents \|Spec:\|Tactics:ready\|Work:progress\|Tactics:single\|priority:P\|devise\|drilldown\|wave-orchestrator\|waveOrchestrator' docs/src docs/public` returns only intentional mentions inside the migration guide (Phase 4).

---

## Phase 2 — Information architecture (nav + files)

New sidebar structure (rename/move files; keep Starlight redirects for old slugs):

```
Getting started
  introduction.mdx        (rewrite — Phase 3)
  installation.mdx        (light edit)
  first-run.mdx           (rewrite of first-feature.mdx — the /quack execute walkthrough)
Agents
  index.mdx               (rewrite — pipeline overview + DoR cascade)
  architect.mdx           (from design.mdx)
  engineer.mdx            (NEW — the tactical layer never had a page)
  maestro.mdx             (from wave-orchestrator.mdx)
  developer.mdx           (from execution.mdx)
  utilities.mdx           (fix / revert / close — update)
Guides                    (NEW section)
  pipeline-lifecycle.mdx  (NEW — end-to-end lifecycle of one issue)
  chaining-and-overrides.mdx (NEW — #auto:, model:/effort:/turns:)
  when-things-fail.mdx    (NEW — failure taxonomy, status states, fix/resume)
  migrating-from-agents.mdx (NEW — for pre-topology installs)
Reference
  slash-commands.mdx      (rewrite)
  configuration.mdx       (rewrite)
  labels.mdx              (NEW — split out of scattered mentions)
  branch-naming.mdx       (update: fix/ prefix, real task-branch pattern)
  security.mdx            (update: per_agent keys, execute policy sharing)
  runtimes.mdx            (light edit: workflow filenames, dispatch inputs)
About
  index.mdx               (design philosophy — update agent names, add D1–D15 rationale summary)
```

**Checklist:**
- [ ] `git mv` pages to the new names; add `redirects` in `astro.config.mjs` (old slugs → new) so inbound links keep working (`/agents/design/` → `/agents/architect/`, `/agents/wave-orchestrator/` → `/agents/maestro/`, `/agents/execution/` → `/agents/developer/`, `/getting-started/first-feature/` → `/getting-started/first-run/`).
- [ ] Update README's "Where to go next" table to the new slugs.

**Exit criteria:** `npm run build` (in `docs/`) succeeds; no dead internal links (`npx starlight-links-validator` or the build's link check).

---

## Phase 3 — Page-by-page rewrite specs

For each page: what it must contain, in order. Reuse text from `.autoducks/design/AGENTS.md` where possible — do not invent behavior; verify every claim against the scripts.

### `index.mdx` (landing)
- Hero: one sentence + the `/quack execute` promise ("one comment runs design → plan → build").
- The pipeline diagram (Mermaid, via existing `Mermaid.astro`): 4 agents forward, DoR-cascade arrows backward.
- Three entry cards: "Run your first issue", "Command reference", "When things fail".

### `getting-started/introduction.mdx`
- What autoducks is; the four layers table (from README); how routing works ("you always type `execute`; labels decide which agent answers").
- The DoR cascade explained with a single concrete narrative: raw issue → `/quack execute` → what the user sees happen (status comments, labels, dispatches) at each hop.

### `getting-started/first-run.mdx`
- End-to-end walkthrough with screenshots/blockquotes of the actual comments: status comment (Running → ✅), design published, plan + task issues, waves, final PR.
- A second, shorter path: stage-by-stage (`architect`, review, `engineer`, review, `execute`).

### `agents/index.mdx`
- The comparison table from AGENTS.md (purpose / triggers / DoR / auto-dispatch / labels / DoD).
- Routing rules for the shared `execute` verb, verbatim from the workflow guards.

### `agents/architect.mdx`
- Create-or-revise semantics (D1/D5) — emphasize: human-written specs are structured, not rewritten.
- Feature vs Bug classification (D10) and its consequence (branch prefix).
- Tactical-zone preservation on re-runs; `Design:draft`/`Design:done`; no Draft auto-trigger (D13).

### `agents/engineer.mdx` (NEW — biggest gap today)
- Plan format (waves YAML, task blocks, Progress checklist — post-D14, no priorities).
- Questions Mode; revision mode (`Tactics:done` re-run, preserve-by-number convention); single-task fast path (structural, D12); sub-issue linking degradation table.
- Explicitly: Engineer touches no git (D7).

### `agents/maestro.mdx`
- Owns branch + draft PR (D7); prefix by kind (D10); event-driven advancement (PR merge re-trigger); wave states; duplicate-dispatch guards; final PR assembly (Closes list + Work Log); reviewers from assignees.

### `agents/developer.mdx`
- Task branch naming; auto-merge policy + adaptive merge; explicit task close; max_turns work preservation → `/quack fix` resume; the DoR delegation for comment-triggered tasks; retirement of standalone mode with the "what to do instead" box (`/quack architect #auto:engineer+execute`).

### `agents/utilities.mdx`
- fix / revert / close, one section each: trigger, what it does, security defaults, "not the Bug flow" callout on fix.

### `reference/slash-commands.mdx`
- Full grammar at top (single code block), then one table: verb → agent → requirements → what happens.
- Overrides table (`model:`, `effort:`, `turns:` + positional aliases); `#auto:` semantics (order, dedupe, cap, loop protection); configurable prefix + `scripts/update-triggers.sh` requirement after changing it.

### `reference/configuration.mdx`
- Annotated full `autoducks.json` (current shape: `command`, `providers`, `defaults` with `effort`, `triggers` keys `architect/engineer/execute/fix/revert/close`, `security.per_agent` with the maestro/developer→execute note).
- Per-agent `defaults.json`; precedence chain (directive > agent defaults > global defaults > provider default).

### `reference/labels.mdx` (NEW)
- The stage-label table (from AGENTS.md) + auxiliary labels + retired labels with "cleaned up automatically" note.

### `reference/branch-naming.mdx`
- The real patterns table (feature/, fix/, `-issue-<n>-<epoch>`, `-fix-<epoch>`), replacing the outdated `…/task/…` pattern.

### `reference/security.mdx`
- Update per_agent keys; the maestro/developer→execute policy mapping; note that the gate precedes all feedback (denied users get no status comment).

**Exit criteria per page:** every command, label, filename, and behavior claim greps back to the implementation; every page has at least one copy-pasteable example; tables precede prose in reference pages.

---

## Phase 4 — New guides

### `guides/pipeline-lifecycle.mdx`
Single annotated timeline of one issue: each row = actor (human/agent), event, visible artifact (comment/label/branch/PR). This is the page that makes the whole system legible; link it from everywhere.

### `guides/chaining-and-overrides.mdx`
- `#auto:` recipes: full pipeline from scratch; plan-then-pause; re-plan and re-execute.
- How overrides propagate down chains (only explicit ones) and to wave workers.

### `guides/when-things-fail.mdx`
- Status comment states (Running/✅/⚠️/🔁) and what each means.
- The failure-category table (merge-conflict / no-changes / scope-missing / parse / max_turns / infra) with the exact remediation per category — lift from `notify-failure.sh`.
- max_turns resume flow; conflict resolution flow; Questions Mode flow.

### `guides/migrating-from-agents.mdx`
For installs on the previous topology:
- [ ] Re-run the installer (or copy the new tree) and `scripts/setup.sh`.
- [ ] Command changes table (`/agents devise` → `/quack engineer`, etc.).
- [ ] Config migration: `reasoning`→`effort`, `triggers` keys, `per_agent` keys, new `command` key.
- [ ] Label migration: old labels are removed on sight by agents; optionally delete them repo-wide (one `gh label delete` block).
- [ ] In-flight features: finish them on the old install or re-run `engineer` after migrating (revision mode reconciles).
- [ ] Custom trigger aliases: re-declare and re-run `update-triggers.sh`.

---

## Phase 5 — Didactic assets

- [ ] **Pipeline diagram** (Mermaid) — one canonical definition, reused (or an Astro partial) on index/introduction/agents-index.
- [ ] **Cheat sheet** — a single compact block (commands × overrides × labels) at the top of `slash-commands.mdx`; consider a printable version.
- [ ] **Status-comment gallery** — reproduce the four status states as styled blockquotes so users recognize them.
- [ ] **Glossary** (in `about/index.mdx` or standalone): pipeline branch, tactical zone, design zone, wave, DoR/DoD, chain.
- [ ] **Dashboard** (`docs/public/dashboard`): update queried labels/workflows; add a column/legend for the new stage labels.
- [ ] If `docs/public/LLMs-full.txt` (or equivalent single-file doc) exists in this repo's docs pipeline, regenerate it after all phases.

---

## Phase 6 — Validation & ship

- [ ] `cd docs && npm ci && npm run build` — zero errors/warnings.
- [ ] Link validation (internal + the README's external links to the site).
- [ ] Consistency greps from Phase 1 exit criteria, re-run.
- [ ] Manual read-through of `first-run.mdx` against a real run of the smoke test (`scripts/smoke-test-plan.sh`) — the docs' promised comments/labels must match reality byte-for-byte where quoted.
- [ ] Update `README.md`: remove the "docs site still describes the previous topology" disclaimer; restore the full "Where to go next" table with new slugs.
- [ ] Single PR titled `docs: revise documentation for the new agent topology`.

**Global exit criteria:** a newcomer can go from install to a merged pipeline PR using only `first-run.mdx`; a user with a failed run can self-serve from `when-things-fail.mdx`; no page mentions the old taxonomy outside the migration guide.

---

## Suggested execution order & sizing

| Phase | Size | Depends on |
|---|---|---|
| 1 Terminology sweep | S | — |
| 2 IA / files / redirects | S | 1 |
| 3 Page rewrites | L (10 pages) | 2 |
| 4 New guides | M (4 pages) | 3 |
| 5 Didactic assets | M | 3 |
| 6 Validation | S | all |

Phases 3–5 parallelize well per-page (each page spec above is self-contained) — a good fit for the autoducks pipeline itself: one Feature issue per phase, tasks per page.
