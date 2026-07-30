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
# STDOUT contract (single line):
#   "<pin_sha> <needs_repin:0|1> <needs_resolve:0|1> <child_pr_num>"
#   pin_sha       = the SHA the parent gitlink should point at after delivery
#   needs_repin   = 1 when the SHA was rewritten (squash/rebase) and the feature
#                   branch was RETAINED for safety (caller must re-pin, then delete it)
#   needs_resolve = 1 when a protected child's delivery PR is CONFLICTING (or
#                   persistently behind its base) — the PR is left open, UNMERGED,
#                   and child_pr_num names it so the caller (deliver_children) can
#                   run the resolver on it. Defaults to 0 on every other path.
#   child_pr_num  = the child delivery PR number when needs_resolve=1, else empty.
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

# Poll a child PR's mergeability (under the child's resolved token) with backoff,
# mirroring resolver_wait_for_mergeable (resolver/pre.sh) — GitHub computes
# `mergeable` asynchronously. Prints "<mergeable> <mergeStateStatus>" — a
# persistent UNKNOWN (both fields) after max_attempts falls through rather than
# blocking delivery.
git::_child_wait_for_mergeable() {
  local slug="$1" pr_num="$2" token="$3"
  local max_attempts="${4:-10}" sleep_seconds="${5:-3}"
  local json mergeable state
  for ((i = 1; i <= max_attempts; i++)); do
    json="$(GH_TOKEN="$token" gh pr view "$pr_num" --repo "$slug" --json mergeable,mergeStateStatus 2>/dev/null || echo '{}')"
    mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$json")"
    state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$json")"
    if [[ "$mergeable" == "MERGEABLE" || "$mergeable" == "CONFLICTING" ]]; then
      echo "$mergeable $state"; return 0
    fi
    echo "::notice::submodule_deliver: waiting for PR #$pr_num mergeability on $slug to resolve (attempt $i/$max_attempts, currently ${mergeable:-UNKNOWN}/${state:-UNKNOWN})..." >&2
    sleep "$sleep_seconds"
  done
  echo "${mergeable:-UNKNOWN} ${state:-UNKNOWN}"
}

# Open (or find) the marked child PR for child_branch → default_branch.
git::_child_default_tip() {
  local slug="$1" default_branch="$2" token="$3"
  GH_TOKEN="$token" gh api "repos/$slug/commits/$default_branch" --jq '.sha' 2>/dev/null || true
}

# git::_child_pin_after_merge SLUG DEFAULT_BRANCH TOKEN FEAT_SHA → "<pin> <needs_repin>"
#
# The parent gitlink must pin the child's default-branch *tip*, not the tip of
# the delivered feature branch. Delivery used to return $feat_sha on the grounds
# that a merge commit keeps it reachable from the default branch — but
# reachability is not the property that governs merging the parent PR. A gitlink
# is an opaque SHA in the tree, and GitHub's 3-way merge compares base/ours/
# theirs literally: once main's gitlink moves, a parent PR still pinning the
# feature tip conflicts whether or not that SHA is reachable. Both parent PRs of
# the 2026-07-29 incident went CONFLICTING this way (#119a).
#
# Falls back to the feature tip only when the default-branch tip cannot be read,
# which is no worse than the old behaviour. needs_repin=1 tells maestro to bump
# the parent gitlink on the feature branch before the final PR is created.
git::_child_pin_after_merge() {
  local slug="$1" default_branch="$2" token="$3" feat_sha="$4"
  local tip; tip="$(git::_child_default_tip "$slug" "$default_branch" "$token")"
  if [[ -z "$tip" ]]; then
    echo "::warning::submodule_deliver: could not read $slug $default_branch tip — pinning the delivered feature tip $feat_sha instead." >&2
    echo "$feat_sha 0"; return 0
  fi
  if [[ "$tip" == "$feat_sha" ]]; then echo "$feat_sha 0"; return 0; fi
  echo "$tip 1"
}

# git::_child_has_checks SLUG PR_NUM TOKEN → 0 when the PR has at least one
# check-run/status entry. "No checks at all" is the signature of a PR whose
# creation event produced no workflow run (#119c) — distinct from "checks are
# pending", which reports entries with a null conclusion.
git::_child_has_checks() {
  local slug="$1" pr_num="$2" token="$3" n
  n="$(GH_TOKEN="$token" gh pr view "$pr_num" --repo "$slug" --json statusCheckRollup \
        --jq '[.statusCheckRollup[]?] | length' 2>/dev/null || echo 0)"
  [[ "${n:-0}" -gt 0 ]]
}

