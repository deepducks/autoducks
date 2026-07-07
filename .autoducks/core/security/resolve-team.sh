#!/usr/bin/env bash
# Expand `@org/team-slug` → newline-separated list of member logins.
# Uses `gh api /orgs/{org}/teams/{slug}/members` and caches at
# $RUNNER_TEMP/autoducks-team-cache/<org>-<slug>.txt so each team is
# fetched at most once per job. On API failure the team ref is treated
# as an empty membership list — a warning goes to $GITHUB_STEP_SUMMARY
# and we do NOT exit non-zero (fail-open for the expansion, fail-closed
# is enforced by the caller when nothing else in the ladder matches).
set -euo pipefail

resolve_team() {
  local org="$1"
  local slug="$2"
  local cache_dir="${RUNNER_TEMP:-/tmp}/autoducks-team-cache"
  local cache_file="$cache_dir/${org}-${slug}.txt"

  mkdir -p "$cache_dir"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  local logins
  if logins="$(gh api "/orgs/${org}/teams/${slug}/members" --jq '.[].login' 2>/dev/null)"; then
    printf '%s\n' "$logins" > "$cache_file"
    cat "$cache_file"
    return 0
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'authz: WARN could not resolve team @%s/%s — treating as empty\n' \
      "$org" "$slug" >> "$GITHUB_STEP_SUMMARY"
  fi
  : > "$cache_file"
  return 0
}

resolve_team_contains() {
  local org="$1"
  local slug="$2"
  local actor="$3"
  local members
  members="$(resolve_team "$org" "$slug")"
  [[ -z "$members" ]] && return 1
  local m
  while IFS= read -r m; do
    [[ "$m" == "$actor" ]] && return 0
  done <<< "$members"
  return 1
}
