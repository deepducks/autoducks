#!/usr/bin/env bash
set -euo pipefail

its::create_issue() {
  local title="$1"
  local body_file="$2"
  local labels_csv="${3:-}"
  local type="${4:-}"
  local parent_id="${5:-}"

  local body
  body="$(cat "$body_file")"

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body "$body" \
    '{title: $title, body: $body}')

  if [[ -n "$labels_csv" ]]; then
    local labels_json
    labels_json=$(echo "$labels_csv" | tr ',' '\n' | jq -R . | jq -s .)
    payload=$(echo "$payload" | jq --argjson labels "$labels_json" '. + {labels: $labels}')
  fi

  if [[ -n "$type" ]]; then
    payload=$(echo "$payload" | jq --arg type "$type" '. + {type: $type}')
  fi

  local create_response
  create_response=$(echo "$payload" | gh api "repos/$REPO/issues" --method POST --input -)

  local issue_number
  issue_number=$(echo "$create_response" | jq -r '.number')
  local issue_db_id
  issue_db_id=$(echo "$create_response" | jq -r '.id')

  if [[ -n "$parent_id" ]]; then
    its::link_sub_issue "$parent_id" "$issue_db_id"
  fi

  echo "$issue_number"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::create_issue TITLE BODY_FILE [LABELS_CSV] [TYPE] [PARENT_ID]"; echo "  Create an issue, returns issue number"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
