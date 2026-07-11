#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="product"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"

ISSUE_NUM="${ISSUE_NUM:-}"
COMMENT_ISSUE_NUM="${COMMENT_ISSUE_NUM:-}"
COMMENT_ID="${COMMENT_ID:-0}"
EVENT_NAME="${EVENT_NAME:-}"

# STATUS_ISSUE_NUM: where the human-facing status comment lands. A `/triage`
# comment deliberately keeps ISSUE_NUM empty (scope stays a full backlog
# sweep — see the WARNING in scripts/smoke-test-product.sh) but the status
# comment still belongs on the issue the command was posted on, carried
# separately via COMMENT_ISSUE_NUM. issues.opened/workflow_dispatch already
# carry a real ISSUE_NUM and take priority.
STATUS_ISSUE_NUM="${ISSUE_NUM:-$COMMENT_ISSUE_NUM}"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

# Human-initiated `/triage` (a real triggering comment) gets a status
# comment + reactions; event-driven runs (schedule sweep, issues.opened)
# narrate through the job summary instead — same event-driven-vs-human split
# the Maestro makes for its own report()/status-comment choice.
HUMAN_INITIATED=0
[[ -n "$COMMENT_ID" && "$COMMENT_ID" != "0" ]] && HUMAN_INITIATED=1

job_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

narrate_start() {
  if [[ "$HUMAN_INITIATED" -eq 1 ]]; then
    react_to_comment "$COMMENT_ID" "eyes"
    status_comment::start "$STATUS_ISSUE_NUM"
  else
    job_summary "### 🦆 Product agent — triage run starting (event: \`${EVENT_NAME:-unknown}\`)"
  fi
}

narrate_note() {
  if [[ "$HUMAN_INITIATED" -eq 1 ]]; then
    status_comment::note "$STATUS_ISSUE_NUM" "$1"
  else
    job_summary "$1"
  fi
}

trap '_rc=$?; notify_failure "${ISSUE_NUM:-0}" "$RUN_ID" "" 2>/dev/null || true; \
      if [[ "$HUMAN_INITIATED" -eq 1 ]]; then \
        status_comment::fail "$STATUS_ISSUE_NUM" 2>/dev/null || true; \
        react_to_comment "$COMMENT_ID" "confused" 2>/dev/null || true; \
      else \
        job_summary "⚠️ Product agent pre-execution failed — see the run log." 2>/dev/null || true; \
      fi; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

# ── Scope: a real ISSUE_NUM means "triage just this issue" (issues.opened,
# or a `/triage` comment on a specific issue). No ISSUE_NUM means a full
# backlog sweep (schedule, workflow_dispatch with no issue_number, or a
# `/triage` comment — see STATUS_ISSUE_NUM above for why the latter still
# gets a status comment despite the sweep scope). ──
SCOPE="sweep"
[[ -n "$ISSUE_NUM" ]] && SCOPE="single"

narrate_start

BACKEND=$(its::priority_backend)

# `//` can't be used here: jq's `//` treats a literal `false` the same as
# `null` and falls through to the default, which would silently ignore an
# explicit `"auto_merge_duplicates": false` in config.
AUTO_MERGE_DUPLICATES=$(jq -r 'if .product.auto_merge_duplicates == null then true else .product.auto_merge_duplicates end' "$AUTODUCKS_ROOT/autoducks.json")

# Same explicit-`false`-honoring form as AUTO_MERGE_DUPLICATES above — read
# again (not shared with post.sh) so each script fails independently if the
# other's config read ever breaks.
PROVISIONAL_CLASSIFICATION=$(jq -r 'if .product.provisional_classification == null then true else .product.provisional_classification end' "$AUTODUCKS_ROOT/autoducks.json")

MAX_ISSUES=$(jq -r '.product.max_issues_per_run // 100' "$AUTODUCKS_ROOT/autoducks.json")
[[ -z "$MAX_ISSUES" || "$MAX_ISSUES" == "null" ]] && MAX_ISSUES=100

CONFIDENCE_THRESHOLD=$(jq -r '.product.confidence_threshold // "high"' "$AUTODUCKS_ROOT/autoducks.json")
[[ -z "$CONFIDENCE_THRESHOLD" || "$CONFIDENCE_THRESHOLD" == "null" ]] && CONFIDENCE_THRESHOLD="high"

