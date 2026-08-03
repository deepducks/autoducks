#!/usr/bin/env bash
set -euo pipefail

# its::_priority_field_name
#
# The configured Projects v2 single-select field name that represents
# priority (defaults to "Priority").
its::_priority_field_name() {
  local name
  name="$(jq -r '.product.priority_field // "Priority"' "$AUTODUCKS_ROOT/autoducks.json" 2>/dev/null)"
  [[ -z "$name" || "$name" == "null" ]] && name="Priority"
  echo "$name"
}

# its::_resolve_priority_field
#
# Read-only GraphQL probe: resolves the repo-linked Projects v2 project
# (pinned to `product.project_number` when configured, else the first
# project linked to the repo) and its single-select field whose name
# matches its::_priority_field_name (case-insensitive).
#
# On success, emits a JSON object {project_id, project_number, field_id,
# options: [{id, name}, ...]} to stdout and returns 0. On any failure
# (no scope, no project, no matching field, network error) emits nothing
# and returns 1 — callers must treat non-zero as "not reachable", never
# as a fatal error.
its::_resolve_priority_field() {
  local field_name
  field_name="$(its::_priority_field_name)"

  local project_number
  project_number="$(jq -r '.product.project_number // empty' "$AUTODUCKS_ROOT/autoducks.json" 2>/dev/null)"

  local owner="${REPO%/*}"
  local name="${REPO#*/}"

  local result
  result="$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        projectsV2(first: 20) {
          nodes {
            id
            number
            fields(first: 50) {
              nodes {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options { id name }
                }
              }
            }
          }
        }
      }
    }' -F "owner=$owner" -F "name=$name" 2>/dev/null)" || return 1

  [[ -z "$result" ]] && return 1

  local filter
  if [[ -n "$project_number" ]]; then
    filter=".data.repository.projectsV2.nodes[] | select(.number == ${project_number})"
  else
    filter=".data.repository.projectsV2.nodes[0]"
  fi

  local project
  project="$(echo "$result" | jq -c "$filter" 2>/dev/null)" || return 1
  [[ -z "$project" || "$project" == "null" ]] && return 1

  local field
  field="$(echo "$project" | jq -c --arg fname "$field_name" \
    '.fields.nodes[]? | select((.name // "") | ascii_downcase == ($fname | ascii_downcase))' 2>/dev/null)" || return 1
  [[ -z "$field" || "$field" == "null" ]] && return 1

  jq -n -c --argjson project "$project" --argjson field "$field" \
    '{project_id: $project.id, project_number: $project.number, field_id: $field.id, options: $field.options}'
}

# its::priority_backend
#
# Resolves `product.priority_backend` (auto|project|labels|off) from
# config:
#   off      — short-circuits to "off", no probing.
#   project  — trusts the config, returns "project" without probing.
#   labels   — trusts the config, returns "labels" without probing.
#   auto (default) — probes for a reachable Projects v2 priority field via
#                     its::_resolve_priority_field; "project" when found,
#                     else "labels".
#
# The result is cached in the process environment via
# AUTODUCKS_PRIORITY_BACKEND after the first call; subsequent calls
# short-circuit. Emits exactly one of {project, labels, off} and always
# returns 0 (never exits non-zero — probing is best-effort), mirroring
# its::sub_issues_available.
its::priority_backend() {
  if [[ -n "${AUTODUCKS_PRIORITY_BACKEND:-}" ]]; then
    echo "$AUTODUCKS_PRIORITY_BACKEND"
    return 0
  fi

  local configured
  configured="$(jq -r '.product.priority_backend // "auto"' "$AUTODUCKS_ROOT/autoducks.json" 2>/dev/null)"
  [[ -z "$configured" || "$configured" == "null" ]] && configured="auto"

  local status
  case "$configured" in
    off)
      status="off"
      ;;
    project)
      status="project"
      ;;
    labels)
      status="labels"
      ;;
    *)
      if its::_resolve_priority_field >/dev/null 2>&1; then
        status="project"
      else
        status="labels"
      fi
      ;;
  esac

  export AUTODUCKS_PRIORITY_BACKEND="$status"
  echo "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::priority_backend"; echo "  Resolve the priority backend: project|labels|off"; echo "  Requires: REPO, AUTODUCKS_ROOT env vars"; exit 0 ;;
  esac
fi
