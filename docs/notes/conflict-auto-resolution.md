# Analysis: LLM-based automatic conflict resolution

> **Status: implemented — supersedes the "defer" recommendation below.**
> This shipped as a standalone `resolver` agent
> (`.autoducks/agents/resolver/{defaults.json,pre.sh,prompt.md,post.sh}`),
> not as a hook inside `execution/post.sh`'s rebase-retry loop (option 2,
> below) or a same-attempt-3-only heuristic. The design that shipped:
>
> - **Standalone agent, not an inline retry-loop hook.** The resolver
>   reproduces the conflict itself (`git fetch` + `git merge --no-commit
>   --no-ff`) against the PR's current base/head rather than piggybacking on
>   `execution/post.sh`'s rebase attempts. This sidesteps the "job can't
>   block on another workflow run" tension in option 1 below without
>   entangling the resolver with the unrelated rebase-retry mechanics in
>   option 2 — it runs as its own `pre.sh`/`prompt.md`/`post.sh` triggered by
>   `pull_request: synchronize` (auto) or `/resolve` (manual).
> - **Never merges.** The resolver commits the resolution and does a plain
>   `git push` (never `--force`) to the PR head branch, then stops. It never
>   calls `git::merge_pr` and never dispatches a `#auto:` chain — a human (or
>   the existing review/merge flow) always reviews the pushed merge commit
>   before the PR lands. This directly addresses the "no PR-review gate
>   before merge" failure mode the risk table below flagged as the
>   deal-breaker for auto-merging a wrong resolution.
> - **Config-gated, not frequency-gated.** Rather than waiting for usage
>   data, it ships behind `resolver.auto` (default `true`) and a
>   `resolver.opt_out_label` (default `Resolve:off`), both of which the
>   automatic trigger honors and `/resolve` deliberately ignores. A
>   defence-in-depth loop guard (skip when the PR head tip is already an
>   autoducks resolution commit) bounds the "infinite retry" risk instead of
>   the attempt-counter approach sketched below.
> - **Auditable by construction.** Every resolution applies the
>   `auto-resolved` PR label and posts `/tmp/resolution-summary.md` (a
>   per-file account of how each conflict was reconciled) as a comment on the
>   feature/bug issue — the audit trail the risk table called for.
>
> The rest of this document is kept as historical context for the mechanics
> (hook points, inputs, provider surface) that informed the shipped design.

## The ask

Today, when `execution/post.sh` retries a merge by rebasing onto the base
branch and hits a rebase conflict, it gives up immediately:

```bash
echo "Rebase conflict on attempt $attempt failed — aborting"
git rebase --abort 2>/dev/null || true
break
```

(`.autoducks/agents/execution/post.sh:66-72`). The issue this task descends
from asks whether that abort path could instead kick off another LLM step to
resolve the conflict automatically and continue the rebase/merge, rather than
failing the task and waiting on a human.

`fix/post.sh` doesn't rebase at all — its merge path is a single
`git::merge_pr "$PR_NUM"` call (`.autoducks/agents/fix/post.sh:38`) that
either succeeds or fails outright. Conflicts there surface as a failed merge,
not a rebase conflict, so a resolver would need a slightly different entry
point (see below).

## Where it would hook in

**Primary hook: `execution/post.sh`, inside the rebase-retry loop
(lines 53-74).** After `git rebase "origin/$BASE_BRANCH"` fails, instead of
aborting on the spot, a resolver step would run *before* the `git rebase
--abort`:

```bash
if ! git rebase "origin/$BASE_BRANCH"; then
  if resolve_conflicts_with_llm; then   # new step
    git push --force-with-lease origin "$TASK_BRANCH"
    continue   # loop back into the existing attempt/merge cycle
  fi
  echo "Rebase conflict on attempt $attempt — aborting"
  git rebase --abort 2>/dev/null || true
  break
fi
```

The existing `for attempt in 1 2 3` loop already provides the retry
structure and an upper bound — a resolver only needs to fit inside one
attempt, not add new looping.

