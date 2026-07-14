#!/usr/bin/env bash
set -euo pipefail

# git::submodule_deliver(path, child_branch) — merge-time delivery for one child,
# run by Maestro *before* the parent merges (HANDOFF push order + retention).
# All API calls use the child's resolved credential, never the global GH_TOKEN.
#
# The parent gitlink pins the child *feature-branch* HEAD (Y). Delivery integrates
# Y into the child's default branch, honoring the configured merge method:
#
#   fast-forward / merge commit → Y stays reachable from the default branch
#                                  (FF makes main==Y; merge makes Y an ancestor),
#                                  so the pin needs no change.
#   squash / rebase            → the child's history is rewritten to a NEW commit
#                                  S (Y is not an ancestor of S). To keep the pin
#                                  valid the parent gitlink must be RE-POINTED to S
#                                  — the caller (deliver_children) does that, then
#                                  deletes the now-unreferenced feature branch.
#
# Honors AUTODUCKS_MERGE_METHOD (merge|squash|rebase|auto). "auto" prefers a merge
# commit for children (SHA-preserving → no re-pin), falling back to whatever the
# child repo allows.
#
# STDOUT contract (single line): "<pin_sha> <needs_repin:0|1>"
#   pin_sha     = the SHA the parent gitlink should point at after delivery
#   needs_repin = 1 when the SHA was rewritten (squash/rebase) and the feature
#                 branch was RETAINED for safety (caller must re-pin, then delete it)
# All human-facing notices go to stderr. Offline children print "" and return 0.

# Resolve the delivery merge method for a child repo. Honors AUTODUCKS_MERGE_METHOD;
# on "auto", prefers merge (keeps the pinned SHA stable), then squash, then rebase.
git::_child_delivery_method() {
  local slug="$1" token="$2"
  local configured="${AUTODUCKS_MERGE_METHOD:-auto}"
  if [[ -n "$configured" && "$configured" != "auto" ]]; then
    echo "$configured"; return 0
  fi
  local allowed
  allowed="$(GH_TOKEN="$token" gh api "repos/$slug" 2>/dev/null || echo '{}')"
  if   [[ "$(jq -r '.allow_merge_commit  // false' <<<"$allowed")" == "true" ]]; then echo merge
  elif [[ "$(jq -r '.allow_squash_merge  // false' <<<"$allowed")" == "true" ]]; then echo squash
  elif [[ "$(jq -r '.allow_rebase_merge  // false' <<<"$allowed")" == "true" ]]; then echo rebase
  else echo merge; fi
}

# Open (or find) the marked child PR for child_branch → default_branch.
git::_child_delivery_pr() {
  local slug="$1" default_branch="$2" child_branch="$3" token="$4"
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
  [[ -n "$pr_num" && "$pr_num" != "null" ]] && echo "$pr_num"
}

