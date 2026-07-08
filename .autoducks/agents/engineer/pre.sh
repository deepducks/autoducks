#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="engineer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/build-revision-context.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"

rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated

trap '_rc=$?; touch /tmp/autoducks-pre-failed; \
      notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Tactics:crafting" 2>/dev/null || true; \
      exit $_rc' ERR

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
if ! echo "$ISSUE_LABELS" | grep -qx 'Design:done'; then
  if chain::dispatch_prerequisite "architect" "engineer" "$DOR_CHAIN" "$ISSUE_NUM"; then
    status_comment::delegate "$ISSUE_NUM" "This issue has no \`Design:done\` label, so the **Architect** was dispatched first to create (or revise) the design. The Engineer will re-run automatically when it finishes."
    touch /tmp/autoducks-dor-delegated
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  # Delegation refused (chain loop / too deep) — fail loudly instead of
  # planning on an unready issue.
  its::comment_issue "$ISSUE_NUM" "❌ \`${AUTODUCKS_COMMAND} engineer\`: issue is not ready (missing \`Design:done\`) and the Architect could not be auto-dispatched (chain loop or depth limit). Run \`${AUTODUCKS_COMMAND} architect\` manually, then retry."
  _AUTODUCKS_NOTIFIED=1
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  touch /tmp/autoducks-pre-failed
  exit 1
fi

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Tactics:crafting" "Tactics:done"

its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/issue-request.md

echo "$ISSUE_DATA" | jq -r '.body' > /tmp/issue-body-raw.md

# Revision mode: a completed tactical plan already exists (D6 — `Tactics:done`
# is both the completion record and the routing signal).
IS_REVISION="false"
if echo "$ISSUE_LABELS" | grep -qx "Tactics:done"; then
  IS_REVISION="true"
fi

if body_has_markers /tmp/issue-body-raw.md; then
  SPLIT_RC=0
  split_body /tmp/issue-body-raw.md /tmp/design-zone.md /tmp/tactical-zone-current.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Tactical zone markers are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` and \`<!-- autoducks:tactical:end -->\` markers in the issue body and re-run \`${AUTODUCKS_COMMAND} engineer\`."
    _AUTODUCKS_NOTIFIED=1
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "$COMMENT_ID" "confused"
    progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
    touch /tmp/autoducks-pre-failed
    exit 1
  fi
else
  # Case B: no markers — the whole body is the design zone.
  cp /tmp/issue-body-raw.md /tmp/design-zone.md
  : > /tmp/tactical-zone-current.md
fi

if [[ "$IS_REVISION" == "true" ]]; then
  # Get existing task numbers from YAML block in the tactical zone
  YAML_BLOCK=$(awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag' /tmp/tactical-zone-current.md)
  OLD_NUMBERS=""
  if [[ -n "$YAML_BLOCK" ]]; then
    OLD_NUMBERS=$(echo "$YAML_BLOCK" | yq '.waves[].tasks[]' 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ')
  fi

  build_revision_context "$ISSUE_NUM" "$OLD_NUMBERS" /tmp/conversation.md
  export OLD_NUMBERS
fi

export IS_REVISION

# Persist across GHA steps
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "IS_REVISION=$IS_REVISION" >> "$GITHUB_ENV"
  echo "OLD_NUMBERS=${OLD_NUMBERS:-}" >> "$GITHUB_ENV"
fi
