#!/usr/bin/env bash
set -euo pipefail

# Parse waves from an issue body (YAML or Markdown format)
# Usage: parse_waves <issue_body>
# Output: WAVE|idx|name and TASK|idx|num lines to stdout

parse_yaml_plan() {
  local body="$1"
  local yaml_block
  yaml_block=$(echo "$body" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')

  [[ -z "$yaml_block" ]] && return 1
  echo "$yaml_block" | grep -q 'waves:' || return 1

  local wave_idx=0
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^  - name:'; then
      local name
      name=$(echo "$line" | sed 's/.*name:[[:space:]]*//')
      echo "WAVE|${wave_idx}|${name}"
      ((wave_idx++)) || true
    elif echo "$line" | grep -qE '^      - [0-9]+'; then
      local num
      num=$(echo "$line" | grep -oE '[0-9]+')
      echo "TASK|$((wave_idx - 1))|${num}"
    fi
  done <<< "$yaml_block"

  [[ $wave_idx -gt 0 ]] && return 0 || return 1
}

parse_markdown_plan() {
  local body="$1"

  echo "$body" | awk '
    /^(#|\*|[Ww]ave)/ && /[Ww]ave[[:space:]]+[0-9]+/ && !/^[[:space:]]*[-*][[:space:]]+\[/ {
      wave++
      name = ""
      if (match($0, /[Ww]ave[[:space:]]+[0-9]+/)) {
        rest = substr($0, RSTART + RLENGTH)
        gsub(/^[[:space:]]*[:——\-\*\(]+[[:space:]]*/, "", rest)
        gsub(/[\)\*]+[[:space:]]*$/, "", rest)
        gsub(/[[:space:]]+$/, "", rest)
        name = rest
      }
      if (name == "") name = "Wave " wave
      printf "WAVE|%d|%s\n", wave, name
      next
    }
    wave >= 1 && /^[[:space:]]*[-*][[:space:]]+\[[xX[:space:]]\][[:space:]]+#[0-9]+/ {
      if (match($0, /#[0-9]+/)) {
        num = substr($0, RSTART+1, RLENGTH-1)
        printf "TASK|%d|%s\n", wave, num
      }
    }
  '
}

parse_waves() {
  local body="$1"

  if parse_yaml_plan "$body" 2>/dev/null; then
    return 0
  fi

  local result
  result=$(parse_markdown_plan "$body")
  if [[ -n "$result" ]]; then
    echo "$result"
    return 0
  fi

  echo "::error::Could not parse waves from issue body (neither YAML nor Markdown format)"
  return 1
}
