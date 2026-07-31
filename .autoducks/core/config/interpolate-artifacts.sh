#!/usr/bin/env bash
set -uo pipefail

# Literal, single-pass `{{part}}` substitution for an assembled agent prompt.
#
#   interpolate-artifacts.sh render <body_file|-> [manifest_file]
#   interpolate-artifacts.sh list   <body_file|->
#
# render: replaces every `{{<id>}}` placeholder in the body with the
# contents of its corresponding materialized part, then prints the result on
# stdout. `<id>` is resolved two ways:
#   - issue_number, repo, actor, steering_prompt — scalar values read from
#     env ($ISSUE_NUM, $REPO, $ACTOR, $STEERING_PROMPT respectively;
#     STEERING_PROMPT is base64, matching parse-directive.sh's wire format).
#   - anything else — looked up in <manifest_file> (default
#     /tmp/context-manifest.json, the file resolve_context writes), whose
#     `.parts[].id` / `.parts[].file` map an id to the file that materialized
#     it.
# An id that resolves to neither is replaced with
# `_(artifact "<id>" unavailable)_` and a ::warning:: is emitted; the run
# still succeeds (interpolation is best-effort — a missing artifact should
# not block the whole prompt).
#
# The substitution scans the body left to right exactly once: replacement
# text is appended to the output and never re-scanned, so a replacement that
# itself contains `{{x}}` is spliced verbatim, not re-expanded. This is
# implemented with plain parameter-expansion string splitting and `read`
# slurps — never `eval`, `envsubst`, or a sed/awk substitution whose
# replacement side could interpret attacker-influenced content (sed
# replacement strings treat `&` and backreferences specially; envsubst
# requires exporting arbitrary values as real env vars). A body with no
# `{{...}}` at all is echoed back byte-for-byte, untouched.
#
# list: prints every distinct `{{<id>}}` id found in the body, one per line,
# in first-seen order — so a caller can fold missing ids into its
# materialization set before rendering.

# ── whole-file slurp, preserving trailing newlines (unlike `$(...)`) ────
_ia::slurp() {
  local file="$1" __outvar="$2"
  local content=""
  if [[ "$file" == "-" ]]; then
    IFS= read -r -d '' content || true
  else
    IFS= read -r -d '' content < "$file" || true
  fi
  printf -v "$__outvar" '%s' "$content"
}

_ia::scalar() {
  case "$1" in
    issue_number) printf '%s' "${ISSUE_NUM:-}" ;;
    repo)         printf '%s' "${REPO:-}" ;;
    actor)        printf '%s' "${ACTOR:-}" ;;
    steering_prompt)
      if [[ -n "${STEERING_PROMPT:-}" ]]; then
        printf '%s' "$STEERING_PROMPT" | base64 -d 2>/dev/null
      else
        printf ''
      fi
      ;;
    *) return 1 ;;
  esac
}

# _ia::part_file <id> <manifest_file> — prints the file backing <id> per the
# manifest, or nothing (exit 1) if the manifest has no entry for it.
_ia::part_file() {
  local id="$1" manifest_file="$2"
  [[ -f "$manifest_file" ]] || return 1
  local file
  file="$(jq -r --arg id "$id" '.parts[]? | select(.id == $id) | .file' "$manifest_file" 2>/dev/null | head -1)" || return 1
  [[ -n "$file" ]] || return 1
  printf '%s' "$file"
}

interpolate_artifacts::render() {
  local body_file="$1" manifest_file="${2:-/tmp/context-manifest.json}"
  local body
  _ia::slurp "$body_file" body

  if [[ "$body" != *'{{'* ]]; then
    printf '%s' "$body"
    return 0
  fi

  local remaining="$body" out="" before after id
  while [[ "$remaining" == *'{{'* ]]; do
    before="${remaining%%\{\{*}"
    after="${remaining#*\{\{}"
    if [[ "$after" != *'}}'* ]]; then
      # Unterminated `{{` — no matching close; leave the rest as literal text.
      out+="$before"'{{'"$after"
      remaining=""
      break
    fi
    id="${after%%\}\}*}"
    remaining="${after#*\}\}}"
    out+="$before"

    local replacement="" resolved=1
    if replacement="$(_ia::scalar "$id")"; then
      :
    else
      local part_file
      if part_file="$(_ia::part_file "$id" "$manifest_file")" && [[ -f "$part_file" ]]; then
        _ia::slurp "$part_file" replacement
      else
        resolved=0
      fi
    fi

    if [[ "$resolved" -eq 1 ]]; then
      out+="$replacement"
    else
      echo "::warning::interpolate-artifacts: placeholder '{{$id}}' is unknown or not materialized — replacing with a marker." >&2
      out+='_(artifact "'"$id"'" unavailable)_'
    fi
  done
  out+="$remaining"

  printf '%s' "$out"
}

interpolate_artifacts::list() {
  local body_file="$1"
  local body
  _ia::slurp "$body_file" body

  local remaining="$body" after id
  declare -A seen=()
  while [[ "$remaining" == *'{{'* ]]; do
    after="${remaining#*\{\{}"
    [[ "$after" == *'}}'* ]] || break
    id="${after%%\}\}*}"
    remaining="${after#*\}\}}"
    if [[ -n "$id" && -z "${seen[$id]:-}" ]]; then
      seen["$id"]=1
      printf '%s\n' "$id"
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    render)
      shift
      [[ $# -ge 1 ]] || { echo "Usage: interpolate-artifacts.sh render <body_file|-> [manifest_file]" >&2; exit 1; }
      interpolate_artifacts::render "$@"
      ;;
    list)
      shift
      [[ $# -ge 1 ]] || { echo "Usage: interpolate-artifacts.sh list <body_file|->" >&2; exit 1; }
      interpolate_artifacts::list "$@"
      ;;
    *)
      echo "Usage: interpolate-artifacts.sh render <body_file|-> [manifest_file] | list <body_file|->" >&2
      exit 1
      ;;
  esac
fi
