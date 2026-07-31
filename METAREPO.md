# Metarepo (submodule aggregation)

Run the full autoducks pipeline from a private **metarepo** that aggregates related
repos as git submodules (e.g. `autoducks`, `autoducks-docs`,
`autoducks-api`), driving work across all of them from one place — **without waking
the children's own pipelines**. Execution is backpressured (sequential) and delivery
is children-first / parent-last so the parent→child gitlink is never orphaned.

Everything is gated on `metarepo.enabled`; with it off, autoducks is byte-identical
single-repo.

---

## Prerequisites

- A **metarepo** (usually **private**) that will aggregate the children.
- Child repos added as **git submodules** of the metarepo.
- An **`AUTODUCKS_PAT`** that can push/PR/merge on **every child**, with scopes:
  `repo` (or fine-grained `contents:write` + `pull_requests:write`), **`workflow`**
  (to install workflows), and **`read:org`** (else `gh pr create` fails resolving
  reviewers/teams). A single fine-grained PAT is bound to one owner — cross-org
  children need `per_owner_pat` or a GitHub App (see Auth).
- A Claude credential: **`CLAUDE_CODE_OAUTH_TOKEN`** (from `claude setup-token`) or
  `ANTHROPIC_API_KEY`.

---

## Installation

### 1. Create the metarepo and add children as submodules

```bash
gh repo create OWNER/meta --private
git clone https://github.com/OWNER/meta && cd meta
git submodule add https://github.com/OWNER/child-a.git child-a
git submodule add https://github.com/OWNER/child-b.git child-b
# keep clean https URLs in .gitmodules (no embedded tokens)
```

### 2. Install the autoducks machinery

Either `autoducks install` (the CLI), or copy `.autoducks/` + the
`.github/workflows/autoducks-*.yml` files into the metarepo by hand. The machinery is
the metarepo's own; the children keep their own `.autoducks` (or none).

### 3. Configure `.autoducks/autoducks.json`

```jsonc
"metarepo": {
  "enabled": true,
  "protected_submodule_strategy": "auto_merge",   // or "required_check"
  "auth": { "mode": "single_pat" },                // single_pat | per_owner_pat | github_app
  "submodules": {
    "child-a": { "protected": null },   // key must match a .gitmodules path
    "child-b": { "protected": null }
  }
},
"orchestrator": { "mode": "sequential" },
"defaults": { "merge_method": "squash", "model": "claude-sonnet-5", "effort": "high" }
```

- `protected: null` → detected at runtime from the child's branch protection.
  A bool overrides that detection: `true` makes the parent gate delivery as if
  the child were protected (useful before the protection rule actually lands),
  `false` skips the per-child API probe on a repo whose policy you already know.
- Every key under `submodules` must name a path declared in `.gitmodules`.
  `scripts/setup.sh` check 14 fails on a key with no submodule behind it, so a
  retired child cannot leave live-looking config behind.
- Enabling metarepo mode **forces `orchestrator.mode: sequential`** regardless of
  config (backpressured execution is mandatory — see "How it works").

### 4. Secrets — set them **repo-level on the metarepo**

```bash
# run `claude setup-token`, copy the sk-ant-oat01… token, then:
read -rs CCOT; printf '%s' "$CCOT" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R OWNER/meta; unset CCOT
gh auth token | gh secret set AUTODUCKS_PAT -R OWNER/meta
```

> ⚠️ **Use repo-level secrets on the metarepo.** Org-level secrets with
> `--visibility selected` did **not** reliably reach the metarepo's workflows in
> testing (the token arrived empty → `scope-missing` failures). Only repos that run
> their **own** pipeline need these secrets; children driven solely by the metarepo
> stay dormant and don't need them.

### 5. Actions permissions on the metarepo

```bash
gh api -X PUT repos/OWNER/meta/actions/permissions/workflow \
  -F default_workflow_permissions=write -F can_approve_pull_request_reviews=true
```

### 6. Labels

```bash
for l in Feature Task Bug; do gh label create "$l" -R OWNER/meta --force; done
# Work:*, Design:*, etc. self-create at runtime.
```

### 7. Per **protected** child: allow merge commits + auto-merge

```bash
gh api -X PATCH repos/OWNER/child -F allow_merge_commit=true -F allow_auto_merge=true
```

