#!/usr/bin/env bash
set -euo pipefail

# git::submodule_deliver(path, child_branch) — merge-time delivery for one child,
# run by Maestro *before* the parent merges (HANDOFF push order + retention).
# All API calls use the child's resolved credential, never the global GH_TOKEN.
#
# Unprotected default branch → fast-forward it to the child feature branch head,
#   then delete the feature branch (the SHA now lives on the default branch, so
#   the pinned gitlink stays reachable).
# Protected default branch → open a child PR carrying the skip-marker (so the
#   child's own reviewer/rework/commit-lint stay dormant); auto_merge it (default)
#   or leave it for a required_check bridge.
#
# Offline / non-GitHub children (no slug) are advanced locally by the caller's
# recursive push and need no API work here.
git::submodule_deliver() {
  local path="$1" child_branch="$2"
  local slug; slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
  [[ -n "$slug" ]] || { echo "::notice::submodule_deliver: $path has no GitHub slug (offline) — skipping API delivery." >&2; return 0; }

  local token; token="$(git::resolve_token "$slug")"
  local default_branch
  default_branch="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"

  local protected; protected="$(git::submodule_protection "$slug")"

  if [[ "$protected" != "true" ]]; then
    # ── Unprotected: fast-forward default branch to the feature head ──
    local head_sha
    head_sha="$(GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" --jq '.object.sha' 2>/dev/null || true)"
    if [[ -z "$head_sha" ]]; then
      echo "::warning::submodule_deliver: $slug has no branch $child_branch to deliver." >&2
      return 0
    fi
    if GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$default_branch" \
         -X PATCH -f "sha=$head_sha" -F "force=false" --silent 2>/dev/null; then
      # SHA is now on the default branch → safe to delete the feature branch.
      GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" -X DELETE --silent 2>/dev/null || true
      echo "::notice::submodule_deliver: advanced $slug $default_branch → $head_sha and deleted $child_branch." >&2
    else
      echo "::warning::submodule_deliver: could not fast-forward $slug $default_branch to $head_sha (not a fast-forward?). Left $child_branch in place." >&2
      return 1
    fi
    return 0
  fi

  # ── Protected: open a marked child PR, optionally auto-merge ──
  local body="Autoducks metarepo delivery: merging \`$child_branch\` into \`$default_branch\`.

${AUTODUCKS_METAREPO_MARKER:-<!-- autoducks:metarepo-managed -->}"
  local pr_num
  pr_num="$(GH_TOKEN="$token" gh pr create --repo "$slug" \
      --base "$default_branch" --head "$child_branch" \
      --title "Autoducks: deliver $child_branch" --body "$body" 2>&1 \
      | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
  if [[ -z "$pr_num" ]]; then
    pr_num="$(GH_TOKEN="$token" gh pr list --repo "$slug" --head "$child_branch" --base "$default_branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  fi
  [[ -n "$pr_num" && "$pr_num" != "null" ]] || { echo "::warning::submodule_deliver: could not open a child PR on $slug for $child_branch." >&2; return 1; }

  if [[ "${AUTODUCKS_METAREPO_STRATEGY:-auto_merge}" == "auto_merge" ]]; then
    # Metarepo feature review already passed; merge the child PR directly.
    GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --squash --delete-branch 2>/dev/null \
      || GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --merge --delete-branch 2>/dev/null \
      || { echo "::warning::submodule_deliver: opened child PR #$pr_num on $slug but auto-merge failed." >&2; return 1; }
    echo "::notice::submodule_deliver: merged protected child PR #$pr_num on $slug." >&2
  else
    echo "::notice::submodule_deliver: opened child PR #$pr_num on $slug (strategy=required_check — left for the bridge)." >&2
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_deliver SUBMODULE_PATH CHILD_BRANCH"; echo "  Deliver a child submodule at merge time (advance main or open+merge protected PR)"; exit 0 ;;
  esac
fi
