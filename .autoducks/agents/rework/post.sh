#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="rework"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"
source "$AUTODUCKS_ROOT/core/orchestration/reconcile-tasks.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "${FEATURE_NUM:-$ISSUE_NUM}" "Work:orchestrating" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (failure, or a benign "nothing
# to rework" skip), reacted, and short-circuited via the shared marker —
# skip all checks below so we don't double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

# The in-progress label lives on FEATURE_NUM (rework tracks progress on the
# feature, not on the rework command's own issue), so clear it directly
# before handing off to the shared helper, which posts the neutral status
# comment on ISSUE_NUM (the rework issue) and exits — pass an empty label so
# it doesn't also try (and fail) to abort a label on ISSUE_NUM.
if [[ "${JOB_STATUS:-}" == "cancelled" ]]; then
  progress_labels::abort "$FEATURE_NUM" "Work:orchestrating" 2>/dev/null || true
fi
cancellation::handle "$ISSUE_NUM" ""

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$FEATURE_NUM" "Work:orchestrating"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Nothing actionable — the LLM judged the feedback already resolved or
# purely informational. A manual `/rework` finishes green here: no
# sub-issue, no draft flip, no dispatch. A headless auto-loop dispatch
# (workflow_dispatch with pr_number, no triggering comment — COMMENT_ID
# defaults to "0") has no comment thread for a human to notice the outcome
# on, and the PR is still blocked, so a silent green stop would strand it.
# Fall back to the same human handoff the reviewer posts on request-changes.
if [[ -f /tmp/rework-none.md ]]; then
  react_to_comment "${COMMENT_ID:-}" "+1"
  if [[ -z "${COMMENT_ID:-}" || "${COMMENT_ID:-0}" == "0" ]]; then
    status_comment::finish "$ISSUE_NUM" "**Nothing to rework** — PR #$PR_NUM is still blocked.

$(cat /tmp/rework-none.md)

