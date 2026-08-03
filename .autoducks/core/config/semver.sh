#!/usr/bin/env bash
# semver.sh — shared semver module (sortable form, comparison, constraint
# satisfaction, bump classification). Extracted verbatim from
# apply-plugins.sh's semver_num / check_version_compat so there is one
# implementation. Sourced by apply-plugins.sh and changelog.sh
# (changelog::range orders and bounds releases via semver::compare). Pure
# string/arithmetic — no $REPO, no network, safe to source anywhere.

# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_SEMVER_SH_LOADED:-}" ]] && return 0
readonly _SEMVER_SH_LOADED=1

# semver::num "a.b.c..." → sortable fixed-width integer string
semver::num() {
  local IFS=. p
  read -ra p <<<"$1"
  printf '%05d%05d%05d' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}"
}

# semver::compare A B — prints -1, 0, or 1 (A < B, A == B, A > B)
semver::compare() {
  local an bn
  an="$(semver::num "$1")"
  bn="$(semver::num "$2")"
  if [[ "$an" == "$bn" ]]; then
    printf '0'
  elif [[ "$an" < "$bn" ]]; then
    printf -- '-1'
  else
    printf '1'
  fi
}

# semver::satisfies HOST CONSTRAINT
#   Exit 0 if HOST satisfies CONSTRAINT, 1 if it does not, 2 if CONSTRAINT
#   does not match the '^(>=|<=|>|<|=)?(N.N.N)$' grammar (an unprefixed
#   constraint means "=").
semver::satisfies() {
  local host="$1" constraint="$2"
  [[ "$constraint" =~ ^(\>=|\<=|\>|\<|=)?([0-9]+\.[0-9]+\.[0-9]+)$ ]] || return 2
  local op="${BASH_REMATCH[1]:-=}" ver="${BASH_REMATCH[2]}"
  local hn pn
  hn="$(semver::num "$host")"
  pn="$(semver::num "$ver")"
  case "$op" in
    ">=") [[ "$hn" > "$pn" || "$hn" == "$pn" ]] && return 0 ;;
    "<=") [[ "$hn" < "$pn" || "$hn" == "$pn" ]] && return 0 ;;
    ">")  [[ "$hn" > "$pn" ]] && return 0 ;;
    "<")  [[ "$hn" < "$pn" ]] && return 0 ;;
    "=")  [[ "$hn" == "$pn" ]] && return 0 ;;
  esac
  return 1
}

# semver::bump_kind FROM TO — prints major|minor|patch|none|downgrade
semver::bump_kind() {
  local from="$1" to="$2" cmp
  cmp="$(semver::compare "$from" "$to")"
  if [[ "$cmp" == "0" ]]; then
    printf 'none'
    return 0
  fi
  if [[ "$cmp" == "1" ]]; then
    printf 'downgrade'
    return 0
  fi
  local IFS=. fp tp
  read -ra fp <<<"$from"
  read -ra tp <<<"$to"
  if [[ "${fp[0]:-0}" != "${tp[0]:-0}" ]]; then
    printf 'major'
  elif [[ "${fp[1]:-0}" != "${tp[1]:-0}" ]]; then
    printf 'minor'
  else
    printf 'patch'
  fi
}
