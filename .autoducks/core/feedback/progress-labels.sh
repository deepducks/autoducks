#!/usr/bin/env bash
# Progress-label helpers. Names, colors, and descriptions live in one place
# so agents don't drift out of sync.

PROGRESS_LABELS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$PROGRESS_LABELS_DIR/../config/label-utils.sh"

# Ordered as (name, color, description) triples.
AUTODUCKS_PROGRESS_LABELS=(
  "Design:draft|C5DEF5|Architect agent is drafting the design"
  "Design:done|1F6FEB|Design complete"
  "Tactics:crafting|F9D0C4|Engineer agent is crafting the tactical plan"
  "Tactics:done|D93F0B|Tactical plan complete"
  "Work:orchestrating|BFE5BF|Maestro is orchestrating execution waves"
  "Work:coding|C2E0C6|Developer is implementing the task"
  "Work:done|0E8A16|Work complete"
  "Review:reviewing|FBCA04|Review agent is reviewing the pull request"
  "Review:done|0E8A16|Review complete"
  "Review:changes|D93F0B|Review requested changes"
  "Resolve:resolving|FBCA04|Resolver agent is resolving conflicts"
  "Resolve:done|0E8A16|Conflicts resolved"
  "Resolve:conflict|D93F0B|Conflicts could not be auto-resolved"
  "auto-resolved|0052CC|Conflicts auto-resolved by the resolver agent"
  "Agent:running|FBCA04|Custom agent is running"
  "Agent:done|0E8A16|Custom agent finished"
)

# Sticky Mode:* labels indicating the orchestrator's execution mode. Distinct
# from AUTODUCKS_PROGRESS_LABELS: never swapped in/out by start/finish.
AUTODUCKS_MODE_LABELS=(
  "Mode:waves|BFDADC|Orchestrator: sequential fan-out of waves (default)"
  "Mode:sequential|5319E7|Orchestrator: one task at a time, fully sequential"
)

# Ensure all labels in AUTODUCKS_PROGRESS_LABELS and AUTODUCKS_MODE_LABELS
# exist on $REPO. Idempotent; ignores "already exists".
progress_labels::ensure() {
  local entry name color desc
  for entry in "${AUTODUCKS_PROGRESS_LABELS[@]}" "${AUTODUCKS_MODE_LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    label::ensure "$name" "$color" "$desc" \
      || echo "progress_labels::ensure: failed to ensure label '$name'" >&2
  done
}

# Add the in-progress label for a layer, clearing the paired done label
# (in case this is a re-run over a previously completed layer).
# Usage: progress_labels::start ISSUE_NUM Design:draft Design:done
progress_labels::start() {
  local issue_id="$1" in_progress="$2" done_label="$3"
  its::remove_label "$issue_id" "$done_label" 2>/dev/null || true
  its::add_label    "$issue_id" "$in_progress"
}

# Swap in-progress for done on success.
# Usage: progress_labels::finish ISSUE_NUM Design:draft Design:done
progress_labels::finish() {
  local issue_id="$1" in_progress="$2" done_label="$3"
  its::remove_label "$issue_id" "$in_progress" 2>/dev/null || true
  its::add_label    "$issue_id" "$done_label"
}

# On failure, only clear the in-progress label. Never sets the done label.
# Usage: progress_labels::abort ISSUE_NUM Design:draft
progress_labels::abort() {
  local issue_id="$1" in_progress="$2"
  its::remove_label "$issue_id" "$in_progress" 2>/dev/null || true
}

# The three terminal/in-progress review labels the Reviewer may leave on an
# item (mirror-painted on both the feature/bug issue and its PR). Kept beside
# AUTODUCKS_PROGRESS_LABELS so the two never drift.
AUTODUCKS_REVIEW_LABELS=(
  "Review:reviewing"
  "Review:done"
  "Review:changes"
)

# Remove every Review:* label from a target. Idempotent — labels that are
# absent are silently ignored (its::remove_label already tolerates this).
# Usage: progress_labels::clear_review ISSUE_OR_PR_NUM
progress_labels::clear_review() {
  local target="$1" label
  for label in "${AUTODUCKS_REVIEW_LABELS[@]}"; do
    its::remove_label "$target" "$label" 2>/dev/null || true
  done
}
