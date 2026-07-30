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

if ! command -v jq &>/dev/null; then
  echo "generate-trigger-conditions: jq required but not installed" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "generate-trigger-conditions: $CONFIG not found" >&2
  exit 1
fi

AGENTS=(architect engineer execute fix revert close review rework defer resolve triage merge update)
BUILTINS="architect design engineer tactics execute run work fix revert close review rework defer resolve triage merge update"

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
