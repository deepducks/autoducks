#!/usr/bin/env bash
set -euo pipefail

# Delete the child feature branches a parent pipeline created, at the moment
# that pipeline actually ends: the parent PR closing.
#
# The parent's Developer creates the mirrored branch in each declared child, so
# the parent owns its lifetime. Delivery used to delete it as soon as the child
# PR merged, which is much earlier than the end of the pipeline: the parent PR
# is still open then, and its review loop can still dispatch rework/fix rounds
# that need a child branch to commit onto. Those rounds found none, fell back to
# the child's default branch, and were rejected by branch protection *after* a
# full agent run — or, on an unprotected child, silently pushed rework commits
# onto its trunk (#182).
#
# Safety rule: only delete a child branch whose tip is already contained in the
# child's default branch. That is the definition of "delivered", and it is the
# only state in which deleting loses nothing. A branch that is ahead (delivery
# never ran, or an async auto-merge is still pending) is kept and reported —
# an unmerged parent PR is exactly when that case shows up, and dropping the
# work there would be the expensive mistake this file exists to prevent.

cleanup_child_branches() {
  local feature_branch="$1"
  local path slug default branch_tip default_tip relation
  local deleted=0 kept=0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
    [[ -n "$slug" ]] || continue

    local token; token="$(git::resolve_token "$slug" 2>/dev/null || true)"

    default="$(metarepo::child_default_branch "$path")"
    if [[ "$feature_branch" == "$default" ]]; then
      echo "::warning::cleanup-child-branches: refusing to delete '$default' on $slug — that is the child's default branch, not a pipeline branch." >&2
      continue
    fi

    branch_tip="$(GH_TOKEN="$token" gh api "repos/$slug/git/ref/heads/${feature_branch}" --jq '.object.sha' 2>/dev/null || true)"
    [[ -n "$branch_tip" ]] || continue   # already gone, or never existed for this child

    default_tip="$(GH_TOKEN="$token" gh api "repos/$slug/git/ref/heads/${default}" --jq '.object.sha' 2>/dev/null || true)"
    if [[ -z "$default_tip" ]]; then
      echo "::warning::cleanup-child-branches: could not read '$default' tip on $slug — keeping $feature_branch rather than deleting on an unknown state." >&2
      kept=$((kept + 1))
      continue
    fi

    relation="$(metarepo::pin_relation "$slug" "$branch_tip" "$default_tip")"
    case "$relation" in
      identical|behind)
        if GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/${feature_branch}" -X DELETE --silent 2>/dev/null; then
          echo "::notice::cleanup-child-branches: deleted $feature_branch on $slug (delivered — tip is contained in $default)." >&2
          deleted=$((deleted + 1))
        else
          echo "::warning::cleanup-child-branches: could not delete $feature_branch on $slug." >&2
          kept=$((kept + 1))
        fi
        ;;
      *)
        echo "::warning::cleanup-child-branches: keeping $feature_branch on $slug — its tip is $relation relative to $default, so it holds work that was never delivered. Deleting it would lose that work." >&2
        kept=$((kept + 1))
        ;;
    esac
  done < <(metarepo::submodule_paths)

  echo "::notice::cleanup-child-branches: $feature_branch — deleted=$deleted kept=$kept" >&2
}

# Entrypoint: invoked as a workflow step with FEATURE_BRANCH in the environment.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help)
      echo "Usage: FEATURE_BRANCH=<branch> REPO=<owner/repo> cleanup-child-branches.sh"
      echo "  Delete delivered child feature branches after the parent PR closes (metarepo mode)"
      exit 0
      ;;
  esac

  source "$(dirname "${BASH_SOURCE[0]}")/../config/load-config.sh"

  metarepo::enabled || { echo "cleanup-child-branches: not a metarepo — nothing to do"; exit 0; }

  FEATURE_BRANCH="${FEATURE_BRANCH:?FEATURE_BRANCH env var required}"
  cleanup_child_branches "$FEATURE_BRANCH"
fi