**Secondary hook: `fix/post.sh`, around the `git::merge_pr "$PR_NUM"` call
(line 38).** Since `fix` doesn't rebase, a resolver here would need to be
triggered on merge failure by explicitly rebasing the fix branch onto
`$BASE_BRANCH`, attempting the resolve, and retrying `git::merge_pr`. This
is a smaller, less-trafficked path (fix branches are usually short-lived and
already scoped to a small diff) and can reuse whatever helper the primary
hook produces — it does not need independent design.

Both hook points are inside GHA post-steps, which already run with
`contents: write` and a checked-out worktree, so no new permissions are
needed to run `git` commands there.

## Inputs the resolver needs

After a failed `git rebase`, the working tree already contains everything
required, no extra fetch/diff plumbing needed:

- **Conflicted file list**: `git diff --name-only --diff-filter=U`
- **Conflict markers per file**: the working-tree copy of each conflicted
  file already has `<<<<<<<` / `=======` / `>>>>>>>` markers embedded — this
  is what an LLM resolver would read and rewrite.
- **The two sides for context**: `git show :2:<path>` (ours, i.e. the
  rebased task branch commit) and `git show :3:<path>` (theirs, i.e.
  `origin/$BASE_BRANCH`) via the merge stages in the index, plus `git log
  -1 --format=%B` on each side's tip commit for intent.
- **Task/issue context**: `$ISSUE_NUM` and `its::get_issue "$ISSUE_NUM"` are
  already available in `post.sh`, and can be handed to the resolver as
  background on what the branch is trying to accomplish — useful for
  judging which side should "win" a given hunk.

No new data plumbing is required; the resolver is a pure function of state
already sitting in the git working tree at the point of failure.

## Reusing the existing LLM provider surface

`.autoducks/providers/llm/interface.sh` sources the current
`AUTODUCKS_LLM_PROVIDER` directory (e.g. `claude/`) and requires it to
implement `llm::invoke_agent(prompt_file, model, reasoning)`. This is
exactly the shape a conflict resolver needs: write conflict context to a
prompt file, call `llm::invoke_agent`, then read back the resolved files.
The interface's own comment is relevant here: "in GitHub Actions the actual
LLM invocation is handled by the composite action, not by shell" — the
current agents (`execution`, `fix`, ...) all invoke Claude via the
`./.autoducks/providers/llm/claude` composite action as a workflow step
(`autoducks-execute.yml:102-111`), not through `interface.sh`. A resolver
has two options:

1. **Dispatch as a full agent** — add a new `resolveConflict` agent
   (its own `pre.sh`/`prompt.md`/`post.sh` + a
   `autoducks-resolve-conflict.yml` workflow), invoked via
   `workflow_dispatch` from within `execution/post.sh` (similar to how
   `trigger_loop_closure` re-triggers the wave orchestrator). This mirrors
   the existing pattern exactly but means the current job has to *exit* and
   hand off — `post.sh` can't block on another workflow run and resume the
   merge loop inline.

2. **Dispatch as an in-process step**, using `interface.sh` /
   `llm::invoke_agent` directly from inside `execution/post.sh`. This keeps
   the whole rebase-retry loop in one job, which is what the `continue`
   sketch above assumes, and is why `interface.sh` calling out its
   non-GHA/testing purpose matters less than it looks — this would be the
   first "real" GHA caller of `interface.sh`, using it as a synchronous
   subroutine rather than a composite-action step.