git::submodule_deliver() {
  local path="$1" child_branch="$2"
  local slug; slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
  [[ -n "$slug" ]] || { echo "::notice::submodule_deliver: $path has no GitHub slug (offline) — skipping API delivery." >&2; echo " 0"; return 0; }

  local token; token="$(git::resolve_token "$slug")"
  local default_branch
  default_branch="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  local protected; protected="$(git::submodule_protection "$slug")"
  local method; method="$(git::_child_delivery_method "$slug" "$token")"

  local feat_sha
  feat_sha="$(GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" --jq '.object.sha' 2>/dev/null || true)"
  if [[ -z "$feat_sha" ]]; then
    echo "::warning::submodule_deliver: $slug has no branch $child_branch to deliver." >&2
    echo " 0"; return 0
  fi

  # ── Unprotected + SHA-preserving method: fast-forward, else merge commit ──
  if [[ "$protected" != "true" && "$method" == "merge" ]]; then
    if GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$default_branch" \
         -X PATCH -f "sha=$feat_sha" -F "force=false" --silent 2>/dev/null; then
      GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" -X DELETE --silent 2>/dev/null || true
      echo "::notice::submodule_deliver: fast-forwarded $slug $default_branch → $feat_sha and deleted $child_branch." >&2
      echo "$feat_sha 0"; return 0
    fi
    # Not a fast-forward (default branch moved on a divergent line) — fall back to
    # a MERGE COMMIT via the merges API, which keeps feat_sha reachable as a parent
    # (no re-pin needed). This is the retention-safe alternative to force-pushing.
    local merge_rc=0
    GH_TOKEN="$token" gh api "repos/$slug/merges" -f "base=$default_branch" -f "head=$child_branch" \
      -f "commit_message=Autoducks metarepo delivery: merge $child_branch" --silent 2>/dev/null || merge_rc=$?
    if [[ "$merge_rc" -eq 0 ]]; then
      GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" -X DELETE --silent 2>/dev/null || true
      echo "::notice::submodule_deliver: $default_branch of $slug had diverged — merged $child_branch via a merge commit (feat SHA reachable) and deleted the branch." >&2
      echo "$feat_sha 0"; return 0
    fi
    echo "::warning::submodule_deliver: could not fast-forward or merge $slug $default_branch ← $child_branch (conflict?). Left $child_branch in place." >&2
    echo " 0"; return 1
  fi

  # ── Everything else goes through a marked PR (protected, or squash/rebase policy) ──
  local pr_num; pr_num="$(git::_child_delivery_pr "$slug" "$default_branch" "$child_branch" "$token")"
  [[ -n "$pr_num" ]] || { echo "::warning::submodule_deliver: could not open a child PR on $slug for $child_branch." >&2; echo " 0"; return 1; }

  if [[ "${AUTODUCKS_METAREPO_STRATEGY:-auto_merge}" != "auto_merge" ]]; then
    echo "::notice::submodule_deliver: opened child PR #$pr_num on $slug (strategy=required_check — left for the bridge)." >&2
    echo "$feat_sha 0"; return 0
  fi

  case "$method" in
    merge)
      # Merge commit keeps feat_sha reachable → no re-pin; safe to delete the branch.
      if GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --merge --delete-branch 2>/dev/null; then
        echo "::notice::submodule_deliver: merged child PR #$pr_num on $slug via merge commit (feat SHA reachable on $default_branch)." >&2
        echo "$feat_sha 0"; return 0
      fi
      echo "::warning::submodule_deliver: merge-commit auto-merge of PR #$pr_num on $slug failed." >&2
      echo " 0"; return 1
      ;;
    squash|rebase)
      # Squash/rebase REWRITE the SHA. Merge WITHOUT deleting the branch (so feat_sha
      # stays reachable until the parent gitlink is re-pointed), then report the new
      # default-branch HEAD as the SHA to re-pin. The caller deletes the branch after
      # a successful re-pin.
      if GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --"$method" 2>/dev/null; then
        local new_sha
        new_sha="$(GH_TOKEN="$token" gh api "repos/$slug/commits/$default_branch" --jq '.sha' 2>/dev/null || true)"
        if [[ -n "$new_sha" ]]; then
          echo "::notice::submodule_deliver: ${method}-merged child PR #$pr_num on $slug → $new_sha; parent gitlink will be re-pinned (branch retained until then)." >&2
          echo "$new_sha 1"; return 0
        fi
      fi
      echo "::warning::submodule_deliver: ${method} auto-merge of PR #$pr_num on $slug failed." >&2
      echo " 0"; return 1
      ;;
    *)
      echo "::warning::submodule_deliver: unknown delivery method '$method' for $slug." >&2
      echo " 0"; return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_deliver SUBMODULE_PATH CHILD_BRANCH"; echo "  Deliver a child submodule at merge time. Prints '<pin_sha> <needs_repin>'."; echo "  Method: AUTODUCKS_MERGE_METHOD (merge|squash|rebase|auto). Squash/rebase re-pin the gitlink."; exit 0 ;;
  esac
fi
