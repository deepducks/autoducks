#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../config/load-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/check-recovery.sh"

# Poll each protected metarepo child's delivery PR to completion, driving the
# AUTODUCKS_DELIVERY_CHECK_NAME check-run on the parent's final PR. Inert
# outside metarepo mode (byte-identical single-repo behavior).
#
# Never merges a child and never comments. Two bounded, idempotent side effects
# beyond the check-run (start/conclude) exist because nothing else in the
# pipeline was in a position to perform them (#119):
#
#   * a draft→ready toggle on a child delivery PR that has NO check runs at all,
#     to re-fire a required check whose triggering event GitHub dropped;
#   * a gitlink-only commit on the parent PR's own head branch, re-pointing each
#     child at its current default-branch tip.
#
# Both are derived from current remote state, so a re-run (e.g. on `synchronize`)
# simply re-derives them; there is no workflow-local cache to go stale.
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

# ── Gitlink reconciliation (#119a/b) ──────────────────────────────────────
# Before gating on the children, make sure the gitlinks this PR carries still
# describe where those children actually are. A pin goes stale two ways that
# nothing else notices: an async auto-merge delivery could not report the SHA it
# would produce, and a sibling parent PR merging moves the base's gitlink out
# from under this one. Either leaves a 3-way conflict on an opaque SHA, so a PR
# that was MERGEABLE at creation silently turns CONFLICTING.
#
# Only fast-forwards are applied (metarepo::reconcile_gitlinks refuses anything
# else). A reconcile commit changes this PR's head, so the check-run created
# below is anchored on a SHA that is no longer the tip — conclude_all() therefore
# mirrors the conclusion onto the new head too, which keeps the required check
# satisfied even when the push credential is a GITHUB_TOKEN that fires no
# `synchronize` event.
RECONCILED_SHA=""
reconcile_pins() {
  local moved
  [[ -n "$PR_HEAD" ]] || return 0
  [[ "${#AFFECTED[@]}" -gt 0 ]] || return 0
  # Empty stdout means nothing moved; a SHA means a reconcile commit was pushed.
  moved="$(metarepo::reconcile_gitlinks "$PR_HEAD" "${AFFECTED[@]}" || true)"
  if [[ -n "$moved" && "$moved" != "$PR_HEAD_SHA" ]]; then
    RECONCILED_SHA="$moved"
    log "reconciled gitlinks → new head $moved"
  fi
}

# conclude_all CONCLUSION TITLE SUMMARY — conclude the primary check-run and, if
# a reconcile moved the head, an identical check-run on the new head SHA.
conclude_all() {
  local conclusion="$1" title="$2" summary="$3" mirror_id
  git::conclude_check_run "$CHECK_RUN_ID" "$conclusion" "$title" "$summary" || true
  [[ -n "$RECONCILED_SHA" ]] || return 0
  mirror_id="$(git::start_check_run "$AUTODUCKS_DELIVERY_CHECK_NAME" "$RECONCILED_SHA" 2>/dev/null || true)"
  if [[ -n "$mirror_id" ]]; then
    git::conclude_check_run "$mirror_id" "$conclusion" "$title" "$summary" || true
  else
    log "could not mirror the check-run onto reconciled head $RECONCILED_SHA"
  fi
}

reconcile_pins

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
  conclude_all success "No protected children to poll" \
    "No affected submodule has a protected default branch — nothing to wait on."
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

# ── Missing-required-check recovery (#119c) ───────────────────────────────
# An empty statusCheckRollup means the PR has no check at all — distinct from a
# pending check, which reports an entry with a null conclusion. The escalation
# itself lives in check_recovery::action; these track its inputs per child.
declare -A ZERO_CHECK_ROUNDS=()
declare -A RETRIGGERED=()
RECOVERY_ROUNDS="${AUTODUCKS_CHECK_RECOVERY_ROUNDS:-2}"

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

    total_checks="$(jq -r '[.statusCheckRollup[]?] | length' <<<"$pr_json" 2>/dev/null || echo 0)"
    if [[ "${total_checks:-0}" -eq 0 ]]; then
      ZERO_CHECK_ROUNDS["$m"]=$(( ${ZERO_CHECK_ROUNDS[$m]:-0} + 1 ))
      case "$(check_recovery::action "${ZERO_CHECK_ROUNDS[$m]}" "${RETRIGGERED[$m]:-}" "$RECOVERY_ROUNDS")" in
        retrigger)
          notice "child PR ${CHILD_URL[$m]} has no check runs after ${ZERO_CHECK_ROUNDS[$m]} rounds — re-firing its required check (draft→ready)"
          RETRIGGERED["$m"]=1
          git::retrigger_child_check "${CHILD_PR[$m]}" "${CHILD_SLUG[$m]}" "$token" \
            || log "could not re-trigger the required check on ${CHILD_URL[$m]}"
          ;;
        fail)
          failure_reason="child PR ${CHILD_URL[$m]} still has no check runs after a draft→ready re-trigger — its required check is not being produced, so auto-merge can never fire"
          all_merged=false
          break
          ;;
      esac
    else
      ZERO_CHECK_ROUNDS["$m"]=0
    fi
    all_merged=false
  done

  if [[ -n "$failure_reason" ]]; then
    notice "$failure_reason"
    step_summary "### Delivery poll — failed (round $round)"
    step_summary "$failure_reason"
    step_summary "$(render_summary)"
    conclude_all failure "Delivery failed" \
      "$failure_reason
$(render_summary)"
    exit 0
  fi

  if [[ "$all_merged" == "true" ]]; then
    notice "all protected children delivered"
    # The children have only just landed, so an async auto-merge delivery's real
    # SHA is knowable for the first time here — reconcile before concluding, so
    # the parent merges against pins that match the children (#119a).
    reconcile_pins
    step_summary "### Delivery poll — success (round $round)"
    step_summary "$(render_summary)"
    conclude_all success "All children delivered" \
      "$(render_summary)"
    exit 0
  fi

  notice "round $round: waiting on protected child delivery (${SECONDS}s elapsed)"
  step_summary "### Delivery poll — round $round (pending)"
  step_summary "$(render_summary)"

  if (( SECONDS >= DEADLINE_SECONDS )); then
    notice "timed out waiting for protected child delivery"
    step_summary "### Delivery poll — timed out"
    conclude_all failure "Timed out" \
      "Timed out after ${AUTODUCKS_DELIVERY_TIMEOUT_MINUTES}m waiting for protected child delivery.
$(render_summary)"
    exit 0
  fi

  sleep "$AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS"
done
