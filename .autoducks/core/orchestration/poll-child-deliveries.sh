#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../config/load-config.sh"

# Poll each protected metarepo child's delivery PR to completion, driving the
# AUTODUCKS_DELIVERY_CHECK_NAME check-run on the parent's final PR. Inert
# outside metarepo mode (byte-identical single-repo behavior).
#
# Read-only w.r.t. the children: the only side effect is the check-run
# (start/conclude) — no merge, push, or comment. No workflow-local cache/state
# either, so the conclusion is a pure function of current child-PR state and a
# re-run (e.g. on `synchronize`) simply re-derives it.
#
# Required env: REPO (parent slug), PR_NUM (parent's final PR number),
# PR_HEAD_SHA (github.event.pull_request.head.sha) — the check-run is
# attached to this commit. The affected children and the feature-branch name
# used to find each child's delivery PR are both re-derived from the PR
# itself (git::get_pr), not trusted from a possibly-stale event payload.

metarepo::enabled || exit 0

: "${REPO:?REPO env var required}"
: "${PR_NUM:?PR_NUM env var required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA env var required}"

log() { echo "[poll-child-deliveries] $*" >&2; }
notice() { echo "::notice::poll-child-deliveries: $*"; }
step_summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY" || true; }

CHECK_RUN_ID="$(git::start_check_run "$AUTODUCKS_DELIVERY_CHECK_NAME" "$PR_HEAD_SHA" 2>/dev/null || true)"
if [[ -z "$CHECK_RUN_ID" ]]; then
  log "could not create check-run '$AUTODUCKS_DELIVERY_CHECK_NAME' on $PR_HEAD_SHA"
  exit 1
fi

PR_META_JSON="$(git::get_pr "$PR_NUM" 2>/dev/null || echo '{}')"
PR_BODY="$(jq -r '.body // ""' <<<"$PR_META_JSON")"
PR_HEAD="$(jq -r '.headRefName // ""' <<<"$PR_META_JSON")"

mapfile -t AFFECTED < <(metarepo::delivered_children_from_body "$PR_BODY")

# ── Filter to protected children — only they need gating; an unprotected
# child was already advanced synchronously by submodule_deliver. ──────────
declare -a PROTECTED_PATHS=()
declare -A CHILD_SLUG=()
for m in "${AFFECTED[@]}"; do
  [[ -z "$m" ]] && continue
  slug="$(metarepo::slug_for_path "$m" 2>/dev/null || true)"
  [[ -n "$slug" ]] || continue
  [[ "$(git::submodule_protection "$slug")" == "true" ]] || continue
  PROTECTED_PATHS+=("$m")
  CHILD_SLUG["$m"]="$slug"
done

if [[ "${#PROTECTED_PATHS[@]}" -eq 0 ]]; then
  git::conclude_check_run "$CHECK_RUN_ID" success "No protected children to poll" \
    "No affected submodule has a protected default branch — nothing to wait on." || true
  exit 0
fi

# ── Resolve each protected child's delivery PR (opened by submodule_deliver
# at merge time, before this final PR exists/updates). ─────────────────────
declare -A CHILD_PR=()
declare -A CHILD_URL=()
resolve_child_pr() {
  local m="$1" slug="$2" token num
  token="$(git::resolve_token "$slug")"
  num="$(GH_TOKEN="$token" gh pr list --repo "$slug" --head "$PR_HEAD" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  [[ -n "$num" ]] || return 0
  CHILD_PR["$m"]="$num"
  CHILD_URL["$m"]="https://github.com/$slug/pull/$num"
}
for m in "${PROTECTED_PATHS[@]}"; do
  resolve_child_pr "$m" "${CHILD_SLUG[$m]}"
done

render_summary() {
  local m
  for m in "${PROTECTED_PATHS[@]}"; do
    if [[ -n "${CHILD_PR[$m]:-}" ]]; then
      echo "- \`$m\` → ${CHILD_URL[$m]}"
    else
      echo "- \`$m\` → no delivery PR found yet (${CHILD_SLUG[$m]}, branch \`$PR_HEAD\`)"
    fi
  done
}

# Defensively bound total wall-clock well under GitHub's 6h job cap,
# regardless of how large metarepo.delivery_check.timeout_minutes is set.
DEADLINE_SECONDS=$(( AUTODUCKS_DELIVERY_TIMEOUT_MINUTES * 60 ))
MAX_WALL_SECONDS=$(( 5 * 60 * 60 ))
(( DEADLINE_SECONDS > MAX_WALL_SECONDS )) && DEADLINE_SECONDS="$MAX_WALL_SECONDS"

round=0
while true; do
  round=$(( round + 1 ))
  all_merged=true
  failure_reason=""

  for m in "${PROTECTED_PATHS[@]}"; do
    if [[ -z "${CHILD_PR[$m]:-}" ]]; then
      resolve_child_pr "$m" "${CHILD_SLUG[$m]}"
      [[ -z "${CHILD_PR[$m]:-}" ]] && { all_merged=false; continue; }
    fi

    token="$(git::resolve_token "${CHILD_SLUG[$m]}")"
    pr_json="$(GH_TOKEN="$token" gh pr view "${CHILD_PR[$m]}" --repo "${CHILD_SLUG[$m]}" --json state,mergedAt,statusCheckRollup 2>/dev/null || echo '{}')"
    state="$(jq -r '.state // ""' <<<"$pr_json")"
    merged_at="$(jq -r '.mergedAt // ""' <<<"$pr_json")"

    if [[ "$state" == "MERGED" && -n "$merged_at" ]]; then
      continue
    fi
    if [[ "$state" == "CLOSED" && -z "$merged_at" ]]; then
      failure_reason="child PR ${CHILD_URL[$m]} was closed without merging"
      all_merged=false
      break
    fi
    bad_checks="$(jq -r '[.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT")] | length' <<<"$pr_json" 2>/dev/null || echo 0)"
    if [[ "${bad_checks:-0}" -gt 0 ]]; then
      failure_reason="child PR ${CHILD_URL[$m]} has a failing required check"
      all_merged=false
      break
    fi
    all_merged=false
  done

  if [[ -n "$failure_reason" ]]; then
    notice "$failure_reason"
    step_summary "### Delivery poll — failed (round $round)"
    step_summary "$failure_reason"
    step_summary "$(render_summary)"
    git::conclude_check_run "$CHECK_RUN_ID" failure "Delivery failed" \
      "$failure_reason
$(render_summary)" || true
    exit 0
  fi

  if [[ "$all_merged" == "true" ]]; then
    notice "all protected children delivered"
    step_summary "### Delivery poll — success (round $round)"
    step_summary "$(render_summary)"
    git::conclude_check_run "$CHECK_RUN_ID" success "All children delivered" \
      "$(render_summary)" || true
    exit 0
  fi

  notice "round $round: waiting on protected child delivery (${SECONDS}s elapsed)"
  step_summary "### Delivery poll — round $round (pending)"
  step_summary "$(render_summary)"

  if (( SECONDS >= DEADLINE_SECONDS )); then
    notice "timed out waiting for protected child delivery"
    step_summary "### Delivery poll — timed out"
    git::conclude_check_run "$CHECK_RUN_ID" failure "Timed out" \
      "Timed out after ${AUTODUCKS_DELIVERY_TIMEOUT_MINUTES}m waiting for protected child delivery.
$(render_summary)" || true
    exit 0
  fi

  sleep "$AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS"
done
