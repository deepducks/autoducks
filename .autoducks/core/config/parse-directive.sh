#!/usr/bin/env bash
set -euo pipefail

# ── Parse slash-command directive ────────────────────────────────────
# Provider-agnostic: pure text parsing, no gh/git calls.
#
# Input:  COMMENT_BODY env var (or stdin)
# Output: key=value lines to stdout
#   command          — canonical verb: architect, engineer, execute, fix, revert, close
#   original_command — the raw verb the user typed, before alias normalization
#   model            — claude-opus-4-8, claude-sonnet-5, claude-haiku-4-5, or empty
#   effort           — off, low, medium, high, max, or empty
#   think_phrase     — mapped from effort level (empty when effort is empty)
#   max_turns        — positive integer within a sane upper bound, or empty.
#                       Set via a `turns=<n>`, `max-turns=<n>`, `max_turns=<n>`,
#                       or `turns:<n>` token (digits only; malformed/out-of-range
#                       values are ignored, not fatal).
#   auto_chain       — `+`-separated canonical verbs to run after this agent
#                       finishes, from a `#auto:<verb>[+<verb>...]` token.
#                       Verbs are alias-normalized, deduplicated, capped at 5.
#
# The slash-command prefix is configurable via `command` in autoducks.json
# (default `/quack`). Command normalization: built-in synonyms
# (design→architect, tactics→engineer, run/work→execute) and per-agent custom
# aliases from `triggers.<agent>[]` are resolved to their canonical verb here,
# so every downstream `command=` consumer sees a consistent value.
#
# Empty model/effort/max_turns means "no override" — the caller's `||` chain
# falls through to agent defaults / global config / provider action default.

BODY="${COMMENT_BODY:-$(cat)}"

_CONFIG_FILE="${AUTODUCKS_CONFIG:-.autoducks/autoducks.json}"

COMMAND_PREFIX="/quack"
if [[ -f "$_CONFIG_FILE" ]] && command -v jq &>/dev/null; then
  _cfg_prefix=$(jq -r '.command // empty' "$_CONFIG_FILE" 2>/dev/null || true)
  [[ "$_cfg_prefix" =~ ^/[a-z0-9-]+$ ]] && COMMAND_PREFIX="$_cfg_prefix"
fi

DIRECTIVE=$(printf '%s\n' "$BODY" \
  | grep -oE "^${COMMAND_PREFIX}[[:space:]]+[^[:space:]]+.*" \
  | head -1 || echo "")

COMMAND=""
ORIGINAL_COMMAND=""
MODEL=""
EFFORT=""
MAX_TURNS=""
AUTO_CHAIN=""

