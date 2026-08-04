#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../config/load-config.sh"

# Re-pin open metarepo parent PRs after the default branch's gitlinks moved.
# Inert outside metarepo mode (byte-identical single-repo behaviour).
#
# Why this exists (#119b): a gitlink is an opaque SHA in the parent's tree, and
# GitHub merges it 3-way like any other blob. When two parent PRs are open at
# once, the first to merge moves the default branch's gitlink; the second still
# pins what it pinned at creation, so base and head now disagree and the PR flips
# to CONFLICTING. Nothing in the pipeline noticed. meta#108 went CONFLICTING at
# 00:42:24, four minutes after meta#97 moved main's gitlink at 00:38:43 — and
# both were repaired by hand.
#
# Two events move those gitlinks and both run this: a parent PR merging
# (`repin-siblings`) and a direct push to the default branch
# (`repin-on-base-push`). Only the first carries a PR to exclude.
#
# The reconcile itself only ever fast-forwards (see metarepo::reconcile_gitlinks
# and metarepo::pin_relation) — a pin that is ahead of, or diverged from, the
# child's default branch is reported and left for a human.
#
# Required env: REPO.
# Optional env: MERGED_PR_NUM — the PR that just merged, excluded from the pass.
# Empty (the direct-push case) means every open parent PR is a candidate.

metarepo::enabled || exit 0

: "${REPO:?REPO env var required}"

log() { echo "[repin-open-parent-prs] $*" >&2; }
notice() { echo "::notice::repin-open-parent-prs: $*"; }

MERGED_PR_NUM="${MERGED_PR_NUM:-}"

# Open PRs that carry the delivered-children marker are exactly the parent
# delivery PRs whose gitlinks this move may have staled. `--state open` already
# excludes a PR that just merged, but filter on the number too so a stale list
# cannot make us re-pin it. An empty MERGED_PR_NUM excludes nothing.
PRS_JSON="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,headRefName,body,isCrossRepository 2>/dev/null || echo '[]')"

mapfile -t TARGETS < <(jq -r --arg skip "$MERGED_PR_NUM" '
  .[]
  | select((.number | tostring) != $skip)
  | select(.isCrossRepository != true)
  | select((.body // "") | test("<!-- autoducks:delivered-children:"))
  | "\(.number)\t\(.headRefName)"' <<<"$PRS_JSON" 2>/dev/null || true)

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  notice "no other open parent delivery PR to reconcile"
  exit 0
fi

RC=0
for entry in "${TARGETS[@]}"; do
  [[ -n "$entry" ]] || continue
  pr_num="${entry%%$'\t'*}"
  head_ref="${entry#*$'\t'}"
  [[ -n "$head_ref" ]] || continue

  if ! git ls-remote --exit-code --heads origin "$head_ref" >/dev/null 2>&1; then
    log "PR #$pr_num head branch '$head_ref' no longer exists on the remote — skipping"
    continue
  fi

  body="$(jq -r --arg n "$pr_num" '.[] | select((.number|tostring) == $n) | .body // ""' <<<"$PRS_JSON")"
  mapfile -t children < <(metarepo::delivered_children_from_body "$body")
  if [[ "${#children[@]}" -eq 0 ]]; then
    log "PR #$pr_num declares no delivered children — skipping"
    continue
  fi

  notice "reconciling gitlinks on PR #$pr_num ($head_ref): ${children[*]}"
  metarepo::reconcile_gitlinks "$head_ref" "${children[@]}" || { RC=1; log "reconcile failed for PR #$pr_num"; }
done

exit "$RC"
