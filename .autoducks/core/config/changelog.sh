#!/usr/bin/env bash
# changelog.sh — parser for .autoducks/CHANGELOG.md (Keep-a-Changelog
# format: '## [VERSION] - DATE' release headings, '### Category' subsections
# underneath). Sourced by release/update tooling that needs to show or
# reason about what changed between two host versions. Requires $AUTODUCKS_ROOT
# (falls back to '.autoducks', matching load-agent-defaults.sh) — no $REPO,
# no network.

# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_CHANGELOG_SH_LOADED:-}" ]] && return 0
readonly _CHANGELOG_SH_LOADED=1

_CHANGELOG_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CHANGELOG_SH_DIR/semver.sh"

# changelog::_file — path to CHANGELOG.md under $AUTODUCKS_ROOT
changelog::_file() {
  printf '%s/CHANGELOG.md' "${AUTODUCKS_ROOT:-.autoducks}"
}

# changelog::_versions FILE — every '## [VERSION]' heading's version, one per
# line, in file order (callers must not rely on this order being semver-sorted)
changelog::_versions() {
  local file="$1" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^##\ \[([^]]+)\] ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done < "$file"
}

# changelog::section VERSION — print that release's markdown body (everything
# under its '## [VERSION] ...' heading, up to the next '## [' heading or EOF,
# with leading/trailing blank lines trimmed). Exit 1 if VERSION has no
# heading in the changelog.
changelog::section() {
  local version="$1" file line in_section=0 found=0
  file="$(changelog::_file)"
  [[ -f "$file" ]] || return 1

  local -a body=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##\ \[([^]]+)\] ]]; then
      [[ "$in_section" -eq 1 ]] && break
      if [[ "${BASH_REMATCH[1]}" == "$version" ]]; then
        in_section=1
        found=1
      fi
      continue
    fi
    [[ "$in_section" -eq 1 ]] && body+=("$line")
  done < "$file"
  [[ "$found" -eq 1 ]] || return 1

  local start=0 end=$((${#body[@]} - 1))
  while [[ "$start" -le "$end" && -z "${body[$start]}" ]]; do start=$((start + 1)); done
  while [[ "$end" -ge "$start" && -z "${body[$end]}" ]]; do end=$((end - 1)); done
  [[ "$start" -gt "$end" ]] && return 0

  local i
  for ((i = start; i <= end; i++)); do
    printf '%s\n' "${body[$i]}"
  done
}

# changelog::range FROM_VERSION TO_VERSION — concatenated bodies (blank-line
# separated) for every release in (FROM, TO], newest first. Order/bounds are
# computed via semver::compare, never file order. Empty when FROM == TO or no
# release falls in range.
changelog::range() {
  local from="$1" to="$2" file v
  file="$(changelog::_file)"
  [[ -f "$file" ]] || return 0

  local -a in_range=()
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    [[ "$(semver::compare "$v" "$from")" == "1" ]] || continue
    local cmp_to
    cmp_to="$(semver::compare "$v" "$to")"
    [[ "$cmp_to" == "-1" || "$cmp_to" == "0" ]] || continue
    in_range+=("$v")
  done < <(changelog::_versions "$file")

  # Insertion-sort descending (newest first) by semver::compare.
  local -a sorted=()
  for v in "${in_range[@]}"; do
    local i inserted=0
    for ((i = 0; i < ${#sorted[@]}; i++)); do
      if [[ "$(semver::compare "$v" "${sorted[$i]}")" == "1" ]]; then
        sorted=("${sorted[@]:0:$i}" "$v" "${sorted[@]:$i}")
        inserted=1
        break
      fi
    done
    [[ "$inserted" -eq 0 ]] && sorted+=("$v")
  done

  local first=1
  for v in "${sorted[@]}"; do
    [[ "$first" -eq 0 ]] && printf '\n'
    changelog::section "$v"
    first=0
  done
}

# changelog::has_breaking FROM TO — exit 0 if any '### Breaking' heading
# appears in (FROM, TO]'s bodies, exit 1 otherwise.
changelog::has_breaking() {
  local from="$1" to="$2" body
  body="$(changelog::range "$from" "$to")"
  [[ -z "$body" ]] && return 1
  grep -q '^### Breaking' <<<"$body"
}
