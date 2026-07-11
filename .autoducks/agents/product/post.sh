#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="product"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/delivery-phase.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"
source "$AUTODUCKS_ROOT/core/orchestration/fold-duplicate.sh"
source "$AUTODUCKS_ROOT/core/config/classify-label.sh"

ISSUE_NUM="${ISSUE_NUM:-}"
COMMENT_ISSUE_NUM="${COMMENT_ISSUE_NUM:-}"
COMMENT_ID="${COMMENT_ID:-0}"
EVENT_NAME="${EVENT_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"

# See pre.sh for why STATUS_ISSUE_NUM (where the status comment lands) is
# tracked separately from ISSUE_NUM (which drives scope).
STATUS_ISSUE_NUM="${ISSUE_NUM:-$COMMENT_ISSUE_NUM}"

HUMAN_INITIATED=0
[[ -n "$COMMENT_ID" && "$COMMENT_ID" != "0" ]] && HUMAN_INITIATED=1

SCOPE="sweep"
[[ -n "$ISSUE_NUM" ]] && SCOPE="single"

job_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# narrate_finish DETAILS — status-comment edit for a human-initiated /triage,
# a plain job-summary entry for event-driven runs (schedule, issues.opened).
narrate_finish() {
  if [[ "$HUMAN_INITIATED" -eq 1 && -n "$STATUS_ISSUE_NUM" ]]; then
    status_comment::finish "$STATUS_ISSUE_NUM" "$1"
  else
    job_summary "### 🦆 Product agent — triage run finished (event: \`${EVENT_NAME:-unknown}\`)"
    job_summary "$1"
  fi
}

narrate_fail() {
  if [[ "$HUMAN_INITIATED" -eq 1 && -n "$STATUS_ISSUE_NUM" ]]; then
    status_comment::fail "$STATUS_ISSUE_NUM" "$1"
  else
    job_summary "### ⚠️ Product agent — triage run failed (event: \`${EVENT_NAME:-unknown}\`)"
    job_summary "$1"
  fi
}

# pre.sh already reacted/failed/notified for its own failure — don't
# double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

trap '_rc=$?; notify_failure "${ISSUE_NUM:-0}" "$RUN_ID" "" 2>/dev/null || true; \
      narrate_fail "See the run log for details." 2>/dev/null || true; \
      [[ "$HUMAN_INITIATED" -eq 1 ]] && react_to_comment "$COMMENT_ID" "confused" 2>/dev/null || true; \
      exit $_rc' ERR

# A cancelled run is not a triage failure — neutral status, clean exit,
# no notify_failure / no 😕 reaction. product has no in-progress work
# label and no Check-run, so pass an empty label and no run id.
cancellation::handle "$STATUS_ISSUE_NUM" ""

# Parity with every other agent's post step. In practice LLM_SKIPPED
# never fires for product (it runs on issues/schedule/comments, not on
# workflow-editing PRs), but the gate keeps the post-step contract
# uniform. Only narrate when we actually have an issue to comment on.
if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  [[ -n "$STATUS_ISSUE_NUM" ]] && notify_skip "$STATUS_ISSUE_NUM" \
    "The product agent's auto-triggered run was skipped."
  [[ "$HUMAN_INITIATED" -eq 1 ]] && react_to_comment "$COMMENT_ID" "+1"
  exit 0
fi

CONFIDENCE_THRESHOLD=$(jq -r '.product.confidence_threshold // "high"' "$AUTODUCKS_ROOT/autoducks.json")
[[ -z "$CONFIDENCE_THRESHOLD" || "$CONFIDENCE_THRESHOLD" == "null" ]] && CONFIDENCE_THRESHOLD="high"

MAX_CLOSES_PER_RUN=$(jq -r '.product.max_closes_per_run // 5' "$AUTODUCKS_ROOT/autoducks.json")
[[ -z "$MAX_CLOSES_PER_RUN" || "$MAX_CLOSES_PER_RUN" == "null" ]] && MAX_CLOSES_PER_RUN=5

