#!/usr/bin/env bash
# Canonical Bug/Feature classification labels. Sourced by product/post.sh and
# architect/post.sh so the color constants and the "ensure → add → remove
# opposite" logic live in one place. Requires $REPO, its::add_label,
# its::remove_label, and gh in the caller's environment.

# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_CLASSIFY_LABEL_SH_LOADED:-}" ]] && return 0
readonly _CLASSIFY_LABEL_SH_LOADED=1

# classify_label::color KIND — canonical hex color for a classification label.
classify_label::color() {
  case "$1" in
    Bug)     echo "D73A4A" ;;
    Feature) echo "A2EEEF" ;;
  esac
}

# classify_label::ensure KIND — create the canonical label if missing (no-op if
# it already exists, tolerant of the create race).
classify_label::ensure() {
  local kind="$1"
  gh label create "$kind" --repo "$REPO" \
    --color "$(classify_label::color "$kind")" \
    --description "Autoducks ${kind,,} pipeline" 2>/dev/null || true
}

# classify_label::apply ISSUE KIND — ensure the label exists, add it to ISSUE,
# and remove the opposite classification label. In the Architect path the
# remove is the real override step; in the Product apply path the caller's
# guard already skips any issue carrying Bug/Feature, so the remove is a
# harmless no-op there.
classify_label::apply() {
  local issue="$1" kind="$2" opposite="Bug"
  [[ "$kind" == "Bug" ]] && opposite="Feature"
  classify_label::ensure "$kind"
  its::add_label "$issue" "$kind"
  its::remove_label "$issue" "$opposite" 2>/dev/null || true
}