> ⚠️ **Required for protected children.** Protected delivery uses a **merge commit +
> auto-merge-when-ready** (a merge commit keeps the pinned SHA reachable without an
> async re-pin; auto-merge waits for the child's required checks). If the child is
> squash-only or has auto-merge disabled, delivery **stalls silently**. The doctor
> gate should catch this — verify it before the first run.

### 8. Verify

```bash
# probe write access + protection per child, with the resolved credential:
bash .autoducks/core/security/metarepo-access-gate.sh --table
# recursive clone resolves:
git clone --recurse-submodules https://github.com/OWNER/meta /tmp/check
```

---

## Auth model (`metarepo.auth.mode`)

Every cross-repo op goes through `git::resolve_token(repo)`:

- **`single_pat`** (default) — every child uses `AUTODUCKS_PAT`. For single-owner
  metarepos (e.g. `deepducks/*`).
- **`per_owner_pat`** — owner → `AUTODUCKS_PAT_<OWNER>` secret; resolve by the child's
  owner. For cross-org metarepos.
- **`github_app`** — mint an installation token per owner at run time (rides on the
  OIDC token broker; recommended for genuine multi-org).

---

## How it works

**Branch & execution.** Child branches mirror the parent pipeline branch
`feature/<N>-<slug>`. Real code is committed **inside the child submodule**; the
parent task branch carries only **gitlink bumps**. The **Engineer** tags each task's
`**Modules:**` with the submodule path(s) it changes and orders inter-module
dependencies as wave edges; the **Developer** edits only inside the declared submodule
directories (never the metarepo's own `.autoducks/`).

### Backpressured (sequential) execution — mandatory in metarepo mode

In a metarepo, each submodule is a **single opaque gitlink** (one line) in the parent
tree. Two tasks changing the same child concurrently collide on that pointer — even
when the underlying files don't overlap — and resolving the collision wrong silently
drops a task's work. Modules can also depend on each other (a change in `pkg-a` may
need a change in `pkg-b`).

So execution is **backpressured (sequential), max-in-flight = 1**: the Maestro
dispatches **one task at a time**, and the next task is dispatched only **after the
previous task's PR merged** into the pipeline branch. Each task therefore branches off
the *merged* result of the previous one — the gitlink only ever moves forward (no
write-race) and every task builds/tests against the current state of its dependencies.

This is controlled by `orchestrator.mode`:

- `orchestrator.mode: "sequential"` → backpressured (max-in-flight = 1).
- `orchestrator.mode: "waves"` → parallel waves (the single-repo default).

**Enabling `metarepo.enabled` forces `sequential` at runtime regardless of what the
config says** — `load-config.sh` sets `AUTODUCKS_ORCHESTRATOR_MODE="sequential"` when
metarepo mode is on, so the config cannot accidentally run children in parallel.
DAG-ordered parallelism across *declared-independent* modules (unlocked by the
`**Modules:**` declaration) is a documented future optimization, not the default.

To confirm it's active: `orchestrator.mode` is `"sequential"` in `autoducks.json`, and
any agent run logs/env shows `AUTODUCKS_ORCHESTRATOR_MODE=sequential` once
`AUTODUCKS_METAREPO=true`.

**Delivery (children-first, parent-last).** At feature completion, before the parent
final PR:

- **Unprotected child** → fast-forward its default branch to the child feature head
  (or a merge-commit fallback if it diverged); `squash` policy rewrites the SHA →
  the parent gitlink is **re-pinned**.
- **Protected child** → open a marked PR and **merge-commit + auto-merge-when-ready**
  (merges when required checks pass).

The human merges the parent last. A **skip-marker** (`<!-- autoducks:metarepo-managed
-->`) on child PRs keeps the child's own reviewer/rework/commit-lint dormant.

### The gitlink pin contract

**A parent gitlink always pins the tip of the child's default branch — never the tip
of the child's feature branch.**

The distinction is not cosmetic. A gitlink is an opaque SHA in the parent's tree, and
GitHub merges it 3-way like any other blob: base vs ours vs theirs. Reachability from
the default branch is *not* the property that governs it. A parent PR pinning a feature
tip that a delivery merge commit kept perfectly reachable still conflicts the moment
the base's gitlink moves — which is exactly how both parent PRs of the 2026-07-29
incident flipped to `CONFLICTING/DIRTY` (#119).

Two moments reconcile the pin, because neither alone is sufficient:

1. **At delivery**, `git::submodule_deliver` re-reads the child's default-branch tip
   after any *synchronous* merge and returns that, asking Maestro for a gitlink bump
   when it differs from the feature tip.
2. **Late**, `metarepo::reconcile_gitlinks` fast-forwards an open parent PR's gitlinks
   to each child's current tip. This covers the two cases delivery cannot:
   an **async auto-merge** cannot report the SHA it will eventually produce, and a
   **sibling parent PR merging** moves the base's gitlink out from under every other
   open PR. It runs from three places, covering every way a pin goes stale: the
   delivery poller (per PR), the `repin-siblings` job on any parent PR merge, and
   the `repin-on-base-push` job on any direct push to the default branch.

Reconciliation **only ever fast-forwards**. A pin that is *ahead* of the child's
default branch means the delivery has not merged yet and is left alone; a *diverged*
pin means history was rewritten and is reported for a human. It never moves a pin
backwards or across rewritten history.

### Required-check recovery

Auto-merge only fires when the required checks report, so a child delivery PR whose
`opened` event produced no workflow run waits forever — `autoducks#1121` sat
`MERGEABLE/BLOCKED` for 53 minutes until a human toggled draft→ready by hand. An
**empty** `statusCheckRollup` is the signature (a *pending* check reports an entry with
a null conclusion), and the recovery is the same draft→ready toggle
(`git::retrigger_child_check`) that the conflict path already used:

- `submodule_deliver` asserts the checks exist right after arming `--auto`, and again
  on the fallback path where auto-merge could not be enabled at all.
- the delivery poller re-fires the check after `metarepo.check_recovery.poll_rounds`
  rounds with an empty rollup, and **fails the delivery check with that diagnosis** one
  window later rather than hanging to the delivery timeout.

Note this path does **not** assume `--auto` is available: `allow_auto_merge` cannot be
enabled on a private repo under some plans, and `PATCH`ing it returns `200` while the
field stays `false`. Such a child always lands on the fallback path, so it gets the
same check assertion.

---

## Gotchas & requirements (hard-won)

1. **Secrets repo-level on the metarepo** (org `--visibility selected` may not
   propagate → empty token → `scope-missing`).
2. **Protected children must allow merge commits + auto-merge** — else delivery
   stalls silently.
3. **`AUTODUCKS_PAT` needs `read:org`** (classic) or a fine-grained PAT — else
   `gh pr create` fails resolving reviewers.
4. **`AUTODUCKS_PAT` needs `workflow` scope** to push the workflow files.
5. **Do NOT add `synchronize` to a child's CI** — it would fire on every task
   iteration. The metarepo re-triggers a child's required check **on demand** only for
   its delivery pushes (e.g. toggle `ready_for_review`), never as a blanket trigger.
6. **Concurrent features on the same child** can conflict at delivery; the roadmap is
   a **resolver-driven** conflict heal (rebase + LLM-resolve + re-pin), not
   serialization per module.

---

## Configuration reference

| Key | Values | Meaning |
|---|---|---|
| `metarepo.enabled` | bool | Master switch; forces sequential orchestration. |
| `metarepo.protected_submodule_strategy` | `auto_merge` \| `required_check` | How protected children merge. |
| `metarepo.auth.mode` | `single_pat` \| `per_owner_pat` \| `github_app` | Credential resolution. |
| `metarepo.submodules.<path>.protected` | bool \| null | `null` = detect at runtime; a bool overrides detection. |
| `metarepo.check_recovery.assert_attempts` | int | Times delivery re-checks that a child PR has any check run (default 3). |
| `metarepo.check_recovery.assert_interval_seconds` | int | Wait between those attempts (default 5). |
| `metarepo.check_recovery.poll_rounds` | int | Poll rounds with an empty rollup before the poller re-fires the check (default 2). |
| `defaults.merge_method` | `squash` \| `merge` \| `rebase` \| `auto` | Merge policy; squash re-pins on delivery. |

See `.autoducks/design/AGENTS.md` → "Metarepo mode" for the full model.