AUTO_MERGE_DUPLICATES=$(jq -r '.product.auto_merge_duplicates // true' "$AUTODUCKS_ROOT/autoducks.json")
[[ -z "$AUTO_MERGE_DUPLICATES" || "$AUTO_MERGE_DUPLICATES" == "null" ]] && AUTO_MERGE_DUPLICATES="true"

# `//` can't be used here (same reasoning as auto_merge_duplicates in
# pre.sh): a literal `false` must be honored, not treated as "unset".
PROVISIONAL_CLASSIFICATION=$(jq -r 'if .product.provisional_classification == null then true else .product.provisional_classification end' "$AUTODUCKS_ROOT/autoducks.json")

BACKEND=$(its::priority_backend)

# ── Validate the LLM's decision file ────────────────────────────────────
VALIDATOR="$AUTODUCKS_ROOT/core/robustness/validate-triage-decisions.py"
VALID_OUT="/tmp/triage-decisions.valid.json"
REPORT_FILE="/tmp/triage-validation-report.json"

if ! python3 "$VALIDATOR" /tmp/triage-decisions.json "$VALID_OUT" "$CONFIDENCE_THRESHOLD" "$MAX_CLOSES_PER_RUN"; then
  REASON=$(jq -r '.reason // "unknown parse failure"' "$REPORT_FILE" 2>/dev/null || echo "unknown parse failure")
  job_summary "### ⚠️ Triage decisions could not be parsed"
  job_summary "\`/tmp/triage-decisions.json\`: $REASON"
  job_summary "Nothing was applied this run."
  narrate_fail "⚠️ Could not parse the triage decisions ($REASON) — nothing was applied. See the job summary for details."
  [[ "$HUMAN_INITIATED" -eq 1 ]] && react_to_comment "$COMMENT_ID" "confused"
  exit 0
fi

PRIORITIES_JSON=$(jq -c '.priorities' "$VALID_OUT")
DUPLICATES_JSON=$(jq -c '.duplicates' "$VALID_OUT")
CLASSIFICATIONS_JSON=$(jq -c '.classifications' "$VALID_OUT")

DROPPED_COUNT=$(jq '.dropped | length' "$REPORT_FILE" 2>/dev/null || echo 0)
if [[ "$DROPPED_COUNT" -gt 0 ]]; then
  job_summary "### Triage validation dropped $DROPPED_COUNT entr$([[ "$DROPPED_COUNT" == 1 ]] && echo y || echo ies)"
  jq -r '.dropped[] | "- " + (.section // "?") + ": " + (.reason // "?") + ((.issue // .canonical) as $n | if $n then " (#\($n))" else "" end)' \
    "$REPORT_FILE" 2>/dev/null | while IFS= read -r line; do job_summary "$line"; done
fi

# Scope / config guardrails: a scoped single-issue run never touches
# duplicates (pre.sh didn't gather anything to dedup against), and
# `auto_merge_duplicates: false` disables the whole dedup half regardless
# of what the LLM proposed.
if [[ "$SCOPE" == "single" || "$AUTO_MERGE_DUPLICATES" != "true" ]]; then
  DUPLICATES_JSON="[]"
fi
if [[ "$BACKEND" == "off" ]]; then
  PRIORITIES_JSON="[]"
fi
if [[ "$PROVISIONAL_CLASSIFICATION" != "true" ]]; then
  CLASSIFICATIONS_JSON="[]"
fi

PRIORITY_COUNT=$(echo "$PRIORITIES_JSON" | jq 'length')
DUPLICATE_GROUP_COUNT=$(echo "$DUPLICATES_JSON" | jq 'length')
DUPLICATE_CLOSE_COUNT=$(echo "$DUPLICATES_JSON" | jq '[.[].duplicates[]] | length')
CLASSIFICATION_COUNT=$(echo "$CLASSIFICATIONS_JSON" | jq 'length')

