#!/usr/bin/env bash
set -euo pipefail

# ── Generate custom-alias trigger clauses ───────────────────────────
# Reads .autoducks/autoducks.json `triggers.<agent>[]` and emits the
# startsWith(...) expression fragments for the requested agent, ready to
# splice into that agent's workflow `if:` guard.
#
# GitHub's expression engine cannot read repository files, so per-team custom
# aliases (and the configurable command namespace, `command` in
# autoducks.json — default `""`, i.e. bare short forms like `/architect`)
# must be baked into the workflow YAML at setup time. This script is the
# fragment generator used by the patcher in scripts/update-triggers.sh (and
# at install time).
#
# Invoked with no AUTODUCKS_AGENT it only validates the triggers block
# (format, collisions with built-ins, cross-agent duplicates).

CONFIG="${AUTODUCKS_CONFIG:-.autoducks/autoducks.json}"

# AUTODUCKS_AGENTS / AUTODUCKS_BUILTIN_VERBS — see agent-roster.sh. The
# roster lives in one file so this validator and parse-directive.sh's
# normalize_verb() cannot disagree about which agents exist.
_GTC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GTC_SH_DIR/agent-roster.sh"

if ! command -v jq &>/dev/null; then
  echo "generate-trigger-conditions: jq required but not installed" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "generate-trigger-conditions: $CONFIG not found" >&2
  exit 1
fi

AGENTS=("${AUTODUCKS_AGENTS[@]}")
BUILTINS="$AUTODUCKS_BUILTIN_VERBS"

# Command namespace (validated; falls back to empty — bare short forms — on
# garbage). namespace = command with a single optional leading '/' stripped.
NS="$(jq -r '.command // ""' "$CONFIG")"
[[ "$NS" =~ ^$|^/?[a-z0-9-]+$ ]] || NS=""
NS="${NS#/}"

# cmd_for TRIGGER — bake the command string for a trigger word:
#   namespace == "" ? "/<trigger>" : "/<namespace> <trigger>"
cmd_for() {
  if [[ -z "$NS" ]]; then
    printf '/%s' "$1"
  else
    printf '/%s %s' "$NS" "$1"
  fi
}

validate_triggers() {
  local agent alias
  local -A seen=()

  # A `.triggers` key naming no agent is a typo that behaves exactly like a
  # working config: the loop below only ever reads keys it already knows, so
  # `"triage-all": ["classify"]` validates, installs, and silently never fires.
  # Consumer configs also drift the other way — this repo's own carried 12 of
  # the 13 keys for a release — but a *missing* key means "no aliases", which is
  # both harmless and a legitimate thing to write, so it is not an error.
  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    case " ${AGENTS[*]} " in
      *" $key "*) : ;;
      *) echo "trigger validation: '.triggers.$key' names no agent (known: ${AGENTS[*]})" >&2; return 1 ;;
    esac
  done < <(jq -r '.triggers // {} | keys[]' "$CONFIG")

  for agent in "${AGENTS[@]}"; do
    while IFS= read -r alias; do
      [[ -z "$alias" ]] && continue
      if [[ ! "$alias" =~ ^[a-z0-9-]+$ ]]; then
        echo "trigger validation: alias '$alias' (agent '$agent') not lowercase [a-z0-9-]+" >&2
        return 1
      fi
      local b
      for b in $BUILTINS; do
        if [[ "$alias" == "$b" ]]; then
          echo "trigger validation: alias '$alias' (agent '$agent') collides with built-in verb/alias '$b'" >&2
          return 1
        fi
      done
      if [[ -n "${seen[$alias]:-}" ]]; then
        echo "trigger validation: alias '$alias' (agent '$agent') already defined for agent '${seen[$alias]}'" >&2
        return 1
      fi
      seen[$alias]="$agent"
    done < <(jq -r --arg a "$agent" '.triggers[$a][]? // empty' "$CONFIG")
  done
  return 0
}

validate_triggers

AGENT="${AUTODUCKS_AGENT:-}"
if [[ -z "$AGENT" ]]; then
  exit 0
fi
case " ${AGENTS[*]} " in
  *" $AGENT "*) : ;;
  *) echo "generate-trigger-conditions: unknown agent '$AGENT'" >&2; exit 1 ;;
esac

while IFS= read -r alias; do
  [[ -z "$alias" ]] && continue
  printf "startsWith(github.event.comment.body, '%s') ||\n" "$(cmd_for "$alias")"
done < <(jq -r --arg a "$AGENT" '.triggers[$a][]? // empty' "$CONFIG")
