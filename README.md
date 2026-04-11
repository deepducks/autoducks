# claude-in-github

> A template repo for autonomous agentic development workflows powered by [Claude Code](https://github.com/anthropics/claude-code-action).

Drop this template into any GitHub repository and let Claude agents implement a multi-issue plan from start to finish — no human intervention required after the kickstart.

---

## What you get

Three composable GitHub Actions workflows plus tooling:

| File | Purpose |
|---|---|
| `.github/workflows/claude-meta.yml` | **Orchestrator** — reads a meta issue, tracks progress, assigns next wave |
| `.github/workflows/claude-task.yml` | **Worker** — implements a single task, creates and auto-merges its PR |
| `.github/workflows/claude-fix.yml` | **Recovery** — `@claude fix` picks up failed tasks, resolves conflicts |
| `.github/ISSUE_TEMPLATE/meta-issue.yml` | Structured form for creating meta issues |
| `.github/ISSUE_TEMPLATE/task-issue.yml` | Structured form for creating task issues |
| `scripts/setup.sh` | Validates prerequisites and creates labels |
| `scripts/smoke-test.sh` | End-to-end validator — creates 3 trivial tasks and runs the loop |

---

## How it works

```
Human comments @claude
on meta issue (kickstart)
        │
        ▼
   ┌──────────────────────────────────────────┐
   │         claude-meta.yml                   │
   │  1. Determine meta issue (#N)             │
   │  2. Ensure branch meta/<N> exists         │
   │  3. Check merged PRs → mark done          │
   │  4. Find next ready issues                │
   │  5. Comment @claude on them               │
   └──────────────┬───────────────────────────┘
                  │ comments @claude on task issue
                  ▼
   ┌──────────────────────────────────────────┐
   │         claude-task.yml                   │
   │  1. Extract base branch from comment      │
   │  2. Checkout meta/<N> (not main)          │
   │  3. Implement the issue                   │
   │  4. Auto-create PR → auto-merge           │
   │  5. gh workflow run claude-meta.yml ←──── │─── loop closure
   └──────────────┬───────────────────────────┘
                  │ workflow_dispatch with meta_issue input
                  ▼
              loops back to claude-meta.yml
                  │
          (when all tasks done)
                  ▼
   meta agent opens final PR: meta/<N> → main
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

---

## Quick start

### 1. Create your repo from this template

Click **Use this template** at the top of this page → create a new repo.

### 2. Run the setup script

```bash
cd your-new-repo
./scripts/setup.sh
```

The script will:
- Create required labels (`meta`, `smoke-test`, `priority:P0` … `P3`)
- Check that the `CLAUDE_CODE_OAUTH_TOKEN` secret is set
- Check that Actions have the right workflow permissions
- Report anything that needs manual setup

### 3. Manual prerequisites (one-time per repo)

Some things the script can't automate for you:

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
./scripts/smoke-test.sh --cleanup
```

This creates 3 trivial tasks (create a file, append to it, create another file) in 2 waves, kickstarts the loop, and waits for the final PR. The `--cleanup` flag removes all artifacts after success.

If the smoke test passes, your setup is ready for real work.

---

## Usage

### Creating an implementation plan

1. **Create task issues** using the "Task Issue" template. One issue per unit of work. Include acceptance criteria and explicit dependencies.

2. **Create a meta issue** using the "Meta Issue" template. Reference the task issues by number in the waves section.

3. **Kickstart** by commenting on the meta issue:
   ```
   @claude
   ```

4. The orchestrator takes over:
   - Creates the `meta/<N>` branch
   - Assigns Wave 1 issues (comments `@claude` on each)
   - Posts a summary

5. The loop runs autonomously:
   - Task workers implement → create PRs → merge → trigger meta
   - Meta advances through waves
   - Repeats until everything is done
   - Final PR: `meta/<N>` → `main` opens automatically

### Handling failures

When a task worker fails:

1. A notification is posted on both the **meta issue** and the **task issue**.
2. Retry by commenting on the failed task issue:
   ```
   @claude fix
   ```
3. The fix agent picks up the existing partial branch, reads the error context from previous comments, and attempts to complete the task.
4. If the fix agent also fails, it posts `❌ Manual intervention needed` on the meta issue.

### Retrying the orchestrator

If the meta orchestrator itself fails (rare, usually transient), just comment:
```
@claude
```
on the meta issue. The orchestrator is idempotent — it reads current state and picks up where it left off.

### Multiple implementation plans

Multiple meta issues can coexist in the same repo. Each gets its own `meta/<N>` branch and operates independently. Tasks are scoped to their meta issue via the `Base branch` instruction in the orchestrator's comment.

---

## Workflow details

### `claude-meta.yml` — Orchestrator

| | |
|---|---|
| **Triggers** | PR merge into `meta/*` (human), `@claude` comment on `meta`-labeled issue, `workflow_dispatch` from task worker post-step |
| **Mode** | Automation (fixed `prompt`) |
| **Model** | `claude-sonnet-4-6` |
| **Timeout** | 60 minutes |
| **Key permissions** | `contents: write`, `pull-requests: write`, `issues: write` |

### `claude-task.yml` — Worker

| | |
|---|---|
| **Triggers** | `@claude` comment on non-meta issue (excludes `@claude fix`) |
| **Mode** | Interactive (reads issue body + comment as context) |
| **Model** | `claude-sonnet-4-6` |
| **Timeout** | 60 minutes |
| **Key permissions** | `contents: write`, `pull-requests: write`, `issues: write`, **`actions: write`** (needed for loop closure via `workflow_dispatch`) |

### `claude-fix.yml` — Fix agent

| | |
|---|---|
| **Triggers** | `@claude fix` comment on non-meta issue |
| **Mode** | Interactive (reads all issue comments including failure context) |
| **Model** | `claude-sonnet-4-6` |
| **Timeout** | 60 minutes |
| **Key permissions** | Same as task worker |

---

## Guardrails

| Guardrail | Description |
|---|---|
| **60-minute timeout** | All agent jobs have a hard time limit to prevent runaway costs |
| **Failure notifications** | Failures are reported on both the meta and task issues |
| **Fix agent** | `@claude fix` provides semi-automated recovery |
| **Idempotent orchestrator** | Re-running the meta agent is always safe — it reads current state |
| **Conflict resolution** | Task worker auto-resolves merge conflicts via API merge |
| **Bot allowlist** | Only `claude[bot]` and `github-actions[bot]` can trigger workflows |
| **Loop closure via `workflow_dispatch`** | Task workers trigger meta after merge (GITHUB_TOKEN events can't cascade) |

### Known limitations

| Limitation | Workaround |
|---|---|
| `GITHUB_TOKEN`-generated events don't trigger other workflows (neither PR merges nor bot comments) | Post-step uses `gh workflow run` (workflow_dispatch IS allowed for `GITHUB_TOKEN`) |
| Workflow validation fails when workflow files change between trigger and execution | Re-trigger via `@claude` comment (uses the latest workflow from `main`) |
| `git` auth not available in post-steps | Post-steps use `gh api` and `gh` CLI instead of `git` commands |
| Parallel tasks in the same wave may cause merge conflicts | Post-step tries direct merge, falls back to API merge; unresolvable conflicts trigger a failure notification |
| P1+ tasks need human review before merging (depending on branch protection) | The orchestrator only auto-merges P0 tasks; others wait for review |

---

## Configuration

The defaults should work out of the box, but you can customize:

### Change the model

Edit the `claude_args` line in the workflows:

```yaml
claude_args: "--model claude-opus-4-5"  # or claude-haiku-4-5, etc.
```

### Change the timeout

Edit `timeout-minutes` at the job level. Max is 360 minutes on GitHub-hosted runners.

### Restrict who can trigger

By default, any `@claude` comment from a repo collaborator triggers workflows. To restrict further, add `allowed_non_write_users` or modify the `if` conditions.

---

## Architecture decisions

A few non-obvious choices documented for future maintainers:

- **Why not use `prompt` in task/fix workflows?** Interactive mode (no `prompt`) lets the agent read the issue body and triggering comment as natural context. Using `prompt` would switch to automation mode and require manually passing all that context.

- **Why `gh api` instead of `git` in post-steps?** Git credentials are revoked after the `claude-code-action` step completes, but `GITHUB_TOKEN` still works with the `gh` CLI. So all remote operations after the agent step use `gh api`.

- **Why a separate meta branch per plan?** Isolation. Multiple plans can run in parallel without stepping on each other. It also makes it trivial to abandon a plan — just delete the branch.

- **Why does the meta re-check state on every run?** Idempotency. A failed or retried run should never corrupt state or double-assign tasks. The meta always reads the current issue checkboxes and PR statuses as the source of truth.

- **Why `workflow_dispatch` for loop closure instead of just comments?** GitHub Actions deliberately blocks `GITHUB_TOKEN`-generated events from triggering other workflows (to prevent infinite loops). The only exception is `workflow_dispatch` and `repository_dispatch`, so we use those.

---

## Contributing

Issues and PRs welcome. If you find a new failure mode, please document the root cause in the "Known limitations" table.

## License

MIT
