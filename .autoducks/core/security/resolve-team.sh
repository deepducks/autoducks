#!/usr/bin/env bash
# Expand `@org/team-slug` → newline-separated list of member logins.
# Uses `gh api /orgs/{org}/teams/{slug}/members` and caches at
# $RUNNER_TEMP/autoducks-team-cache/<org>-<slug>.txt so each team is
# fetched at most once per job.
#
# Direction-specific failure policy (see design §2):
#   - Expansion is fail-OPEN: on any API failure (including a `read:org`/
#     403 scope error) the team ref resolves to an empty membership list
#     and this script still exits 0 — a warning goes to
#     $GITHUB_STEP_SUMMARY, but we never abort the caller.
#   - Authorization is fail-CLOSED: `resolve_team_contains` returns
#     non-zero for an empty/unresolved team, so an unresolved `@org/team`
#     CODEOWNERS ref can never itself grant access. The authz ladder in
#     authorize.sh then falls through to its final default-deny.
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

  local logins stderr_file stderr_output
  stderr_file="$(mktemp)"
  if logins="$(gh api "/orgs/${org}/teams/${slug}/members" --jq '.[].login' 2>"$stderr_file")"; then
    rm -f "$stderr_file"
    printf '%s\n' "$logins" > "$cache_file"
    cat "$cache_file"
    return 0
  fi
  stderr_output="$(cat "$stderr_file" 2>/dev/null || true)"
  rm -f "$stderr_file"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    if [[ "$stderr_output" =~ (read:org|required scopes|HTTP 403) ]]; then
      printf 'authz: WARN insufficient token scope to resolve team @%s/%s (needs read:org) — treating as empty\n' \
        "$org" "$slug" >> "$GITHUB_STEP_SUMMARY"
    else
      printf 'authz: WARN team lookup failed for @%s/%s — treating as empty\n' \
        "$org" "$slug" >> "$GITHUB_STEP_SUMMARY"
    fi
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