# Duplicate detection runs only for a full sweep, and only when the config
# allows it — a scoped single-issue triage has nothing to compare against.
DUPLICATES_ENABLED="false"
if [[ "$SCOPE" == "sweep" && "$AUTO_MERGE_DUPLICATES" == "true" ]]; then
  DUPLICATES_ENABLED="true"
fi

# ── Gather the inbox ────────────────────────────────────────────────────
if [[ "$SCOPE" == "single" ]]; then
  ISSUE_JSON=$(its::get_issue "$ISSUE_NUM")
  ISSUES_JSON=$(jq -n --argjson n "$ISSUE_NUM" --argjson issue "$ISSUE_JSON" \
    '[{number: $n, title: $issue.title, body: $issue.body, labels: $issue.labels,
       type: $issue.type, already_prioritized: ($issue.labels | any(startswith("Priority:"))),
       dedup_candidates: []}]')
else
  RAW_ISSUES=$(its::list_issues open "$MAX_ISSUES")

  # Truncation check: is there more open backlog than we pulled? Cheap
  # over-fetch (bounded, not unbounded) rather than a second full listing.
  TOTAL_OPEN=$(gh issue list --repo "$REPO" --state open --limit "$((MAX_ISSUES + 1))" --json number --jq 'length' 2>/dev/null || echo 0)
  if [[ "$TOTAL_OPEN" -gt "$MAX_ISSUES" ]]; then
    job_summary "⚠️ Backlog has more than ${MAX_ISSUES} open issues; this run is bounded to \`product.max_issues_per_run\` (${MAX_ISSUES}) and the rest were dropped for this pass."
  fi

  # Cheap its::search_issues dedup pre-filter: for each issue, search on a
  # few significant title words and flag any other in-scope issue that comes
  # back — a hint for the LLM, not a verdict (it still has to read both
  # bodies to confirm). Capped at DEDUP_SEARCH_CAP calls — GitHub search's
  # secondary rate limit is ~30 req/min, and an uncapped one-call-per-issue
  # loop over a large sweep (up to `max_issues_per_run`, default 100) can
  # trip it. Issues beyond the cap simply get no dedup hint; the LLM still
  # sees their full title/body and can catch duplicates by reading.
  ISSUES_JSON="$RAW_ISSUES"
  if [[ "$DUPLICATES_ENABLED" == "true" ]]; then
    DEDUP_SEARCH_CAP=25
    INBOX_NUMBERS=$(echo "$RAW_ISSUES" | jq -c '[.[].number]')
    INBOX_COUNT=$(echo "$RAW_ISSUES" | jq 'length')
    if [[ "$INBOX_COUNT" -gt "$DEDUP_SEARCH_CAP" ]]; then
      job_summary "⚠️ Dedup pre-filter is capped at ${DEDUP_SEARCH_CAP} \`its::search_issues\` call(s) to stay under GitHub search's rate limit; $((INBOX_COUNT - DEDUP_SEARCH_CAP)) of ${INBOX_COUNT} issue(s) in scope got no dedup search hint this run (the LLM still reviews their full title/body)."
    fi
    SEARCH_CALLS=0
    ISSUES_JSON=$(echo "$RAW_ISSUES" | jq -c '.[]' | while IFS= read -r issue; do
      num=$(echo "$issue" | jq -r '.number')
      title=$(echo "$issue" | jq -r '.title')
      candidates="[]"
      if [[ "$SEARCH_CALLS" -lt "$DEDUP_SEARCH_CAP" ]]; then
        # First 3 words of >=4 chars, stripped of punctuation — enough to bias
        # `gh search issues` toward genuinely similar titles without dragging
        # in every issue that shares a common short word.
        query=$(printf '%s' "$title" \
          | tr -d '[:punct:]' \
          | tr '[:upper:]' '[:lower:]' \
          | tr ' ' '\n' \
          | awk 'length($0) >= 4' \
          | head -3 \
          | paste -sd' ' -)
        if [[ -n "$query" ]]; then
          candidates=$(its::search_issues "$query" 2>/dev/null \
            | jq -c --argjson self "$num" --argjson inbox "$INBOX_NUMBERS" \
              '[.[].number] | map(select(. != $self and (. as $c | $inbox | index($c) != null)))' \
            2>/dev/null || echo "[]")
          SEARCH_CALLS=$((SEARCH_CALLS + 1))
        fi
      fi
      echo "$issue" | jq -c --argjson candidates "$candidates" '. + {dedup_candidates: $candidates}'
    done | jq -s '.')
  else
    ISSUES_JSON=$(echo "$RAW_ISSUES" | jq -c '[.[] | . + {dedup_candidates: []}]')
  fi

  # Priority-state layout, backend-aware. The `labels` backend can answer
  # "already prioritized?" for free from the labels already fetched above;
  # the `project`/`off` backends can't without a per-issue API round-trip,
  # so post.sh re-checks freshly (and cheaply, only for accepted decisions)
  # right before applying — this is a hint, not the enforcement point.
  if [[ "$BACKEND" == "labels" ]]; then
    ISSUES_JSON=$(echo "$ISSUES_JSON" | jq -c '[.[] | . + {already_prioritized: (.labels | any(startswith("Priority:")))}]')
  else
    ISSUES_JSON=$(echo "$ISSUES_JSON" | jq -c '[.[] | . + {already_prioritized: false}]')
  fi
