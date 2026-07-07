#!/usr/bin/env bash
# Progress-label helpers. Names, colors, and descriptions live in one place
# so agents don't drift out of sync.

# Ordered as (name, color, description) triples.
AUTODUCKS_PROGRESS_LABELS=(
  "Spec:draft|C5DEF5|Design agent is drafting the specification"
  "Spec:plan|1F6FEB|Design specification complete"
  "Tactics:crafting|F9D0C4|Tactical agent is crafting the plan"
  "Tactics:ready|D93F0B|Tactical plan complete"
  "Work:progress|BFE5BF|Work in progress (Execution or Wave)"
  "Work:done|0E8A16|Work complete"
)

# Ensure all six labels exist on $REPO. Idempotent; ignores "already exists".
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
# Usage: progress_labels::start ISSUE_NUM Spec:draft Spec:plan
progress_labels::start() {
  local issue_id="$1" in_progress="$2" done_label="$3"
  its::remove_label "$issue_id" "$done_label" 2>/dev/null || true
  its::add_label    "$issue_id" "$in_progress"
}

# Swap in-progress for done on success.
# Usage: progress_labels::finish ISSUE_NUM Spec:draft Spec:plan
progress_labels::finish() {
  local issue_id="$1" in_progress="$2" done_label="$3"
  its::remove_label "$issue_id" "$in_progress" 2>/dev/null || true
  its::add_label    "$issue_id" "$done_label"
}

# On failure, only clear the in-progress label. Never sets the done label.
# Usage: progress_labels::abort ISSUE_NUM Spec:draft
progress_labels::abort() {
  local issue_id="$1" in_progress="$2"
  its::remove_label "$issue_id" "$in_progress" 2>/dev/null || true
}
