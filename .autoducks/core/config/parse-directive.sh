#!/usr/bin/env bash
set -euo pipefail

# ── Parse /agents directive ─────────────────────────────────────────
# Provider-agnostic: pure text parsing, no gh/git calls.
#
# Input:  COMMENT_BODY env var (or stdin)
# Output: key=value lines to stdout
#   command         — canonical verb: design, devise, execute, fix, revert, close
#   original_command — the raw verb the user typed, before alias normalization
#   model           — claude-opus-4-8, claude-sonnet-5, claude-haiku-4-5, or empty
#   reasoning       — off, low, medium, high, max, or empty
#   think_phrase    — mapped from reasoning level (empty when reasoning is empty)
#   max_turns       — positive integer within a sane upper bound, or empty.
#                      Set via a `turns=<n>`, `max-turns=<n>`, `max_turns=<n>`,
#                      or `turns:<n>` token (digits only; malformed/out-of-range
#                      values are ignored, not fatal).
#
# Command normalization: built-in synonyms (plan→design, drilldown/specify→devise,
# work/run/start→execute) and per-agent custom aliases from
# .autoducks/autoducks.json `triggers.<agent>[]` are resolved to their canonical
# verb here, so every downstream `command=` consumer sees a consistent value.
#
# Empty model/reasoning/max_turns means "no override" — the caller's `||` chain
# falls through to agent defaults / global config / provider action default.

BODY="${COMMENT_BODY:-$(cat)}"

DIRECTIVE=$(printf '%s\n' "$BODY" \
  | grep -oE '^/agents[[:space:]]+[^[:space:]]+.*' \
  | head -1 || echo "")

COMMAND=""
ORIGINAL_COMMAND=""
MODEL=""
REASONING=""
MAX_TURNS=""

if [[ -n "$DIRECTIVE" ]]; then
  read -ra TOKENS <<< "$DIRECTIVE"
  COMMAND="${TOKENS[1]:-}"
  COMMAND=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')

  # ── Alias → canonical verb normalization (built-in) ─────────────────
  # Aliases only ever occupy token [1]; this never touches the model/reasoning
  # token loop below (which parses tokens [2:]).
  ORIGINAL_COMMAND="$COMMAND"
  case "$COMMAND" in
    plan)                   COMMAND="design"  ;;
    drilldown|specify)      COMMAND="devise"  ;;
    work|run|start)         COMMAND="execute" ;;
  esac

  # ── Custom alias resolution (config-driven, Tier 2) ─────────────────
  # Read the same config the setup-time generator baked into the workflow
  # guards, and resolve any custom alias to its canonical verb. Guarded so a
  # missing/malformed `triggers` key cannot abort this sourced script
  # (runs under `set -euo pipefail`).
  if [[ -f ".autoducks/autoducks.json" ]] && command -v jq &>/dev/null; then
    # config key → canonical verb
    declare -A _CANON=(
      [design]=design [tactical]=devise [execute]=execute
      [fix]=fix [revert]=revert [close]=close
    )
    for _agent in design tactical execute fix revert close; do
      while IFS= read -r _alias; do
        if [[ -n "$_alias" && "$COMMAND" == "$_alias" ]]; then
          COMMAND="${_CANON[$_agent]}"
          break 2
        fi
      done < <(jq -r --arg a "$_agent" '.triggers[$a][]? // empty' \
                .autoducks/autoducks.json 2>/dev/null)
    done
  fi

  for tok in "${TOKENS[@]:2}"; do
    # Lowercase without stripping ':' first, so the `turns:<n>` colon syntax
    # can still be matched below — the general strip (next line) removes ':'
    # along with other trailing punctuation for every other token form.
    _lc=$(echo "$tok" | tr '[:upper:]' '[:lower:]')
    if [[ "$_lc" =~ ^turns:([0-9]+)$ ]]; then
      _v="${BASH_REMATCH[1]}"
      (( _v > 0 && _v <= 1000 )) && MAX_TURNS="$_v"
    fi
    t=$(echo "$_lc" | tr -d ',.!?:;')
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
      # max_turns override — digits only; a sane upper bound rejects absurd
      # values (defense-in-depth against runaway cost). `turns:<n>` is handled
      # above, before ':' is stripped.
      turns=*|max-turns=*|max_turns=*)
        _v="${t#*=}"
        [[ "$_v" =~ ^[0-9]+$ ]] && (( _v > 0 && _v <= 1000 )) && MAX_TURNS="$_v" ;;
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
echo "original_command=$ORIGINAL_COMMAND"
echo "model=$MODEL"
echo "reasoning=$REASONING"
echo "think_phrase=$THINK_PHRASE"
echo "max_turns=$MAX_TURNS"
