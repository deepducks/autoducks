#!/usr/bin/env bash
set -euo pipefail

# ── Generate custom-alias trigger clauses ───────────────────────────
# Reads .autoducks/autoducks.json `triggers.<agent>[]` and emits the
# startsWith(...) expression fragments for the requested agent, ready to
# splice into that agent's workflow `if:` guard.
#
# GitHub's expression engine cannot read repository files, so per-team custom
# aliases must be baked into the workflow YAML at setup time. This script is
# the fragment generator used by the patcher in scripts/update-triggers.sh
# (and at install time).
#
# Usage:
#   AUTODUCKS_AGENT=design bash generate-trigger-conditions.sh
#
# Output (stdout): one clause per custom alias, e.g.
#   startsWith(github.event.comment.body, '/agents go') ||
#   startsWith(github.event.comment.body, '/agents ship') ||
#
# Emits nothing when the agent has no custom aliases. Every invocation first
# validates the ENTIRE triggers block (format + collisions) and hard-fails on
# any violation, so a bad config can never be silently baked into the guards.

CONFIG="${AUTODUCKS_CONFIG:-.autoducks/autoducks.json}"

if ! command -v jq &>/dev/null; then
  echo "generate-trigger-conditions: jq is required but not installed" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "generate-trigger-conditions: $CONFIG not found" >&2
  exit 1
fi

# Config keys that may carry custom aliases.
AGENTS=(design tactical execute fix revert close)

# The complete forbidden set: canonical verbs AND built-in aliases. A custom
# alias may collide with none of these.
BUILTINS="design plan devise drilldown specify execute work run start fix revert close"

# ── Validate the entire triggers block ──────────────────────────────
validate_triggers() {
  local agent alias
  declare -A seen=()

  for agent in "${AGENTS[@]}"; do
    # `.triggers[$a][]?` yields nothing for absent keys; `// empty` guards a
    # null value. Non-array values make jq error, which we surface.
    while IFS= read -r alias; do
      [[ -z "$alias" ]] && continue

      if [[ ! "$alias" =~ ^[a-z0-9-]+$ ]]; then
        echo "trigger validation: alias '$alias' (agent '$agent') is not lowercase [a-z0-9-]+" >&2
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

# ── Emit clauses for the requested agent ────────────────────────────
AGENT="${AUTODUCKS_AGENT:-}"
if [[ -z "$AGENT" ]]; then
  # No specific agent requested: validation-only mode.
  exit 0
fi

case " ${AGENTS[*]} " in
  *" $AGENT "*) : ;;
  *) echo "generate-trigger-conditions: unknown agent '$AGENT'" >&2; exit 1 ;;
esac

while IFS= read -r alias; do
  [[ -z "$alias" ]] && continue
  printf "startsWith(github.event.comment.body, '/agents %s') ||\n" "$alias"
done < <(jq -r --arg a "$AGENT" '.triggers[$a][]? // empty' "$CONFIG")