**Next:** run \`$(autoducks_command_for rework)\` to address the findings on this PR now,
or \`$(autoducks_command_for defer)\` to save them as a follow-up issue and merge as-is.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
  else
    status_comment::finish "$ISSUE_NUM" "**Nothing to rework.**

$(cat /tmp/rework-none.md)

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
  fi
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

# Check the task spec was produced
if [[ ! -f /tmp/rework-task.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

# Parse the task spec (same parser/format the Engineer uses)
PARSE_ERROR_FILE=/tmp/parse-error.md
if ! python3 "$AUTODUCKS_ROOT/core/robustness/parse-plan.py" /tmp/rework-task.md /tmp/rework-task.jsonl; then
  if [[ -f "$PARSE_ERROR_FILE" ]]; then
    its::comment_issue "$ISSUE_NUM" "$(cat "$PARSE_ERROR_FILE")"
  fi
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

TASK_LINE=$(head -1 /tmp/rework-task.jsonl)
TASK_TITLE=$(echo "$TASK_LINE" | jq -r '.title')
TASK_BODY=$(echo "$TASK_LINE" | jq -r '.body')

# Metarepo mode: a task with no declared `**Modules:**` is knowably broken
# before anyone runs it — every real code change in a metarepo lives in a
# child, so the developer's drift guard rejects the first commit it makes.
# Failing here costs one cheap re-run; failing in the developer's post phase
# costs a whole implementation run that is then thrown away (#181).
if metarepo::enabled && [[ -z "$(metarepo::modules_from_body "$TASK_BODY")" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing" AUTODUCKS_FAIL_PHASE="post"
  its::comment_issue "$ISSUE_NUM" "❌ **Rework task rejected:** it declares no \`**Modules:**\`.

This repository is a **metarepo**, so all code lives in submodules ($(metarepo::submodule_paths | sed 's/^/`/; s/$/`/' | paste -sd, - | sed 's/,/, /g')). A task with an empty module set cannot legally change anything — the developer's drift guard would reject its first commit.

**Next:** re-run \`$(autoducks_command_for rework)\` — the task spec must carry a \`**Modules:**\` line naming the submodule path(s) the fix touches." 2>/dev/null || true
  echo "::error::rework: task spec declares no modules in metarepo mode" >&2
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

# `since` records when this rework round was filed. There is no cheap way to
# recover the previous round's merge timestamp from the ITS API, so each
# marker just threads the moment it was (re)written — still a monotonically
# increasing boundary a future run can compare against.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER="<!-- autoducks:rework: feature=${FEATURE_NUM} pr=${PR_NUM} since=${SINCE} -->"
TASK_BODY_WITH_MARKER="${TASK_BODY}

${MARKER}"

# Preserve the existing sub-issue's number (update-in-place) when the
# idempotency guard in pre.sh found one still open; otherwise use a fresh
# placeholder so reconcile_tasks creates a new issue.
TASK_REF="${REWORK_TASK_NUM:-T1}"
jq -c -n --arg ref "$TASK_REF" --arg title "$TASK_TITLE" --arg body "$TASK_BODY_WITH_MARKER" \
  '{ref: $ref, title: $title, body: $body, labels: ["Task"]}' > /tmp/rework-task-final.jsonl

RECONCILE_OUTPUT=$(reconcile_tasks "$FEATURE_NUM" /tmp/rework-task-final.jsonl "${REWORK_TASK_NUM:-}")
NEW_TASK_NUM=$(echo "$RECONCILE_OUTPUT" | grep '^TASK_NUMBERS=' | sed 's/^TASK_NUMBERS=//' | tr -d ' ')

# Append the task as a trailing wave — only for a genuinely new sub-issue.
# An update to an already-open rework sub-issue is already part of a wave.
if [[ -z "$REWORK_TASK_NUM" ]]; then
  FEATURE_ISSUE_JSON=$(its::get_issue "$FEATURE_NUM")
  FEATURE_TITLE=$(echo "$FEATURE_ISSUE_JSON" | jq -r '.title')
  FEATURE_BODY_RAW=$(echo "$FEATURE_ISSUE_JSON" | jq -r '.body')
  printf '%s' "$FEATURE_BODY_RAW" > /tmp/rework-feature-body-raw.md

  SPLIT_RC=0
  split_body /tmp/rework-feature-body-raw.md /tmp/rework-design-zone.md /tmp/rework-tactical-current.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$FEATURE_NUM" "❌ Tactical zone markers on #$FEATURE_NUM are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` / \`<!-- autoducks:tactical:end -->\` markers and re-run \`$(autoducks_command_for rework)\`."
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    exit 1
  fi

  if parse_waves "$FEATURE_BODY_RAW" >/dev/null 2>&1; then
    # Multi-wave plan already exists — append a trailing "Rework" wave and
    # a matching Progress line; every other wave/line is left untouched.
    awk -v name_line="  - name: Rework" -v tasks_line="    tasks: [${NEW_TASK_NUM}]" '
      /^```yaml[[:space:]]*$/ { in_yaml=1; print; next }
      in_yaml && /^```[[:space:]]*$/ { print name_line; print tasks_line; print; in_yaml=0; next }
      { print }
    ' /tmp/rework-tactical-current.md > /tmp/rework-tactical-step1.md

    # Insert the new checklist line as the last item of the `## Progress`
    # section. Blank lines inside the section (the separator before/after
    # the checklist) are buffered rather than treated as the section's end,
    # so the new line lands after the last real checklist item, not after
    # the heading's blank-line separator.
    awk -v new_line="- [ ] #${NEW_TASK_NUM} ${TASK_TITLE}" '
      BEGIN { in_progress=0; inserted=0; nblank=0 }
      {
        if ($0 ~ /^## Progress[[:space:]]*$/) { in_progress=1; print; next }
        if (in_progress) {
          if ($0 ~ /^- \[[ xX]\] #/) {
            for (i=1;i<=nblank;i++) print blank[i]
            nblank=0
            print
            next
          } else if ($0 ~ /^[[:space:]]*$/) {
            nblank++; blank[nblank]=$0
            next
          } else {
            if (!inserted) { print new_line; inserted=1 }
            for (i=1;i<=nblank;i++) print blank[i]
            nblank=0
            in_progress=0
            print
            next
          }
        }
        print
      }
      END {
        if (in_progress) {
          if (!inserted) print new_line
          for (i=1;i<=nblank;i++) print blank[i]
        }
      }
    ' /tmp/rework-tactical-step1.md > /tmp/rework-tactical-zone-new.md
  else
    # Single-task fast path (no waves plan) — promote to a genuine 2-wave
    # plan: wave 1 is the original single task (already merged into the
    # feature branch, tracked by the feature issue number itself, D12),
    # wave 2 is this rework.
    {
      echo "## Plan"
      echo ""
      echo '```yaml'
      echo "waves:"
      echo "  - name: Wave 1"
      echo "    tasks: [${FEATURE_NUM}]"
      echo "  - name: Rework"
      echo "    tasks: [${NEW_TASK_NUM}]"
      echo '```'
      echo ""
      echo "## Progress"
      echo ""
      echo "- [x] #${FEATURE_NUM} ${FEATURE_TITLE}"
      echo "- [ ] #${NEW_TASK_NUM} ${TASK_TITLE}"
    } > /tmp/rework-tactical-zone-new.md
  fi

  assemble_body /tmp/rework-design-zone.md /tmp/rework-tactical-zone-new.md /tmp/rework-feature-body-new.md
  its::update_issue_body "$FEATURE_NUM" /tmp/rework-feature-body-new.md
fi

# Revert the feature PR to draft — degrades gracefully if it's already a
# draft (or merged/closed out from under us).
git::mark_pr_draft "$PR_NUM" 2>/dev/null || true

# The review verdict is now being reworked — strip any lingering Review:*
# labels the Reviewer mirror-painted on the feature issue and its PR before
# handing back to orchestration, so exactly one stage label is shown. Mirror
# the Reviewer's target set (FEATURE_NUM + PR_NUM), de-duplicated.
for _t in "$FEATURE_NUM" "$PR_NUM"; do
  [[ -n "$_t" ]] || continue
  progress_labels::clear_review "$_t"
done

# Hand off to the Maestro. Do NOT mark the PR ready — the Maestro flips it
# back when the rework task merges.
progress_labels::start "$FEATURE_NUM" "Work:orchestrating" "Work:done"
chain::_dispatch execute "$FEATURE_NUM" "${AUTO_CHAIN:-}"

react_to_comment "${COMMENT_ID:-}" "+1"

if [[ -n "$REWORK_TASK_NUM" ]]; then
  TASK_ACTION_MSG="**Rework task #$NEW_TASK_NUM updated** with the latest unresolved feedback"
else
  TASK_ACTION_MSG="**Rework task #$NEW_TASK_NUM created** and appended as a new wave on #$FEATURE_NUM"
fi

status_comment::finish "$ISSUE_NUM" "$TASK_ACTION_MSG — PR #$PR_NUM has been reverted to draft.

**Next:** nothing — the Maestro is reworking PR #$PR_NUM and will flip it back to ready once the fix merges.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
