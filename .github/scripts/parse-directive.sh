#!/usr/bin/env bash
# =============================================================================
# Parse /agents directive from a comment body
# =============================================================================
#
# PURPOSE
# -------
# Extracts the slash-command directive from $COMMENT_BODY and emits
# $GITHUB_OUTPUT-style key=value lines for consumption by a workflow step.
#
# INPUT
# -----
# COMMENT_BODY    (env) The full comment body to parse.
#
# OUTPUT (stdout, one key=value per line)
# ---------------------------------------
# command         plan | start | work | fix | revert | close (empty if no match)
# model           claude-opus-4-7 | claude-sonnet-4-6 | claude-haiku-4-5-20251001
# reasoning       off | low | medium | high | max
# think_phrase    the "think hard" phrase suitable for injecting into prompts
#
# USAGE IN WORKFLOWS
# ------------------
#   - name: Parse directive
#     id: directive
#     env:
#       COMMENT_BODY: ${{ github.event.comment.body }}
#     run: |
#       .github/scripts/parse-directive.sh >> "$GITHUB_OUTPUT"
#
#   # Downstream steps:
#   # ${{ steps.directive.outputs.command }}
#   # ${{ steps.directive.outputs.model }}
#
# SYNTAX SUPPORTED
# ----------------
#   /agents <command> [model] [reasoning]
#
# command:    plan | start | work | fix | revert | close
# model:      opus | sonnet | haiku             (default: opus)
# reasoning:  off|none|no-think | low | med|medium | high | max|ultra|ultrathink
#             (default: high)
#
# Args can appear in any order after the command. Unknown tokens are ignored.
# If no /agents directive is found on any line, command is emitted empty and
# defaults for model/reasoning are still emitted so callers can use them
# safely.
# =============================================================================

set -euo pipefail

BODY="${COMMENT_BODY:-}"

# Match the first line that begins with `/agents <something>`. Anchored at
# line start to avoid matching the literal string in prose or quoted examples.
DIRECTIVE=$(printf '%s\n' "$BODY" | grep -oE '^/agents[[:space:]]+[^[:space:]]+.*' | head -1 || echo "")

COMMAND=""
MODEL="claude-opus-4-7"
REASONING="high"

if [[ -n "$DIRECTIVE" ]]; then
  read -ra TOKENS <<< "$DIRECTIVE"
  # TOKENS[0] = "/agents"
  # TOKENS[1] = command
  # TOKENS[2..] = args
  COMMAND="${TOKENS[1]:-}"
  COMMAND=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')

  for tok in "${TOKENS[@]:2}"; do
    t=$(echo "$tok" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')
    case "$t" in
      opus)                    MODEL="claude-opus-4-7" ;;
      sonnet)                  MODEL="claude-sonnet-4-6" ;;
      haiku)                   MODEL="claude-haiku-4-5-20251001" ;;
      off|none|no-think)       REASONING="off" ;;
      low)                     REASONING="low" ;;
      med|medium)              REASONING="medium" ;;
      high)                    REASONING="high" ;;
      max|ultra|ultrathink)    REASONING="max" ;;
    esac
  done
fi

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
