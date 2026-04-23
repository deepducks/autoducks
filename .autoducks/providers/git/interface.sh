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
#   git::create_pr(head, base, title, body)           → pr_number
#   git::merge_pr(pr_number)
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
