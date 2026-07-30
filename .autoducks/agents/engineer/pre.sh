#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="engineer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER" "$AUTODUCKS_DOR_DELEGATED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/build-revision-context.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"
source "$AUTODUCKS_ROOT/core/orchestration/delivery-phase.sh"
source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"
source "$AUTODUCKS_ROOT/core/config/label-utils.sh"

trap '_rc=$?; touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Tactics:crafting" 2>/dev/null || true; \
      exit $_rc' ERR

ISSUE_LABELS_EARLY=$(its::get_issue "$ISSUE_NUM" | jq -r '.labels[]?')
if delivery_phase::started "$ISSUE_NUM" "$ISSUE_LABELS_EARLY"; then
  its::comment_issue "$ISSUE_NUM" "🔒 **Planning is locked — execution has already started.**

Re-running the Engineer now would reconcile the plan against tasks that are
already being built, and could close a task out from under an in-flight
Developer (orphaning its branch/PR) and desynchronise the Maestro's wave state.

To change the plan, first unwind the delivery with \`${AUTODUCKS_COMMAND} revert\`
(undo the plan, keep the issue), then re-run \`${AUTODUCKS_COMMAND} engineer\`."
  react_to_comment "${COMMENT_ID:-}" "confused"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

ISSUE_DATA=$(its::get_issue "$ISSUE_NUM")
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')

# ── Definition of Ready (D5): a completed design must exist ──────────
# Without `Design:done` the Engineer would be planning on top of an
# unstructured issue. Delegate to the Architect (create-or-revise) and
# re-queue ourselves — plus any pending chain — behind it.
#
# When this run was routed here from an `execute` verb, the user asked for
# execution: preserve that intent through the delegation by appending
# `execute` to the re-queued chain (post.sh does the same for direct runs).
DOR_CHAIN="${AUTO_CHAIN:-}"
if [[ "${COMMAND:-}" == "execute" ]]; then
  case "+${DOR_CHAIN}+" in
    *"+execute+"*) : ;;
    *) DOR_CHAIN="execute${DOR_CHAIN:++$DOR_CHAIN}" ;;
  esac
fi
ISSUE_TYPE=$(echo "$ISSUE_DATA" | jq -r '.type // empty')
is_classified=false
if [[ "${ISSUE_TYPE,,}" == "feature" || "${ISSUE_TYPE,,}" == "bug" ]] \
   || label::any_in_list "$ISSUE_LABELS" Feature Bug; then
  is_classified=true
fi

if ! label::in_list "$ISSUE_LABELS" "Design:done" || [[ "$is_classified" == false ]]; then
  if chain::dispatch_prerequisite "architect" "engineer" "$DOR_CHAIN" "$ISSUE_NUM"; then
    status_comment::delegate "$ISSUE_NUM" "This issue has no completed, classified design, so the **Architect** was dispatched first to create (or revise) the design. The Engineer will re-run automatically when it finishes."
    touch "$AUTODUCKS_DOR_DELEGATED_MARKER"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  # Delegation refused (chain loop / too deep) — fail loudly instead of
  # planning on an unready issue.
  its::comment_issue "$ISSUE_NUM" "❌ \`$(autoducks_command_for engineer)\`: issue is not ready (missing \`Design:done\`) and the Architect could not be auto-dispatched (chain loop or depth limit). Run \`$(autoducks_command_for architect)\` manually, then retry."
  _AUTODUCKS_NOTIFIED=1
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 1
fi

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Tactics:crafting" "Tactics:done"

resolve_context "engineer" "$ISSUE_NUM"
if metarepo::enabled; then metarepo::agent_context_block > /tmp/metarepo-context.md; fi

# Revision mode: a completed tactical plan already exists (D6 — `Tactics:done`
# is both the completion record and the routing signal).
IS_REVISION="false"
if label::in_list "$ISSUE_LABELS" "Tactics:done"; then
  IS_REVISION="true"
fi

if body_has_markers /tmp/issue-body-raw.md; then
  SPLIT_RC=0
  split_body /tmp/issue-body-raw.md /tmp/design-zone.md /tmp/tactical-zone-current.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Tactical zone markers are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` and \`<!-- autoducks:tactical:end -->\` markers in the issue body and re-run \`$(autoducks_command_for engineer)\`."
    _AUTODUCKS_NOTIFIED=1
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "$COMMENT_ID" "confused"
    progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
    touch "$AUTODUCKS_PRE_FAILED_MARKER"
    exit 1
  fi
else
  # Case B: no markers — the whole body is the design zone.
  cp /tmp/issue-body-raw.md /tmp/design-zone.md
  : > /tmp/tactical-zone-current.md
fi

# Existing task numbers referenced in the tactical zone's YAML wave block.
# tactical_zone::task_refs returns only real issue numbers (Tn placeholders are
# filtered out). Extracted UNCONDITIONALLY: a prior Architect re-design clears
# Tactics:done (bug #880) while the tactical zone still lists the tasks, so
# without this the superseded tasks are orphaned instead of closed (bug #1026).
YAML_BLOCK=$(awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag' /tmp/tactical-zone-current.md)
OLD_NUMBERS=""
if [[ -n "$YAML_BLOCK" ]]; then
  OLD_NUMBERS=$(tactical_zone::task_refs "$YAML_BLOCK" | tr '\n' ' ')
fi
export OLD_NUMBERS

# Revision mode: `Tactics:done` is the usual signal, but a tactical zone that
# already references real task issues is an equally valid one — treat it as a
# revision so those tasks get reconciled/closed rather than orphaned (#1026).
if [[ -n "${OLD_NUMBERS// /}" ]]; then
  IS_REVISION="true"
fi

if [[ "$IS_REVISION" == "true" ]]; then
  build_revision_context "$ISSUE_NUM" "$OLD_NUMBERS" /tmp/conversation.md

  # Surface the steering prompt explicitly: if the trigger comment falls
  # outside `build_revision_context`'s last-20-comments window, it would
  # otherwise be silently dropped from the revision context.
  if [[ -n "${STEERING_PROMPT:-}" ]]; then
    STEERING_PROMPT_TEXT=$(printf '%s' "$STEERING_PROMPT" | base64 -d 2>/dev/null || true)
    if [[ -n "$STEERING_PROMPT_TEXT" ]]; then
      printf '%s\n' "$STEERING_PROMPT_TEXT" > /tmp/steering-prompt.md
      {
        echo ""
        echo "---"
        echo ""
        echo "# Reviewer feedback / adjustments (steer the revision)"
        echo ""
        echo "$STEERING_PROMPT_TEXT"
      } >> /tmp/conversation.md
    fi
  fi
fi

export IS_REVISION

# Persist across GHA steps
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "IS_REVISION=$IS_REVISION" >> "$GITHUB_ENV"
  echo "OLD_NUMBERS=${OLD_NUMBERS:-}" >> "$GITHUB_ENV"
fi