# ── dry_run: describe, don't do ─────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  PROPOSAL=$(
    {
      echo "**Dry run — nothing was applied.**"
      echo
      if [[ "$PRIORITY_COUNT" -gt 0 ]]; then
        echo "**Proposed priorities ($PRIORITY_COUNT):**"
        echo "$PRIORITIES_JSON" | jq -r '.[] | "- #\(.issue) → `\(.priority)` — \(.rationale)"'
        echo
      fi
      if [[ "$DUPLICATE_GROUP_COUNT" -gt 0 ]]; then
        echo "**Proposed duplicate closes ($DUPLICATE_CLOSE_COUNT across $DUPLICATE_GROUP_COUNT group(s)):**"
        echo "$DUPLICATES_JSON" | jq -r '.[] | "- #\(.canonical) ← " + (.duplicates | map("#" + (. | tostring)) | join(", ")) + " (confidence: \(.confidence)) — \(.rationale)"'
        echo
      fi
      if [[ "$CLASSIFICATION_COUNT" -gt 0 ]]; then
        echo "**Proposed provisional classifications ($CLASSIFICATION_COUNT):**"
        echo "$CLASSIFICATIONS_JSON" | jq -r '.[] | "- #\(.issue) → `\(.kind)` — \(.rationale)"'
        echo
      fi
      if [[ "$PRIORITY_COUNT" -eq 0 && "$DUPLICATE_GROUP_COUNT" -eq 0 && "$CLASSIFICATION_COUNT" -eq 0 ]]; then
        echo "Nothing to propose — the backlog in scope is already groomed."
      fi
    }
  )
  narrate_finish "$PROPOSAL"
  [[ "$HUMAN_INITIATED" -eq 1 ]] && react_to_comment "$COMMENT_ID" "+1"
  exit 0
fi

# ── Apply priorities: open, un-prioritized issues only ──────────────────

# product::_project_priority ISSUE — best-effort read of the current
# Projects-v2 priority field value for ISSUE. Empty output means "no value
# set OR could not be determined"; callers treat lookup failure as "already
# prioritized" (skip) so an API hiccup can never cause a double-set.
PROJECT_ID=""
PROJECT_FIELD_NAME=""
product::_ensure_project_field() {
  [[ -n "$PROJECT_ID" ]] && return 0
  local resolved
  resolved=$(its::_resolve_priority_field 2>/dev/null) || return 1
  [[ -z "$resolved" ]] && return 1
  PROJECT_ID=$(echo "$resolved" | jq -r '.project_id')
  PROJECT_FIELD_NAME=$(its::_priority_field_name)
  [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "null" ]]
}

product::_project_priority() {
  local issue_id="$1" node_id
  product::_ensure_project_field || return 1
  node_id=$(gh api "repos/$REPO/issues/$issue_id" --jq '.node_id' 2>/dev/null) || return 1
  [[ -z "$node_id" ]] && return 1
  gh api graphql -f query='
    query($id: ID!, $fieldName: String!) {
      node(id: $id) {
        ... on Issue {
          projectItems(first: 20) {
            nodes {
              project { id }
              fieldValueByName(name: $fieldName) {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
            }
          }
        }
      }
    }' -F id="$node_id" -F fieldName="$PROJECT_FIELD_NAME" 2>/dev/null \
    | jq -r --arg pid "$PROJECT_ID" '[.data.node.projectItems.nodes[]? | select(.project.id == $pid)][0].fieldValueByName.name // empty'
}

# product::_already_prioritized ISSUE ISSUE_JSON — true when ISSUE already
# carries a priority under the active backend.
product::_already_prioritized() {
  local issue="$1" issue_json="$2"
  case "$BACKEND" in
    labels)
      echo "$issue_json" | jq -e '.labels | any(startswith("Priority:"))' >/dev/null 2>&1
      ;;
    project)
      local val
      val=$(product::_project_priority "$issue") || return 0
      [[ -n "$val" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

product::_priority_color() {
  case "$1" in
    Critical) echo "B60205" ;;
    High)     echo "D93F0B" ;;
    Medium)   echo "FBCA04" ;;
    Low)      echo "0E8A16" ;;
    *)        echo "CFD3D7" ;;
  esac
}

