# Metarepo (submodule aggregation)

Run the full autoducks pipeline from a private **metarepo** that aggregates related
repos as git submodules (e.g. `autoducks`, `autoducks-docs`, `autoducks-cli`,
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
    "child-a": { "external_cycle": true,  "protected": null },  // public, own cycle
    "child-b": { "external_cycle": false, "protected": null }   // private, meta-only
  }
},
"orchestrator": { "mode": "sequential" },
"defaults": { "merge_method": "squash", "model": "claude-sonnet-5", "effort": "high" }
```

- `protected: null` → detected at runtime from the child's branch protection.
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
parent task branch carries only **gitlink bumps**. Execution is **backpressured
(sequential, max-in-flight = 1)**: each task branches off the *merged* result of the
previous one, so the gitlink only moves forward (no write-race). The **Engineer** tags
each task's `**Modules:**` with the submodule path(s) it changes and orders
inter-module dependencies as wave edges; the **Developer** edits only inside the
declared submodule directories (never the metarepo's own `.autoducks/`).

**Delivery (children-first, parent-last).** At feature completion, before the parent
final PR:

- **Unprotected child** → fast-forward its default branch to the child feature head
  (or a merge-commit fallback if it diverged); `squash` policy rewrites the SHA →
  the parent gitlink is **re-pinned**.
- **Protected child** → open a marked PR and **merge-commit + auto-merge-when-ready**
  (merges when required checks pass; SHA preserved, no re-pin).

The human merges the parent last. A **skip-marker** (`<!-- autoducks:metarepo-managed
-->`) on child PRs keeps the child's own reviewer/rework/commit-lint dormant.

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
| `metarepo.submodules.<path>.external_cycle` | bool | Child has its own feature cycle (public OSS). |
| `metarepo.submodules.<path>.protected` | bool \| null | `null` = detect at runtime. |
| `defaults.merge_method` | `squash` \| `merge` \| `rebase` \| `auto` | Merge policy; squash re-pins on delivery. |

See `.autoducks/design/AGENTS.md` → "Metarepo mode" for the full model.
