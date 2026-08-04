#!/usr/bin/env bash
set -euo pipefail

SET_PRIORITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../core/config/label-utils.sh
source "$SET_PRIORITY_DIR/../../../core/config/label-utils.sh"

# its::_set_priority_via_labels ISSUE_ID PRIORITY
#
# Strips any existing `Priority:*` label from ISSUE_ID and applies
# `Priority:PRIORITY`.
its::_set_priority_via_labels() {
  local issue_id="$1"
  local priority="$2"

  local current_labels
  current_labels="$(gh issue view "$issue_id" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null)" || current_labels=""

  local label
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    its::remove_label "$issue_id" "$label"
  done < <(label::has_prefix_in_list "$current_labels" "Priority:")

  its::add_label "$issue_id" "Priority:${priority}"
}

# its::_set_priority_via_project ISSUE_ID PRIORITY
#
# In order: (1) resolve the project + single-select priority field
# (its::_resolve_priority_field), (2) ensure ISSUE_ID is a project item —
# a field cannot be set on an issue that isn't one, even though the
# sidebar shows the field — adding it via addProjectV2ItemById if absent,
# (3) resolve the option id whose name case-insensitively matches
# PRIORITY (logging and no-op'ing if nothing matches), (4) call
# updateProjectV2ItemFieldValue. There is no REST fallback: any
# unreachable step returns 1 so the caller emits "unavailable".
its::_set_priority_via_project() {
  local issue_id="$1"
  local priority="$2"

  local resolved
  resolved="$(its::_resolve_priority_field 2>/dev/null)" || return 1
  [[ -z "$resolved" ]] && return 1

  local project_id field_id
  project_id="$(echo "$resolved" | jq -r '.project_id')"
  field_id="$(echo "$resolved" | jq -r '.field_id')"
  [[ -z "$project_id" || "$project_id" == "null" ]] && return 1
  [[ -z "$field_id" || "$field_id" == "null" ]] && return 1

  local option_id
  option_id="$(echo "$resolved" | jq -r --arg p "$priority" \
    '[.options[] | select((.name // "") | ascii_downcase == ($p | ascii_downcase))][0].id // empty')"

  if [[ -z "$option_id" ]]; then
    echo "its::set_priority: no priority option matching '${priority}' on issue ${issue_id}; no-op" >&2
    return 1
  fi

  local issue_node_id
  issue_node_id="$(gh api "repos/$REPO/issues/$issue_id" --jq '.node_id' 2>/dev/null)" || return 1
  [[ -z "$issue_node_id" || "$issue_node_id" == "null" ]] && return 1

  local item_id
  item_id="$(gh api graphql -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on Issue {
          projectItems(first: 20) {
            nodes { id project { id } }
          }
        }
      }
    }' -F "id=$issue_node_id" 2>/dev/null \
    | jq -r --arg pid "$project_id" '[.data.node.projectItems.nodes[]? | select(.project.id == $pid)][0].id // empty')" || item_id=""

  if [[ -z "$item_id" ]]; then
    item_id="$(gh api graphql -f query='
      mutation($project: ID!, $content: ID!) {
        addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
          item { id }
        }
      }' -F "project=$project_id" -F "content=$issue_node_id" 2>/dev/null \
      | jq -r '.data.addProjectV2ItemById.item.id // empty')" || return 1
    [[ -z "$item_id" ]] && return 1
  fi

  gh api graphql -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project,
        itemId: $item,
        fieldId: $field,
        value: { singleSelectOptionId: $option }
      }) {
        projectV2Item { id }
      }
    }' -F "project=$project_id" -F "item=$item_id" -F "field=$field_id" -F "option=$option_id" \
    >/dev/null 2>&1 || return 1
}

# its::set_priority ISSUE_ID PRIORITY
#
# Sets ISSUE_ID's priority to the named value PRIORITY via whichever
# backend its::priority_backend resolves to. Emits a single token on
# stdout and always returns 0:
#
#   project      — Projects v2 field updated
#   labels       — Priority:* label swapped
#   off          — priority tracking disabled by config; no-op
#   unavailable  — project backend selected but unreachable at any step
#                  (no REST fallback exists)
its::set_priority() {
  local issue_id="$1"
  local priority="$2"

  local backend
  backend="$(its::priority_backend)"

  case "$backend" in
    off)
      echo "off"
      ;;
    labels)
      its::_set_priority_via_labels "$issue_id" "$priority"
      echo "labels"
      ;;
    project)
      if its::_set_priority_via_project "$issue_id" "$priority"; then
        echo "project"
      else
        echo "unavailable"
      fi
      ;;
    *)
      echo "unavailable"
      ;;
  esac

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::set_priority ISSUE_ID PRIORITY"; echo "  Set an issue's priority via the project or labels backend"; echo "  Requires: REPO, AUTODUCKS_ROOT env vars"; exit 0 ;;
  esac
fi