APPLIED_PRIORITIES_JSON="[]"
if [[ "$BACKEND" != "off" && "$PRIORITY_COUNT" -gt 0 ]]; then
  # Private collector: only jq -n's output may land here, so side-effect
  # stdout from gh/its:: below can never contaminate the jq -s slurp.
  priorities_collector=$(mktemp)
  while IFS= read -r p; do
    issue=$(echo "$p" | jq -r '.issue')
    priority=$(echo "$p" | jq -r '.priority')

    issue_json=$(its::get_issue "$issue" 2>/dev/null) || continue
    closed=$(gh issue view "$issue" --repo "$REPO" --json closed --jq '.closed' 2>/dev/null || echo true)
    [[ "$closed" == "true" ]] && continue

    product::_already_prioritized "$issue" "$issue_json" && continue

    if [[ "$BACKEND" == "labels" ]]; then
      gh label create "Priority:${priority}" --repo "$REPO" \
        --color "$(product::_priority_color "$priority")" \
        --description "Autoducks triage priority: ${priority}" >/dev/null 2>&1 || true
    fi

    its::set_priority "$issue" "$priority" >/dev/null 2>&1 || true
    jq -n --argjson issue "$issue" --arg priority "$priority" '{issue: $issue, priority: $priority}' >> "$priorities_collector"
  done < <(echo "$PRIORITIES_JSON" | jq -c '.[]')
  APPLIED_PRIORITIES_JSON=$(jq -s '.' < "$priorities_collector")
  rm -f "$priorities_collector"
fi
APPLIED_PRIORITY_COUNT=$(echo "$APPLIED_PRIORITIES_JSON" | jq 'length')

# ── Apply duplicates: close, label, cross-reference ─────────────────────
CLOSED_DUPLICATES_JSON="[]"
if [[ "$DUPLICATE_GROUP_COUNT" -gt 0 ]]; then
  # Private collector: only jq -n's output may land here, so side-effect
  # stdout from fold_duplicate::close below can never contaminate the jq -s slurp.
  duplicates_collector=$(mktemp)
  while IFS= read -r group; do
    canonical=$(echo "$group" | jq -r '.canonical')

    while IFS= read -r dup; do
      [[ -z "$dup" ]] && continue

      dup_json=$(its::get_issue "$dup" 2>/dev/null) || continue
      dup_closed=$(gh issue view "$dup" --repo "$REPO" --json closed --jq '.closed' 2>/dev/null || echo true)
      [[ "$dup_closed" == "true" ]] && continue

      dup_labels=$(echo "$dup_json" | jq -r '.labels[]?')
      if delivery_phase::started "$dup" "$dup_labels"; then
        continue
      fi

      fold_duplicate::close "$dup" "$canonical" >/dev/null

      jq -n --argjson canonical "$canonical" --argjson duplicate "$dup" '{canonical: $canonical, duplicate: $duplicate}' >> "$duplicates_collector"
    done < <(echo "$group" | jq -r '.duplicates[]')
  done < <(echo "$DUPLICATES_JSON" | jq -c '.[]')
  CLOSED_DUPLICATES_JSON=$(jq -s '.' < "$duplicates_collector")
  rm -f "$duplicates_collector"
fi

# Cross-reference comment on each canonical, folding in whichever of its
# duplicates were actually closed (delivery-phase locks may have skipped
# some of the group). Wording matches merge.sh's "Folding in #N ..." so the
# two close paths read the same regardless of which one produced them.
echo "$CLOSED_DUPLICATES_JSON" | jq -c 'group_by(.canonical) | .[]' | while IFS= read -r fold; do
  canonical=$(echo "$fold" | jq -r '.[0].canonical')
  ids=$(echo "$fold" | jq -r '[.[].duplicate] | map("#" + (. | tostring)) | join(", ")')
  its::comment_issue "$canonical" "Folding in $ids as duplicate(s) of this issue (closed as \`not_planned\`)." 2>/dev/null || true
