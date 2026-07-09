#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="merge"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/orchestration/delivery-phase.sh"
source "$AUTODUCKS_ROOT/core/orchestration/fold-duplicate.sh"

# `/merge #M` on issue N: closes N as a duplicate of M. Deterministic —
# no LLM involved. Idempotent: re-running on an already-closed N is a
# safe no-op, and re-running on a merge that already landed just repeats
# the (harmless) cross-reference comments.

ISSUE_NUM="${ISSUE_NUM:?ISSUE_NUM env var required}"
COMMENTER="${COMMENTER:-unknown}"
COMMENT_BODY="${COMMENT_BODY:-}"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

# Target accepts both `#M` and bare `M` right after the verb.
TARGET=$(printf '%s\n' "$COMMENT_BODY" \
  | grep -oE '/merge[[:space:]]+#?[0-9]+' \
  | head -1 \
  | grep -oE '[0-9]+' || true)

if [[ -z "$TARGET" ]]; then
  status_comment::fail "$ISSUE_NUM" "❌ No target issue found. Comment \`/merge #<issue>\` (or \`/merge <issue>\`) to mark #$ISSUE_NUM as a duplicate of another issue."
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 0
fi

if [[ "$TARGET" == "$ISSUE_NUM" ]]; then
  status_comment::fail "$ISSUE_NUM" "❌ #$ISSUE_NUM can't be a duplicate of itself. Comment \`/merge #<other-issue>\` with the issue this one duplicates."
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 0
fi

# Idempotent no-op: already closed (whether by a prior merge run or
# anything else) — nothing left to do.
ALREADY_CLOSED=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json closed --jq '.closed' 2>/dev/null || echo "false")
if [[ "$ALREADY_CLOSED" == "true" ]]; then
  status_comment::finish "$ISSUE_NUM" "Already closed — nothing to merge."
  react_to_comment "${COMMENT_ID:-}" "+1"
  exit 0
fi

ISSUE_DATA=$(its::get_issue "$ISSUE_NUM")
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]?')

# Delivery-phase lock: refuse to fold in an issue whose execution has
# already started (Work:* label, or a live pipeline branch).
if delivery_phase::started "$ISSUE_NUM" "$ISSUE_LABELS"; then
  its::comment_issue "$ISSUE_NUM" "🔒 **Can't merge — delivery has already started on #$ISSUE_NUM.**

Folding this into #$TARGET now would abandon in-flight work (open task branches/PRs, the pipeline branch). Unwind delivery first with \`$(autoducks_command_for revert)\` (undo the plan, keep the issue) or \`$(autoducks_command_for close)\` (full teardown), then re-run \`$(autoducks_command_for merge) #$TARGET\`."
  status_comment::fail "$ISSUE_NUM" "Locked — delivery phase already started."
  react_to_comment "${COMMENT_ID:-}" "-1"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 0
fi

# Comment on the target: fold N in, consolidating N's unique body (if any).
TARGET_COMMENT="Folding in #$ISSUE_NUM as a duplicate of this issue."
N_BODY=$(echo "$ISSUE_DATA" | jq -r '.body // empty')
if [[ -n "$(printf '%s' "$N_BODY" | tr -d '[:space:]')" ]]; then
  TARGET_COMMENT+=$'\n\n'"## Merged from #$ISSUE_NUM"$'\n\n'"$N_BODY"
fi
its::comment_issue "$TARGET" "$TARGET_COMMENT"

fold_duplicate::close "$ISSUE_NUM" "$TARGET"

react_to_comment "${COMMENT_ID:-}" "+1"
status_comment::finish "$ISSUE_NUM" "Merged into #$TARGET; closed as \`not_planned\`."
its::assign_issue "$ISSUE_NUM" "$COMMENTER" 2>/dev/null || true