# git::_child_assert_checks SLUG PR_NUM TOKEN — auto-merge only ever fires once
# the required checks report, so arming `--auto` on a PR that has no checks at
# all leaves it BLOCKED forever. GitHub intermittently drops the `opened` event
# (autoducks#1121 sat 53 minutes with zero runs until a human toggled it), so
# verify rather than trust, and re-fire the check with the draft→ready toggle
# when nothing materialises (#119c).
git::_child_assert_checks() {
  local slug="$1" pr_num="$2" token="$3"
  local attempts="${AUTODUCKS_CHECK_ASSERT_ATTEMPTS:-3}"
  local delay="${AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS:-5}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    git::_child_has_checks "$slug" "$pr_num" "$token" && return 0
    (( i < attempts )) && sleep "$delay"
  done
  echo "::warning::submodule_deliver: child PR #$pr_num on $slug has no check runs after ${attempts} attempts — re-firing its required check via a draft→ready toggle (#119c)." >&2
  git::retrigger_child_check "$pr_num" "$slug" "$token" \
    || echo "::warning::submodule_deliver: could not re-trigger the required check on $slug PR #$pr_num — the delivery poller will retry." >&2
  return 1
}

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
  [[ -n "$slug" ]] || { echo "::notice::submodule_deliver: $path has no GitHub slug (offline) — skipping API delivery." >&2; echo " 0 0 "; return 0; }

  local token; token="$(git::resolve_token "$slug")"
  local default_branch
  default_branch="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  local protected; protected="$(git::submodule_protection "$slug")"
  local method; method="$(git::_child_delivery_method "$slug" "$token")"

  local feat_sha
  feat_sha="$(GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" --jq '.object.sha' 2>/dev/null || true)"
  if [[ -z "$feat_sha" ]]; then
    echo "::warning::submodule_deliver: $slug has no branch $child_branch to deliver." >&2
    echo " 0 0 "; return 0
  fi

  local pin repin
  # ── Unprotected + SHA-preserving method: fast-forward, else merge commit ──
  if [[ "$protected" != "true" && "$method" == "merge" ]]; then
    if GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$default_branch" \
         -X PATCH -f "sha=$feat_sha" -F "force=false" --silent 2>/dev/null; then
      GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" -X DELETE --silent 2>/dev/null || true
      echo "::notice::submodule_deliver: fast-forwarded $slug $default_branch → $feat_sha and deleted $child_branch." >&2
      read -r pin repin <<< "$(git::_child_pin_after_merge "$slug" "$default_branch" "$token" "$feat_sha")"
      echo "$pin $repin 0 "; return 0
    fi
    # Not a fast-forward (default branch moved on a divergent line) — fall back to
    # a MERGE COMMIT via the merges API. The merge commit, not the feature tip, is
    # what the parent must pin: a merely-reachable SHA still conflicts once main's
    # gitlink moves (#119a), so re-read the resulting tip and ask for a re-pin.
    local merge_rc=0
    GH_TOKEN="$token" gh api "repos/$slug/merges" -f "base=$default_branch" -f "head=$child_branch" \
      -f "commit_message=Autoducks metarepo delivery: merge $child_branch" --silent 2>/dev/null || merge_rc=$?
    if [[ "$merge_rc" -eq 0 ]]; then
      GH_TOKEN="$token" gh api "repos/$slug/git/refs/heads/$child_branch" -X DELETE --silent 2>/dev/null || true
      read -r pin repin <<< "$(git::_child_pin_after_merge "$slug" "$default_branch" "$token" "$feat_sha")"
      echo "::notice::submodule_deliver: $default_branch of $slug had diverged — merged $child_branch via a merge commit and pinned the resulting $default_branch tip $pin." >&2
      echo "$pin $repin 0 "; return 0
    fi
    echo "::warning::submodule_deliver: could not fast-forward or merge $slug $default_branch ← $child_branch (conflict?). Left $child_branch in place." >&2
    echo " 0 0 "; return 1
  fi

  # ── Everything else goes through a marked PR (protected, or squash/rebase policy) ──
  local pr_num; pr_num="$(git::_child_delivery_pr "$slug" "$default_branch" "$child_branch" "$token")"
  [[ -n "$pr_num" ]] || { echo "::warning::submodule_deliver: could not open a child PR on $slug for $child_branch." >&2; echo " 0 0 "; return 1; }

  # Under strategy=required_check, an UNPROTECTED child (squash/rebase policy)
  # is left for the bridge — the poller stays read-only and does not merge on
  # our behalf. A PROTECTED child still needs GitHub auto-merge enabled below
  # so it merges once the required checks (including the delivery check) pass;
  # skipping that would leave every protected child PR stuck open forever.
  if [[ "${AUTODUCKS_METAREPO_STRATEGY:-auto_merge}" != "auto_merge" && "$protected" != "true" ]]; then
    echo "::notice::submodule_deliver: opened child PR #$pr_num on $slug (strategy=required_check — left for the bridge)." >&2
    echo "$feat_sha 0 0 "; return 0
  fi

  # ── Protected child: merge commit + auto-merge-when-ready ──
  # A protected default branch usually gates on required checks that only pass
  # after the PR opens, so an immediate merge fails. Enable GitHub auto-merge
  # (--auto) with a MERGE COMMIT: GitHub merges once the checks pass. This is why
  # protected delivery always uses a merge commit and ignores a squash/rebase
  # merge_method (which would rewrite the SHA under an async merge, leaving
  # nothing to re-pin synchronously). This applies for both auto_merge and
  # required_check strategies, since the delivery check itself is what gates the
  # merge under required_check.
  #
  # The merge is asynchronous, so the SHA the parent must ultimately pin — the
  # default-branch tip after the merge lands — is not knowable here. The pin
  # returned below is therefore provisional; the delivery poller reconciles the
  # parent PR's gitlink to the real tip once the child PR reports MERGED (#119a).
  if [[ "$protected" == "true" ]]; then
    # Poll mergeability under the child token before arming auto-merge — a
    # CONFLICTING (or persistently behind-base) delivery PR must NOT be
    # force-merged; report it back for the resolver instead.
    local mergeable_state mergeable merge_state_status
    mergeable_state="$(git::_child_wait_for_mergeable "$slug" "$pr_num" "$token")"
    read -r mergeable merge_state_status <<< "$mergeable_state"
    if [[ "$mergeable" == "CONFLICTING" || ( "$mergeable" == "UNKNOWN" && "$merge_state_status" == "BEHIND" ) ]]; then
      echo "::warning::submodule_deliver: protected child PR #$pr_num on $slug is $mergeable/$merge_state_status — leaving it open for conflict resolution." >&2
      echo "$feat_sha 0 1 $pr_num"; return 0
    fi
    if GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --merge --auto --delete-branch 2>/dev/null; then
      echo "::notice::submodule_deliver: enabled auto-merge (merge commit) on protected child PR #$pr_num on $slug — merges when required checks pass." >&2
      # Auto-merge is only as good as the checks it waits on: verify they exist
      # rather than assuming the PR's creation event produced a run (#119c).
      git::_child_assert_checks "$slug" "$pr_num" "$token" || true
      echo "$feat_sha 0 0 "; return 0
    fi
    # Repo may disallow auto-merge — try an immediate merge commit (works when no
    # required checks are pending). That merge IS synchronous, so pin its result.
    if GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --merge --delete-branch 2>/dev/null; then
      read -r pin repin <<< "$(git::_child_pin_after_merge "$slug" "$default_branch" "$token" "$feat_sha")"
      echo "::notice::submodule_deliver: merged protected child PR #$pr_num on $slug via merge commit — pinned $default_branch tip $pin." >&2
      echo "$pin $repin 0 "; return 0
    fi
    echo "::warning::submodule_deliver: opened protected child PR #$pr_num on $slug but could not enable auto-merge or merge it (required checks pending, or merge/auto-merge disabled). PR left open; the pinned SHA stays reachable via the retained branch." >&2
    # This is the private-repo reality: `allow_auto_merge` cannot be turned on
    # under the current plan, and PATCHing it returns 200 while the field stays
    # false — so a child like autoducks-api always lands here. Nothing will merge
    # this PR on its own, which makes a required check that never materialised
    # doubly invisible. Assert the checks here too, so at least the human who
    # picks it up sees a real check state instead of an empty rollup (#119c).
    git::_child_assert_checks "$slug" "$pr_num" "$token" || true
    echo "$feat_sha 0 0 "; return 0
  fi

  # ── Unprotected + squash/rebase policy: PR + method + re-pin ──
  case "$method" in
    merge)
      # (Unprotected + merge was already handled by the FF/merges-API path above.)
      if GH_TOKEN="$token" gh pr merge "$pr_num" --repo "$slug" --merge --delete-branch 2>/dev/null; then
        read -r pin repin <<< "$(git::_child_pin_after_merge "$slug" "$default_branch" "$token" "$feat_sha")"
        echo "::notice::submodule_deliver: merged child PR #$pr_num on $slug via merge commit — pinned $default_branch tip $pin." >&2
        echo "$pin $repin 0 "; return 0
      fi
      echo "::warning::submodule_deliver: merge-commit auto-merge of PR #$pr_num on $slug failed." >&2
      echo " 0 0 "; return 1
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
          echo "$new_sha 1 0 "; return 0
        fi
      fi
      echo "::warning::submodule_deliver: ${method} auto-merge of PR #$pr_num on $slug failed." >&2
      echo " 0 0 "; return 1
      ;;
    *)
      echo "::warning::submodule_deliver: unknown delivery method '$method' for $slug." >&2
      echo " 0 0 "; return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_deliver SUBMODULE_PATH CHILD_BRANCH"; echo "  Deliver a child submodule at merge time. Prints '<pin_sha> <needs_repin> <needs_resolve> <child_pr_num>'."; echo "  pin_sha is the child's default-branch tip after delivery — NOT the feature tip (#119a)."; echo "  Method: AUTODUCKS_MERGE_METHOD (merge|squash|rebase|auto)."; echo "  needs_repin=1: the tip differs from the delivered feature tip, so the parent gitlink must be bumped."; echo "  needs_resolve=1 + child_pr_num: a protected child's delivery PR is CONFLICTING and was left open."; echo "  Async auto-merge cannot know the final tip; the delivery poller reconciles the pin instead."; exit 0 ;;
  esac
fi
