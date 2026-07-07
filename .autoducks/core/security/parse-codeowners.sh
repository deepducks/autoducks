#!/usr/bin/env bash
# Deterministic CODEOWNERS parser — no `gh` calls, path patterns ignored,
# file is treated as a flat allowlist of owners.
#
# Emits one owner per line, alphabetised & deduped:
#   @username         → "username"
#   @org/team-slug    → "@org/team-slug" (kept as team ref, expanded later)
#   user@example.com  → skipped (no leading '@')
set -euo pipefail

parse_codeowners() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^[[:space:]]*(#|$)/ { next }
    { for (i = 2; i <= NF; i++) if ($i ~ /^@/) print $i }
  ' "$file" | sort -u
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: parse_codeowners PATH"; echo "  Print @-prefixed owners from CODEOWNERS."; exit 0 ;;
    "") echo "Usage: parse_codeowners PATH" >&2; exit 2 ;;
    *) parse_codeowners "$1" ;;
  esac
fi