# ── Verb normalization helpers ───────────────────────────────────────
# Built-in synonyms → canonical verb. Custom aliases (config `triggers.<agent>[]`)
# resolve through the same map keyed by config key.
normalize_verb() {
  local v="$1"
  case "$v" in
    design)   v="architect" ;;
    tactics)  v="engineer"  ;;
    run|work) v="execute"   ;;
  esac
  if [[ -f "$_CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    local _agent _alias
    for _agent in architect engineer execute fix revert close; do
      while IFS= read -r _alias; do
        if [[ -n "$_alias" && "$v" == "$_alias" ]]; then
          v="$_agent"
          break 2
        fi
      done < <(jq -r --arg a "$_agent" '.triggers[$a][]? // empty' \
                 "$_CONFIG_FILE" 2>/dev/null)
    done
  fi
  printf '%s' "$v"
}

is_canonical_verb() {
  case "$1" in
    architect|engineer|execute|fix|revert|close) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -n "$DIRECTIVE" ]]; then
  read -ra TOKENS <<< "$DIRECTIVE"
  COMMAND="${TOKENS[1]:-}"
  COMMAND=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')
  ORIGINAL_COMMAND="$COMMAND"
  COMMAND=$(normalize_verb "$COMMAND")

  for tok in "${TOKENS[@]:2}"; do
    # Lowercase without stripping ':' or '#' first, so the colon syntaxes
    # (`turns:<n>`, `model:<m>`, `effort:<e>`) and `#auto:` chaining can be
    # matched below — the general strip (later) removes them for every other
    # token form.
    _lc=$(echo "$tok" | tr '[:upper:]' '[:lower:]')

    # ── #auto: chaining ──────────────────────────────────────────────
    if [[ "$_lc" =~ ^#auto:(.+)$ ]]; then
      _chain_raw="${BASH_REMATCH[1]}"
      _chain_out=""
      _count=0
      IFS='+' read -ra _verbs <<< "$_chain_raw"
      for _v in "${_verbs[@]}"; do
        _v=$(echo "$_v" | tr -d ',.!?;')
        [[ -z "$_v" ]] && continue
        _v=$(normalize_verb "$_v")
        is_canonical_verb "$_v" || continue
        # dedupe (loop protection: a verb may appear at most once in a chain)
        case "+${_chain_out}+" in *"+${_v}+"*) continue ;; esac
        (( _count >= 5 )) && break
        _chain_out="${_chain_out:+$_chain_out+}$_v"
        (( _count++ )) || true
      done
      AUTO_CHAIN="$_chain_out"
      continue
    fi

    # ── Named colon args ─────────────────────────────────────────────
    if [[ "$_lc" =~ ^model:(.+)$ ]]; then
      _m=$(echo "${BASH_REMATCH[1]}" | tr -d ',.!?;')
      case "$_m" in
        opus)     MODEL="claude-opus-4-8" ;;
        sonnet)   MODEL="claude-sonnet-5" ;;
        haiku)    MODEL="claude-haiku-4-5" ;;
        claude-*) MODEL="$_m" ;;
      esac
      continue
    fi
    if [[ "$_lc" =~ ^effort:(.+)$ ]]; then
      _e=$(echo "${BASH_REMATCH[1]}" | tr -d ',.!?;')
      case "$_e" in
        off|none|no-think)    EFFORT="off" ;;
        low)                  EFFORT="low" ;;
        med|medium)           EFFORT="medium" ;;
        high)                 EFFORT="high" ;;
        max|ultra|ultrathink) EFFORT="max" ;;
      esac
      continue
    fi
    if [[ "$_lc" =~ ^turns:([0-9]+)$ ]]; then
      _v="${BASH_REMATCH[1]}"
      (( _v > 0 && _v <= 1000 )) && MAX_TURNS="$_v"
      continue
    fi

    t=$(echo "$_lc" | tr -d ',.!?:;#')
    case "$t" in
      # Model aliases (positional)
      opus)                    MODEL="claude-opus-4-8" ;;
      sonnet)                  MODEL="claude-sonnet-5" ;;
      haiku)                   MODEL="claude-haiku-4-5" ;;
      # Effort aliases (positional)
      off|none|no-think)       EFFORT="off" ;;
      low)                     EFFORT="low" ;;
      med|medium)              EFFORT="medium" ;;
      high)                    EFFORT="high" ;;
      max|ultra|ultrathink)    EFFORT="max" ;;
      # max_turns override — digits only; a sane upper bound rejects absurd
      # values (defense-in-depth against runaway cost). `turns:<n>` is handled
      # above, before ':' is stripped.
      turns=*|max-turns=*|max_turns=*)
        _v="${t#*=}"
        [[ "$_v" =~ ^[0-9]+$ ]] && (( _v > 0 && _v <= 1000 )) && MAX_TURNS="$_v" ;;
    esac
  done
fi

# ── Map effort level → think phrase ──────────────────────────────────
# Empty EFFORT must yield empty THINK_PHRASE so downstream defaults win.
THINK_PHRASE=""
case "$EFFORT" in
  off)    THINK_PHRASE="" ;;
  low)    THINK_PHRASE="Think before writing." ;;
  medium) THINK_PHRASE="Think hard before writing." ;;
  high)   THINK_PHRASE="Think very hard before writing." ;;
  max)    THINK_PHRASE="Ultrathink — take extensive time to reason before writing." ;;
esac

echo "command=$COMMAND"
echo "original_command=$ORIGINAL_COMMAND"
echo "model=$MODEL"
echo "effort=$EFFORT"
echo "think_phrase=$THINK_PHRASE"
echo "max_turns=$MAX_TURNS"
echo "auto_chain=$AUTO_CHAIN"
