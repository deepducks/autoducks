#!/usr/bin/env bash
# Progress-label helpers. Names, colors, and descriptions live in one place
# so agents don't drift out of sync.

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
)

# Ensure all labels in AUTODUCKS_PROGRESS_LABELS exist on $REPO. Idempotent; ignores "already exists".
progress_labels::ensure() {
  local entry name color desc
  for entry in "${AUTODUCKS_PROGRESS_LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    gh label create "$name" \
      --repo "$REPO" \
      --color "$color" \
      --description "$desc" 2>/dev/null || true
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
