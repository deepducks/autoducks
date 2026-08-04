#!/usr/bin/env bash
set -euo pipefail

# Git provider interface
# Sources the concrete implementation from providers/git/$AUTODUCKS_GIT_PROVIDER/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${AUTODUCKS_GIT_PROVIDER:?AUTODUCKS_GIT_PROVIDER must be set (e.g. \"github\")}"

PROVIDER_DIR="${SCRIPT_DIR}/${AUTODUCKS_GIT_PROVIDER}"

if [[ ! -d "$PROVIDER_DIR" ]]; then
  echo "ERROR: Git provider directory not found: ${PROVIDER_DIR}" >&2
  exit 1
fi

# Source all .sh files from the provider implementation directory
for f in "${PROVIDER_DIR}"/*.sh; do
  [[ -f "$f" ]] || continue
  # shellcheck source=/dev/null
  source "$f"
done

# ── Required function signatures ──────────────────────────────────────────
#
#   git::create_branch(base, name)
#   git::branch_exists(name)                         → exit code 0/1
#   git::default_branch()                             → branch name, or empty
#     The branch the host serves as HEAD, which is the copy of
#     .github/workflows/ and .autoducks/ a scheduled or dispatched run
#     executes. Not AUTODUCKS_BASE_BRANCH, which says where the pipeline cuts
#     from; a repo may legitimately set the two to different branches. Empty
#     when the host cannot answer — callers decide whether that is fatal.
#   git::create_pr(head, base, title, body, draft?)   → pr_number
#   git::merge_pr(pr_number, when?)                   → 0 ok / 2 method-not-allowed / 1 other
#     when ∈ {now, auto}, default now. `auto` asks the host to hold the merge
#     until the repo's own required checks pass, and MUST NOT fall back to
#     merging immediately: callers pass it precisely so the consumer's CI gates
#     the merge. A provider with no auto-merge equivalent must return 1 and
#     leave the PR open, never merge now — silently merging would defeat the
#     gate rather than degrade from it.
#   git::close_pr(pr_number, comment)
#   git::list_open_prs(base_branch?)                  → JSON array
#   git::list_merged_prs(base_branch)                 → JSON array
#   git::list_runs(workflow, status?)                  → JSON array
#   git::dispatch_workflow(workflow, inputs_json)
#   git::delete_branch(name)
#   git::generate_slug(id, title)                     → slug string
#   git::configure_identity()
#   git::push_branch(branch_name)
#   git::find_branches_matching(pattern)              → branch names, one per line
#   git::update_pr_body(pr_number, body)
#   git::mark_pr_ready(pr_number)
#   git::mark_pr_draft(pr_number)
#   git::get_pr(pr_number)                            → JSON object (number, title, body, state,
#                                                        isDraft, headRefName, baseRefName,
#                                                        mergeable, mergeStateStatus)
#   git::get_pr_diff(pr_number)                       → unified diff on stdout
#   git::submit_pr_review(pr_number, event, body_file) → event ∈ {COMMENT, REQUEST_CHANGES, APPROVE}
#   git::list_pr_reviews(pr_number)                    → JSON array (reviews + inline thread comments)
#   git::start_check_run(name, head_sha)              → check_run_id (status=in_progress)
#   git::conclude_check_run(check_run_id, conclusion, title, summary)
#   git::commits_ahead(base_branch)                   → integer
#
#   ── Metarepo mode (inert unless AUTODUCKS_METAREPO=true) ──
#   git::resolve_token(owner_or_slug)                 → push credential for a child
#   git::submodule_list_changed()                     → changed submodule paths, one per line
#   git::submodule_remote(path)                        → set per-child tokenized push remote
#   git::commit_push_recursive(child_branch, msg)     → children-first commit/push, then parent
#   git::submodule_deliver(path, child_branch)        → merge-time delivery for one child
#   git::verify_write_access(slug)                    → exit 0 if the child credential can push
#   git::submodule_protection(slug)                   → "true"/"false" default-branch protection
#   git::retrigger_child_check(pr_number, slug, token) → re-fire a child's required check via draft→ready toggle

REQUIRED_FUNCTIONS=(
  "git::create_branch"
  "git::branch_exists"
  "git::create_pr"
  "git::merge_pr"
  "git::close_pr"
  "git::list_open_prs"
  "git::list_merged_prs"
  "git::list_runs"
  "git::dispatch_workflow"
  "git::delete_branch"
  "git::generate_slug"
  "git::configure_identity"
  "git::push_branch"
  "git::find_branches_matching"
  "git::update_pr_body"
  "git::mark_pr_ready"
  "git::mark_pr_draft"
  "git::get_pr"
  "git::get_pr_diff"
  "git::submit_pr_review"
  "git::list_pr_reviews"
  "git::start_check_run"
  "git::conclude_check_run"
  "git::commits_ahead"
  "git::resolve_token"
  "git::submodule_list_changed"
  "git::submodule_remote"
  "git::commit_push_recursive"
  "git::submodule_deliver"
  "git::verify_write_access"
  "git::submodule_protection"
  "git::retrigger_child_check"
)

missing=0
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  if [[ "$(type -t "$fn" 2>/dev/null)" != "function" ]]; then
    echo "ERROR: Git provider '${AUTODUCKS_GIT_PROVIDER}' does not implement required function: ${fn}" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
