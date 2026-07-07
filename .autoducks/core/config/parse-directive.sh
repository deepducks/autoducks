#!/usr/bin/env bash
set -euo pipefail

# ── Parse /agents directive ─────────────────────────────────────────
# Provider-agnostic: pure text parsing, no gh/git calls.
#
# Input:  COMMENT_BODY env var (or stdin)
# Output: key=value lines to stdout
#   command      — plan, start, work, execute, fix, revert, close, design, devise
#   model        — claude-opus-4-8, claude-sonnet-5, claude-haiku-4-5, or empty
#   reasoning    — off, low, medium, high, max, or empty
#   think_phrase — mapped from reasoning level (empty when reasoning is empty)
#
# Empty model/reasoning means "no override" — the caller's `||` chain falls
# through to agent defaults / global config / provider action default.

BODY="${COMMENT_BODY:-$(cat)}"

DIRECTIVE=$(printf '%s\n' "$BODY" \
  | grep -oE '^/agents[[:space:]]+[^[:space:]]+.*' \
  | head -1 || echo "")

COMMAND=""
MODEL=""
REASONING=""

if [[ -n "$DIRECTIVE" ]]; then
  read -ra TOKENS <<< "$DIRECTIVE"
  COMMAND="${TOKENS[1]:-}"
  COMMAND=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')

  for tok in "${TOKENS[@]:2}"; do
    t=$(echo "$tok" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')
    case "$t" in
      # Model aliases
      opus)                    MODEL="claude-opus-4-8" ;;
      sonnet)                  MODEL="claude-sonnet-5" ;;
      haiku)                   MODEL="claude-haiku-4-5" ;;
      # Reasoning aliases
      off|none|no-think)       REASONING="off" ;;
      low)                     REASONING="low" ;;
      med|medium)              REASONING="medium" ;;
      high)                    REASONING="high" ;;
      max|ultra|ultrathink)    REASONING="max" ;;
    esac
  done
fi

# ── Map reasoning level → think phrase ──────────────────────────────
# Empty REASONING must yield empty THINK_PHRASE so downstream defaults win.
THINK_PHRASE=""
case "$REASONING" in
  off)    THINK_PHRASE="" ;;
  low)    THINK_PHRASE="Think before writing." ;;
  medium) THINK_PHRASE="Think hard before writing." ;;
  high)   THINK_PHRASE="Think very hard before writing." ;;
  max)    THINK_PHRASE="Ultrathink — take extensive time to reason before writing." ;;
esac

echo "command=$COMMAND"
echo "model=$MODEL"
echo "reasoning=$REASONING"
echo "think_phrase=$THINK_PHRASE"