Option 2 is the only one that fits inside the existing retry loop without
restructuring `execution/post.sh` into multiple jobs; option 1 is simpler to
build but changes the control flow (fire-and-forget + re-dispatch instead of
retry-in-place) and would need its own idempotency/dedup guard analogous to
`prevent-duplicate-dispatch.sh`.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| **Infinite retry**: a resolver that "succeeds" but produces a rebase that conflicts again on the next attempt could loop. | Bound it inside the existing `for attempt in 1 2 3` loop (no new loop construct) and additionally cap LLM resolution to a single attempt per `post.sh` run — if the rebase still conflicts after one LLM pass, abort immediately rather than invoking the resolver again. |
| **Re-triggering the wave orchestrator on a bad state**: if a resolver merges silently-broken code, `trigger_loop_closure` / the `pull_request: closed` event on `autoducks-wave.yml` will advance the wave believing the task succeeded. | Never let the resolver push directly to a state that triggers a merge. Require CI (tests/typecheck already run by the repo's own checks) to pass on the resolved branch before `git::merge_pr` is attempted — the merge step already only runs after a successful push, so this is an ordering constraint, not new infra. |
| **Merging bad resolutions (silent correctness regressions)**: LLM conflict resolution can pick the wrong hunk (e.g. drop one side's logic) without producing an obviously broken diff. | Treat the resolver's output the same as any agent-authored change: it must pass `assert_changes` and the repo's CI before merge; additionally, post a diff summary or the resolved hunks to the issue thread (reusing `its::comment_issue`, already used at the end of `post.sh`) so a human can review post-hoc even though the merge is automatic. Consider gating resolver-touched merges behind a distinct PR label so they're auditable/greppable later. |
| **Cost**: every rebase conflict now costs an extra LLM invocation, and conflicts can be frequent on wide feature branches with many concurrent sub-PRs. | Only invoke the resolver on the *last* retry attempt (attempt 3) rather than every attempt, so cheap automatic retries (attempt 1, 2 — which often succeed without any conflict once the base branch settles) aren't taxed, and the resolver is reserved for genuinely persistent conflicts. |
| **Scope creep on `fix/post.sh`**: adding rebase logic to a path that currently has none increases the surface area of a script that's meant to be a thin merge-then-notify step. | Extract the resolver into a shared helper (e.g. `core/robustness/resolve-conflicts.sh`) that both `execution/post.sh` and `fix/post.sh` call, rather than duplicating rebase/resolve logic in `fix/post.sh`. |
| **Concurrency**: two agents (e.g. `execution` and a concurrent `fix`) resolving conflicts on branches that both target the same feature branch could race, each resolving against a base that the other is about to change. | No new mitigation needed beyond what exists: `autoducks-execute.yml`'s `concurrency: group: autoducks-execute-<issue>` already serializes dispatches per task, and `git push --force-with-lease` (already used at `execution/post.sh:73`) protects against clobbering a concurrent update to the same branch. |

## Original recommendation: ~~defer~~ (superseded — see the status note at top)

The mechanics are straightforward — the hook point, inputs, and provider
surface all already exist and compose cleanly (this is close to a "wire two
existing pieces together" change, not new infrastructure). What's missing is
evidence that it's worth building: there's no data yet on how often
`execution/post.sh`'s rebase-retry loop actually hits conflicts (as opposed
to stale-branch merges that a plain rebase already resolves), and an LLM
resolver that merges a wrong hunk is a correctness regression injected
*automatically*, with no PR-review gate before merge in scenario B (sub-PRs
auto-merge into the feature branch). That combination — low current signal
on the problem's frequency, and a failure mode that's worse than the status
quo's "abort and ask a human" — argues for waiting until conflict-driven
task failures are actually observed and counted, rather than building
speculatively.

The concern that actually mattered — no PR-review gate before merge — was
resolved not by waiting for frequency data, but by design: the shipped
resolver never merges, so a wrong resolution is caught by the same
human/review gate that would have caught a wrong hand-authored resolution.
That removed the "worse than the status quo" objection without needing
usage data first.

The decomposition sketched below (for the deferred, rebase-loop-integrated
design) was superseded by the standalone-agent shape described in the status
note at the top of this document; it's kept for historical reference only.

1. `core/robustness/resolve-conflicts.sh` — the shared helper: collect
   conflicted files + both sides' content, build a prompt, call
   `llm::invoke_agent`, apply results, `git add` the resolved files.
2. Wire it into `execution/post.sh`'s rebase-retry loop on the final
   attempt only (per the cost mitigation above).
3. A CI-gate check before the post-resolution `git::merge_pr` call, so a
   bad resolution fails loudly instead of merging.
4. A PR-comment/label trail so resolver-touched merges are auditable.
5. Only after the above is stable, consider wiring the same helper into
   `fix/post.sh`'s merge path.