done

CLOSED_COUNT=$(echo "$CLOSED_DUPLICATES_JSON" | jq 'length')

# ── Apply classifications: authoritative Bug/Feature labels ─────────────
# The LLM's `kind` is a hint, never the enforcement point — every entry is
# re-verified deterministically right here before anything is applied.
# Gated solely by `product.provisional_classification`; independent of the
# priority BACKEND and runs in both `single` and `sweep` scope.
APPLIED_CLASSIFICATIONS_JSON="[]"
if [[ "$CLASSIFICATION_COUNT" -gt 0 ]]; then
  # Private collector: only jq -n's output may land here, so side-effect
  # stdout from classify_label::apply below can never contaminate the jq -s slurp.
  classifications_collector=$(mktemp)
  while IFS= read -r c; do
    issue=$(echo "$c" | jq -r '.issue')
    kind=$(echo "$c" | jq -r '.kind')

    issue_json=$(its::get_issue "$issue" 2>/dev/null) || continue
    closed=$(gh issue view "$issue" --repo "$REPO" --json closed --jq '.closed' 2>/dev/null || echo true)
    [[ "$closed" == "true" ]] && continue

    issue_type=$(echo "$issue_json" | jq -r '.type // empty')
    issue_labels=$(echo "$issue_json" | jq -r '.labels[]?')

    # Already authoritatively classified (native type or exact Feature/Bug
    # label) or already designed — the Architect owns classification once
    # an issue reaches that stage; never override it. This guard also
    # doubles as the idempotency guard.
    if [[ "$issue_type" == "Feature" || "$issue_type" == "Bug" ]] \
       || echo "$issue_labels" | grep -qxE 'Feature|Bug' \
       || echo "$issue_labels" | grep -qx 'Design:done'; then
      continue
    fi

    classify_label::apply "$issue" "$kind" >/dev/null 2>&1 || true

    jq -n --argjson issue "$issue" --arg kind "$kind" '{issue: $issue, kind: $kind}' >> "$classifications_collector"
  done < <(echo "$CLASSIFICATIONS_JSON" | jq -c '.[]')
  APPLIED_CLASSIFICATIONS_JSON=$(jq -s '.' < "$classifications_collector")
  rm -f "$classifications_collector"
fi
APPLIED_CLASSIFICATION_COUNT=$(echo "$APPLIED_CLASSIFICATIONS_JSON" | jq 'length')

# ── Wrap up ───────────────────────────────────────────────────────────
SUMMARY="Triage complete (scope: \`$SCOPE\`, priority backend: \`$BACKEND\`)."
if [[ "$APPLIED_PRIORITY_COUNT" -gt 0 ]]; then
  SUMMARY+=$'\n\n**Priorities set:** '"$APPLIED_PRIORITY_COUNT"
fi
if [[ "$CLOSED_COUNT" -gt 0 ]]; then
  SUMMARY+=$'\n\n**Duplicates closed:** '"$CLOSED_COUNT"
fi
if [[ "$APPLIED_CLASSIFICATION_COUNT" -gt 0 ]]; then
  SUMMARY+=$'\n\n**Classified:** '"$APPLIED_CLASSIFICATION_COUNT"
fi
if [[ "$APPLIED_PRIORITY_COUNT" -eq 0 && "$CLOSED_COUNT" -eq 0 && "$APPLIED_CLASSIFICATION_COUNT" -eq 0 ]]; then
  SUMMARY+=$'\n\nNo-op — the backlog in scope was already groomed.'
fi

narrate_finish "$SUMMARY"
[[ "$HUMAN_INITIATED" -eq 1 ]] && react_to_comment "$COMMENT_ID" "+1"
exit 0