fi

# Provisional-classification hints, backend-independent (unlike priority,
# these read straight off labels/native type already fetched above, so no
# `off`/`project`-style split is needed) — applies to both single and sweep
# scope alike.
ISSUES_JSON=$(echo "$ISSUES_JSON" | jq -c '[.[] | . + {
  already_classified: ((.type == "Feature" or .type == "Bug") or (.labels | any(. == "Feature" or . == "Bug"))),
  design_done: (.labels | any(. == "Design:done"))
}]')

DUPLICATES_ENABLED_JSON="false"
[[ "$DUPLICATES_ENABLED" == "true" ]] && DUPLICATES_ENABLED_JSON="true"

jq -n \
  --arg scope "$SCOPE" \
  --argjson issue_scope "${ISSUE_NUM:-null}" \
  --arg backend "$BACKEND" \
  --argjson duplicates_enabled "$DUPLICATES_ENABLED_JSON" \
  --arg confidence_threshold "$CONFIDENCE_THRESHOLD" \
  --argjson provisional_classification "$PROVISIONAL_CLASSIFICATION" \
  --argjson issues "$ISSUES_JSON" \
  '{scope: $scope, issue_scope: $issue_scope, priority_backend: $backend,
    duplicates_enabled: $duplicates_enabled, confidence_threshold: $confidence_threshold,
    provisional_classification: $provisional_classification,
    classification_enabled: $provisional_classification, issues: $issues}' \
  > /tmp/triage-inbox.json

# ── Human-readable rendering for the LLM ────────────────────────────────
{
  if [[ "$SCOPE" == "single" ]]; then
    echo "# Triage inbox — scoped to #$ISSUE_NUM"
  else
    echo "# Triage inbox — full backlog sweep"
  fi
  echo
  echo "- Priority backend: \`$BACKEND\`"
  echo "- Duplicate detection: \`$DUPLICATES_ENABLED\`"
  echo "- Provisional classification: \`$PROVISIONAL_CLASSIFICATION\`"
  echo "- Confidence threshold: \`$CONFIDENCE_THRESHOLD\`"
  echo "- Issues in scope: $(echo "$ISSUES_JSON" | jq 'length')"
  echo
  echo "$ISSUES_JSON" | jq -c '.[]' | while IFS= read -r issue; do
    num=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title')
    labels=$(echo "$issue" | jq -r '.labels | join(", ")')
    already=$(echo "$issue" | jq -r '.already_prioritized')
    candidates=$(echo "$issue" | jq -r '.dedup_candidates | map("#" + (. | tostring)) | join(", ")')
    body=$(echo "$issue" | jq -r '.body // ""')
    echo "### #$num — $title"
    echo
    echo "Labels: ${labels:-none}"
    echo "Already prioritized (hint): $already"
    [[ -n "$candidates" ]] && echo "Dedup candidates (hint): $candidates"
    echo
    echo "$body"
    echo
    echo "---"
    echo
  done
} > /tmp/triage-inbox.md

narrate_note "Gathered $(echo "$ISSUES_JSON" | jq 'length') issue(s) into the triage inbox (scope: \`$SCOPE\`, priority backend: \`$BACKEND\`, duplicates: \`$DUPLICATES_ENABLED\`)."
exit 0
