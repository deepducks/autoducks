#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="design"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"

# Check if design spec was produced
if [[ ! -f /tmp/design-spec.md ]]; then
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Spec:draft"
  exit 1
fi

# Update issue body with the design spec, preserving the tactical zone if one
# was stashed by pre.sh
if [[ -f /tmp/tactical-zone-preserved.flag ]]; then
  # Guard: flag set but content file vanished => lost state between steps.
  # An empty-but-present file is valid and must NOT trip this.
  if [[ ! -f /tmp/tactical-zone-preserved.md ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Aborting \`/agents design\`: the preserved tactical zone went missing between steps. Publishing would wipe the tactical plan, so no changes were made. Re-run \`/agents design\`."
    react_to_comment "$COMMENT_ID" "confused"
    progress_labels::abort "$ISSUE_NUM" "Spec:draft"
    exit 1
  fi
  assemble_body /tmp/design-spec.md /tmp/tactical-zone-preserved.md /tmp/feature-body.md
  its::update_issue_body "$ISSUE_NUM" /tmp/feature-body.md
else
  its::update_issue_body "$ISSUE_NUM" /tmp/design-spec.md
fi

# Route-critical: label makes routing work on every repo kind.
# Type is best-effort (org-only feature — silently no-ops on user repos).
its::set_issue_type "$ISSUE_NUM" "Feature" 2>/dev/null || true
its::add_label       "$ISSUE_NUM" "Feature"

# Remove Draft label if present
its::remove_label "$ISSUE_NUM" "Draft" 2>/dev/null || true

progress_labels::finish "$ISSUE_NUM" "Spec:draft" "Spec:plan"

react_to_comment "$COMMENT_ID" "+1"

# Notify commenter
its::comment_issue "$ISSUE_NUM" "✅ Design specification complete.

_Ran with \`${MODEL:-unknown}\` at reasoning \`${REASONING:-unknown}\`._

Use \`/agents devise\` to create the tactical plan, or assign @tactical to this issue."
