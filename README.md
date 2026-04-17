# claude-in-github

> A template repo for autonomous agentic development workflows powered by [Claude Code](https://github.com/anthropics/claude-code-action).

Drop this template into any GitHub repository and let Claude agents implement a multi-issue plan from start to finish — no human intervention required after the kickstart.

---

## What you get

Four composable GitHub Actions workflows plus tooling:

| File | Purpose |
|---|---|
| `.github/workflows/claude-plan.yml` | **Planner** — `@plan-agent` runs an iterative planning conversation (questions → plan → revisions) and produces a ready-to-kickstart meta issue |
| `.github/workflows/claude-meta.yml` | **Orchestrator** — deterministic bash script that tracks progress and dispatches tasks |
| `.github/workflows/claude-task.yml` | **Worker** — implements a single task, creates and auto-merges its PR |
| `.github/workflows/claude-fix.yml` | **Recovery** — `@claude fix` picks up failed tasks, resolves conflicts |
| `.github/prompts/` | Agent system prompts as editable `.md` files — loaded into workflows at runtime |
| `.github/scripts/meta-orchestrate.sh` | Bash script that powers the meta orchestrator (zero LLM) |
| `.github/ISSUE_TEMPLATE/meta-issue.yml` | Structured form for creating meta issues |
| `.github/ISSUE_TEMPLATE/task-issue.yml` | Structured form for creating task issues |
| `.github/scripts/setup.sh` | Validates prerequisites and creates labels |
| `scripts/smoke-test.sh` | End-to-end validator — creates 3 trivial tasks and runs the loop (source repo only) |

## Architectural highlights

- **Meta orchestrator is 100% deterministic** — it's a bash script, not an LLM. Parses a YAML plan block from the meta issue, checks merged PRs, updates checkboxes, dispatches the next wave. Runs in seconds, costs $0.
- **LLMs are only used where they must be** — planning (plan-agent), implementing (task worker), and fixing failures (fix agent). Everything else is bash.
- **Plan agent is optional but end-to-end** — mention `@plan-agent` on a feature request and you get back a full meta issue with task issues created and linked. Model and reasoning level are configurable via directive.
- **Loop closure via `workflow_dispatch`** — the only way to cascade workflow runs from `GITHUB_TOKEN`-authenticated steps, since PR merges and bot comments by `GITHUB_TOKEN` don't trigger workflows.
- **Branch per meta issue** — `meta/<N>` acts as an integration branch for the plan. Task PRs target it. When all tasks are done, a final PR merges `meta/<N>` → `main`.
- **Prompts live in `.github/prompts/`** — edit the `.md` files to tune agent behavior without touching workflow YAML.

---

## How it works

```
   (optional — skip if you write the plan manually)

 Human files a feature request and
 comments @plan-agent [model] [reasoning]
        │
        ▼                                         ┌──── human answers questions in new comments ───┐
   ┌──────────────────────────────────────────┐   │                                                │
   │         claude-plan.yml                   │◄──┤           human comments revision requests ◄──┤
   │  1. Parse directive (model, reasoning)    │   │                                                │
   │  2. On revision: gather conversation      │   │                                                │
   │     context (current plan + existing      │   │                                                │
   │     tasks + recent comments)              │   │                                                │
   │  3. Plan agent: Questions Mode OR         │   │                                                │
   │     Plan Mode (new or revised)            │   │                                                │
   │     ├── Questions → post comment, stop ───┼───┘                                                │
   │     └── Plan ─── 4. Splitter: extract    │                                                     │
   │                    tasks (ref = Tn or #)  │                                                     │
   │                  5. Bash reconciliation:  │                                                     │
   │                    integer ref → edit     │                                                     │
   │                    Tn ref       → create  │                                                     │
   │                    dropped      → close   │                                                     │
   │                    + label meta+draft     │                                                     │
   │                    (first pass only)      │                                                     │
   └──────────────┬───────────────────────────┘                                                      │
                  │                                                                                  │
                  │  (issue now `meta`+`draft`; further @plan-agent → revision) ──────────────────── ┘
                  ▼
 Human reviews the plan, comments @claude to approve + kickstart
        │           (meta orchestrator removes the `draft` label,
        │            blocking further @plan-agent revisions)
        ▼
   ┌──────────────────────────────────────────┐
   │         claude-meta.yml (bash)            │
   │  1. Parse YAML plan from issue body       │
   │  2. Ensure meta/<N> branch exists         │
   │  3. Scan merged PRs → update checkboxes   │
   │  4. Find next ready wave                  │
   │  5. gh workflow run claude-task.yml ───── │──┐
   └──────────────┬───────────────────────────┘  │
                  │                              │
                  ▼                              │
   ┌──────────────────────────────────────────┐  │
   │         claude-task.yml (Claude)          │◄─┘
   │  1. Read issue body (gh issue view)       │
   │  2. Implement tasks                       │
   │  3. Commit + push branch                  │
   │  4. Post-step: auto-create + merge PR     │
   │  5. gh workflow run claude-meta.yml ───── │──┐
   └──────────────────────────────────────────┘  │
                                                 │
                  ┌──────────────────────────────┘
                  ▼
              loops back to claude-meta.yml
                  │
          (when all waves done)
                  ▼
   meta script opens final PR: meta/<N> → main
```

### Branch model

```
main
 ├── meta/17                          ← meta issue #17's integration branch
 │    ├── claude/17-issue-1-xxxxx     ← task #1 branch
 │    ├── claude/17-issue-3-xxxxx     ← task #3 branch
 │    └── claude/17-issue-7-xxxxx     ← task #7 branch
 │
 └── meta/42                          ← another meta issue's branch
      └── claude/42-issue-1-xxxxx
```

- Each **meta issue** gets its own integration branch: `meta/<issue_number>`
- Each **task** branches from the meta branch: `claude/<meta>-issue-<task>-<timestamp>`
- Task PRs target the meta branch (not `main`)
- When all tasks are done, a final PR merges `meta/<N>` → `main`
- Multiple meta issues (multiple implementation plans) can run in parallel

### Meta issue format

The meta issue body can use **one of two formats**:

**1. YAML (preferred — explicit):**

````markdown
## Plan

```yaml
waves:
  - name: Foundation
    tasks: [1]
  - name: Contracts
    tasks: [2]
  - name: Core
    tasks: [3, 5, 6, 7]
```

## Progress

- [ ] #1 Project Bootstrap `P0`
- [ ] #2 Data Model `P0`
- [ ] #3 Router `P0`
...
````

**2. Markdown (fallback — natural headings):**

```markdown
## Wave 1 — Foundation
- [ ] #1 Project Bootstrap `P0`

## Wave 2: Contracts
- [ ] #2 Data Model `P0`

### Wave 3 (Core)
- [ ] #3 Router `P0`
- [ ] #5 Token Management `P0`
```

The orchestrator tries YAML first (parsed with `yq`, pre-installed on runners). If no valid YAML plan block is found, it falls back to markdown parsing (awk-based, lenient). Markdown parsing rules:

- **Wave header:** line starts with `#`, `*`, or the word "Wave"; contains "Wave <N>"; is not a checkbox
- **Task:** checkbox line `- [ ] #N` or `* [ ] #N` (or `[x]` for done), assigned to the most recent wave
- **Wave name:** whatever text follows "Wave <N>", after stripping separators (`:`, `—`, `-`, `(`, etc.)

State (which tasks are done) is always derived from merged PRs — the checkboxes are updated by the orchestrator.

---

## Quick start

### 1. Get the files

**Option A — New repo (easiest):** Click **Use this template** at the top of this page → create a new repo, then skip to step 2.

**Option B — Existing repo:** run the install script in your repo root:

```bash
curl -s https://raw.githubusercontent.com/ggondim/claude-in-github/main/scripts/install.sh | bash
```

Only `.github/` is modified — nothing else is added to your repo. On a fresh install, setup runs automatically (you can skip to step 3). Run again at any time to update to the latest version.

### 2. Run the setup script

```bash
.github/scripts/setup.sh
```

The script will:
- Create required labels (`meta`, `smoke-test`, `priority:P0` … `P3`)
- Check that the `CLAUDE_CODE_OAUTH_TOKEN` secret is set
- Check that Actions have the right workflow permissions
- Report anything that needs manual setup

### 3. Manual prerequisites (one-time per repo)

#### a) Install the Claude Code GitHub App

Visit https://github.com/apps/claude and install it on your repo.

#### b) Add the OAuth token secret

Get a token from https://claude.com/oauth/code and add it:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN
```

#### c) Enable write permissions + PR creation for Actions

```bash
gh api repos/OWNER/REPO/actions/permissions/workflow \
  -X PUT \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true
```

If your org blocks this, enable it at `https://github.com/organizations/<ORG>/settings/actions`:
- **Workflow permissions:** Read and write permissions
- ☑️ Allow GitHub Actions to create and approve pull requests

### 4. Validate with a smoke test

```bash
# from the claude-in-github source repo
./scripts/smoke-test.sh --cleanup
```

This creates 3 trivial tasks in 2 waves, kickstarts the loop, waits for the final PR, then cleans up all artifacts.

If the smoke test passes, your setup is ready for real work.

---

## Usage

### Option A — Generate the plan with `@plan-agent` (easiest)

Planning is a short conversation on the issue. The plan-agent can ask clarifying questions, propose a plan, accept revision requests, and iterate until you approve by commenting `@claude`.

#### 1. File a feature/problem issue

Just describe what you want — no template required. The trigger filter requires the issue to NOT be a task (`priority:P*` label) and to be either unplanned (no `meta` label) or still a draft (`meta`+`draft`).

#### 2. Trigger with `@plan-agent`

Comment on the issue. The comment can be just `@plan-agent`, or include a directive to pin model and reasoning budget:

```
@plan-agent                       # defaults: opus + high thinking
@plan-agent sonnet                # sonnet + high thinking
@plan-agent opus max              # opus + ultrathink
@plan-agent haiku off             # haiku, no extended thinking
```

Directive tokens — **model:** `opus` | `sonnet` | `haiku`; **reasoning:** `off` | `low` | `medium` | `high` | `max`. Unknown tokens are ignored. Punctuation and case are forgiven (`@plan-agent sonnet, please` → sonnet + default reasoning).

#### 3. The agent responds in one of three ways

**(a) Questions** — if the agent is missing critical info, it posts a numbered list of clarifying questions and stops. No task issues are created; no labels are applied. Reply to the questions in new comments, then mention `@plan-agent` again (with or without a directive) to continue. The agent sees the full thread on the next run.

**(b) First plan** — if enough context is present, the plan-agent drafts a full meta-issue plan (Purpose / YAML Plan / Progress / Notes) into the issue body, the splitter extracts task specs, and a deterministic bash step creates the task issues, labels the issue `meta`+`draft`, and assigns you as the planning author. The issue now looks like a manually-authored meta (Option B below).

**(c) Revision** — if the issue is already `meta`+`draft` and you comment change requests ("split task 3 into frontend and backend", "drop task 5", "task 2 needs more detail on X"), then re-mention `@plan-agent`, the agent revises. Reconciliation is **deterministic**:

- Existing task issue numbers that appear in the new plan YAML → `gh issue edit` (only if title or body actually changed)
- Existing numbers dropped from the new plan → `gh issue close` with a "Superseded by revised plan" comment
- Fresh `Tn` placeholders in the new plan → `gh issue create`

The identity signal is the `ref` the plan-agent writes in each `### …` heading: a bare integer means "preserve issue #N", a `Tn` placeholder means "create new". You can see every identity choice in the plan body before approving.

#### 4. Approve and kickstart

When you're happy with the plan, comment `@claude` on the meta issue. The orchestrator starts, removes the `draft` label (which also blocks further `@plan-agent` revisions), and runs the implementation loop to completion.

When the final `meta/<N> → main` PR merges, GitHub auto-closes every task issue and the meta issue via `Closes #N` lines in the PR body.

<details>
<summary>Example transcript</summary>

```
[human]   Opens issue: "Add rate limiting to the public API"
[human]   Comments: @plan-agent sonnet medium

[bot]     🤔 Plan agent has questions before writing the plan.
          1. Which endpoints are "public" — anything under /v1/ or only unauthenticated ones?
          2. Sliding window or fixed window?
          3. Per-IP or per-API-key?
          Reply and re-mention @plan-agent.

[human]   Comments: 1. all of /v1/public/*  2. sliding window  3. per-IP for now
[human]   Comments: @plan-agent

[bot]     Updates issue body with Purpose / YAML Plan / Progress / Notes.
          Creates task issues #42, #43, #44. Labels issue meta + draft.
          Posts: "Plan ready. Created 3 task issues; assigned to you."

[human]   Comments: "Task #43 and #44 are really the same work — merge them"
[human]   Comments: @plan-agent

[bot]     Revised plan now has `tasks: [42, T_NEW]` in YAML.
          Closes #44 with "Superseded by revised plan on #N".
          Edits #43's title/body to reflect the merged scope.
          Creates new task for T_NEW.
          Posts: "Plan revised. 1 created, 1 updated, 0 unchanged, 1 closed."

[human]   Comments: @claude

[meta]    Removes `draft` label. Dispatches wave 1. Loop runs to completion.
[meta]    Opens final PR meta/N → main with body "Closes #42, Closes #43, Closes #T_NEW_RESOLVED, Closes #N"
[human]   Merges final PR. All issues auto-close.
```

</details>

### Option B — Write the plan manually

1. **Create task issues** using the "Task Issue" template. One issue per unit of work. Include acceptance criteria and explicit dependencies.

2. **Create a meta issue** using the "Meta Issue" template. Reference the task issues by number in the YAML plan block.

3. **Kickstart** by commenting on the meta issue:
   ```
   @claude
   ```
   Or assign the meta issue to someone (triggers the same workflow).

4. The orchestrator takes over — creates the branch, dispatches the first wave, tracks progress, advances waves, and opens the final PR automatically.

### Handling failures

When a task worker fails:

1. A notification is posted on both the **meta issue** and the **task issue**.
2. Retry by commenting on the failed task issue:
   ```
   @claude fix
   ```
3. The fix agent picks up the existing partial branch, reads the error context from previous comments, and attempts to complete the task.

### Retrying the orchestrator

If the meta orchestrator itself fails (rare), just comment `@claude` on the meta issue. The script is idempotent — it reads current state from GitHub and picks up where it left off.

### Manually dispatching the orchestrator

You can also trigger the meta workflow directly (no comment needed):

```bash
gh workflow run claude-meta.yml -f meta_issue=17
```

---

## Workflow details

### `claude-plan.yml` — Planner (two-agent, iterative)

| | |
|---|---|
| **Triggers** | `@plan-agent` comment on an issue that is NOT a task (no `priority:P*`) AND is either unplanned (no `meta`) OR still draft (`meta`+`draft`). PR comments ignored. |
| **Modes** | **Questions Mode** — agent writes only `/tmp/questions.md` → workflow posts a comment and stops (no labels, no tasks). **Plan Mode** — agent writes `/tmp/plan-body.md` → splitter + reconciliation run. **Revision Mode** — subcase of Plan Mode triggered when the issue is `meta`+`draft`; the workflow builds `/tmp/conversation.md` (current plan + existing task bodies + recent comments) as extra context. |
| **Agent 1 (Plan)** | Model configurable via directive (default `claude-opus-4-7`). Tools: `Read, Glob, Grep, Write`. Explores the repo; decides Questions vs Plan Mode; on Plan Mode writes the meta-issue body to `/tmp/plan-body.md` with `Tn` placeholders for new tasks and real integers for preserved tasks. |
| **Agent 2 (Splitter)** | `claude-sonnet-4-6`. Tools: `Read, Write`. Mechanically extracts task specs into `/tmp/tasks.jsonl`. On revisions, reads `/tmp/existing-tasks.json` to accurately refresh preserved-task bodies. |
| **Reconciliation (deterministic)** | Each splitter entry's `ref` drives a single `gh` call: integer → `gh issue edit` (only on content change); `Tn` → `gh issue create`; numbers in old plan but absent from new plan → `gh issue close` with a "Superseded" comment. |
| **Extended thinking** | Controlled by directive (`off`/`low`/`medium`/`high`/`max`) → injects magic phrase (`think hard` / `think very hard` / `ultrathink`) into the prompt. |
| **Timeout** | 30 minutes |
| **Key permissions** | `contents: read`, `issues: write`, `id-token: write` |

### `claude-meta.yml` — Orchestrator (deterministic)

| | |
|---|---|
| **Triggers** | `@claude` comment on meta issue, assign on meta issue, PR merge into `meta/*` (human merges), `workflow_dispatch` (from task worker post-step) |
| **Implementation** | Pure bash script in `.github/scripts/meta-orchestrate.sh` |
| **LLM** | None |
| **Timeout** | 10 minutes |
| **Key permissions** | `contents: write`, `pull-requests: write`, `issues: write`, `actions: write` |

### `claude-task.yml` — Worker

| | |
|---|---|
| **Triggers** | `workflow_dispatch` (from meta script), `@claude` comment on non-meta issue (manual retry) |
| **Implementation** | Claude Code agent with explicit prompt |
| **Model** | `claude-sonnet-4-6` |
| **Timeout** | 60 minutes |
| **Key permissions** | `contents: write`, `pull-requests: write`, `issues: write`, `actions: write` |

### `claude-fix.yml` — Fix agent

| | |
|---|---|
| **Triggers** | `@claude fix` comment on non-meta issue |
| **Implementation** | Claude Code agent, picks up existing partial branch |
| **Model** | `claude-sonnet-4-6` |
| **Timeout** | 60 minutes |
| **Key permissions** | Same as task worker |

---

## Guardrails

| Guardrail | Description |
|---|---|
| **Deterministic meta** | The orchestrator is a bash script — no LLM drift, no probabilistic failures |
| **60-minute timeout** | Task/fix agents have a hard time limit to prevent runaway costs |
| **Failure notifications** | Failures are reported on both the meta and task issues |
| **Fix agent** | `@claude fix` provides semi-automated recovery |
| **Idempotent orchestrator** | Re-running the meta script is always safe — it reads current state from GitHub |
| **Conflict resolution** | Task worker auto-resolves merge conflicts via API merge |
| **Bot allowlist** | Only `claude[bot]` and `github-actions[bot]` can trigger workflows |
| **Loop closure via `workflow_dispatch`** | Reliable cross-workflow triggering from `GITHUB_TOKEN` |

### Known limitations

| Limitation | Workaround |
|---|---|
| `GITHUB_TOKEN`-generated events don't trigger other workflows (neither PR merges nor bot comments) | Use `gh workflow run` (workflow_dispatch IS allowed for `GITHUB_TOKEN`) |
| Workflow validation fails when workflow files change between trigger and execution | Re-trigger via `@claude` comment (uses the latest workflow from `main`) |
| `git` auth not available in post-steps | Post-steps use `gh api` and `gh` CLI instead of `git` commands |
| Git ref replication lag after branch creation | Meta script waits up to 5s; task worker pre-step polls up to 20s |
| Parallel tasks in the same wave may touch shared files | Post-step tries direct merge, falls back to API merge; unresolvable conflicts trigger failure notification |
| P1+ tasks need human review before merging (with branch protection) | The orchestrator comments on P0 tasks mentioning auto-merge; others wait for review |

---

## Configuration

The defaults should work out of the box, but you can customize:

### Edit agent prompts

All agent system prompts live in `.github/prompts/` as `.md` files:

| File | Used by |
|---|---|
| `plan-agent.md` | `claude-plan.yml` — Plan agent (supports `{{THINK_PHRASE}}` placeholder) |
| `splitter-agent.md` | `claude-plan.yml` — Splitter agent |
| `task-worker.md` | `claude-task.yml` — Task worker |
| `fix-agent.md` | `claude-fix.yml` — Fix agent |

Each workflow has a "Load prompt" step that reads the relevant file into `$GITHUB_ENV` at runtime and feeds it into the Claude Code action. Edit the `.md` file and the next workflow run picks it up — no YAML changes needed.

### Change the model

For the **task/fix agents**, edit the `claude_args` line in `claude-task.yml` or `claude-fix.yml`:

```yaml
claude_args: "--model claude-opus-4-5 --allowedTools Bash,Read,Glob,Grep,Write,Edit"
```

**Important:** the model ID must be the full version, not a short alias. `claude-sonnet` does not work — use `claude-sonnet-4-6`.

For the **plan agent**, no YAML edit is needed — pass the directive in the comment:

```
@plan-agent sonnet medium
@plan-agent opus max
@plan-agent haiku off
```

### Change the timeout

Edit `timeout-minutes` at the job level. Max is 360 minutes on GitHub-hosted runners.

### Restrict who can trigger

By default, any `@claude` / `@plan-agent` comment from a repo collaborator triggers workflows. To restrict further, add `allowed_non_write_users` or modify the `if` conditions.

---

## Design decisions

Non-obvious choices documented for future maintainers:

- **Why is the meta orchestrator pure bash instead of an LLM?** The meta does state tracking and dispatching — not creative work. LLMs were probabilistic about parsing wave structure and updating checkboxes. A deterministic script is faster (seconds vs minutes), cheaper ($0 vs ~$0.10 per run), and never drifts.

- **Why YAML for the plan structure?** It's trivially parseable with `yq` (pre-installed on GitHub runners), human-editable, and naturally expresses waves. ASCII dependency graphs were visual but required LLM interpretation.

- **Why `workflow_dispatch` for loop closure?** GitHub Actions deliberately blocks `GITHUB_TOKEN`-generated events from triggering other workflows (to prevent infinite loops). The exception is `workflow_dispatch` and `repository_dispatch`. Bot comments by `GITHUB_TOKEN` are also silent, so we can't use comments for cross-workflow communication.

- **Why a separate meta branch per plan?** Isolation. Multiple plans can run in parallel without stepping on each other. It also makes it trivial to abandon a plan — just delete the branch.

- **Why explicit git commands in the task worker prompt?** Earlier versions said "the workflow handles the PR" and the agent interpreted this as "I don't need to commit/push either." Being explicit eliminates the ambiguity.

- **Why does the task worker poll for branch visibility?** GitHub has eventual consistency on git refs. When the meta script creates `meta/<N>` and immediately dispatches a task worker, the ref may not be visible to `actions/checkout`. Polling handles this.

- **Why does plan-agent revision use bimodal refs (integer or `Tn`) instead of LLM-based task diffing?** Deterministic reconciliation. The plan-agent decides identity at authoring time by writing a real issue number (preserve) or a fresh placeholder (create) into each `### … —` heading. Bash then reconciles with pure set operations — no semantic matching, no "is this task the same as before" inference. The identity choice is visible in the plan body, so humans can audit it before approving with `@claude`.

- **Why does the final PR body use `Closes #N` for every task?** GitHub auto-closes referenced issues only when a PR merges into the **default branch**. Task PRs target `meta/*`, not `main`, so `fixes #N` on them doesn't auto-close anything. The only merge-into-main event is the final meta PR, so it must carry closure directives for every task plus the meta issue itself.

- **Why `gh api` instead of `git ls-remote` in post-steps?** Git credentials are revoked after the `claude-code-action` step completes, but `GITHUB_TOKEN` still works with the `gh` CLI.

---

## Contributing

Issues and PRs welcome. If you find a new failure mode, please document the root cause in the "Known limitations" table.

## License

MIT
