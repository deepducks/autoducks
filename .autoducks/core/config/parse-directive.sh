#!/usr/bin/env bash
set -euo pipefail

# ── Parse slash-command directive ────────────────────────────────────
# Provider-agnostic: pure text parsing, no gh/git calls.
#
# Input:  COMMENT_BODY env var (or stdin)
# Output: key=value lines to stdout
#   command          — canonical verb: architect, engineer, execute, fix, revert, close, review, rework, defer, resolve
#   original_command — the raw verb the user typed, before alias normalization
#   model            — claude-opus-5, claude-sonnet-5, claude-haiku-4-5, or empty
#   effort           — off, low, medium, high, max, or empty
#   max_turns        — positive integer within a sane upper bound, or empty.
#                       Set via a `turns=<n>`, `max-turns=<n>`, `max_turns=<n>`,
#                       or `turns:<n>` token (digits only; malformed/out-of-range
#                       values are ignored, not fatal).
#   max_iterations   — integer in [1, 10], or empty. Set via an `iters:<n>` or
#                       `iterations:<n>` token (digits only; malformed/out-of-range
#                       values are ignored, not fatal).
#   mode             — waves, sequential, or empty. Set via a `mode:<value>`
#                       token (colon form only); friendly synonyms fan-out/
#                       fanout→waves and seq→sequential are also accepted.
#                       Invalid values are ignored, not fatal.
#   auto_chain       — `+`-separated canonical verbs to run after this agent
#                       finishes, from a `#auto:<verb>[+<verb>...]` token.
#                       Verbs are alias-normalized, deduplicated, capped at 5.
#   steering_prompt  — base64-encoded free-text remainder of the comment:
#                       everything on the first directive line after the
#                       verb and any leading recognized directive tokens
#                       (model:/effort:/turns:/positional aliases/#auto:),
#                       plus every subsequent line of the comment body,
#                       verbatim. Empty (empty string, still base64 of
#                       nothing) when the comment is directive-only.
#
# The slash-command namespace is configurable via `command` in
# autoducks.json (default `""` — bare short forms like `/architect`). When a
# namespace is set (e.g. `"quack"`), directives take the two-token form
# `/quack architect`. Command normalization: built-in synonyms
# (design→architect, tactics→engineer, run/work→execute) and per-agent custom
# aliases from `triggers.<agent>[]` are resolved to their canonical verb here,
# so every downstream `command=` consumer sees a consistent value.
#
# Empty model/effort/max_turns means "no override" — the caller's `||` chain
# falls through to agent defaults / global config / provider action default.

BODY="${COMMENT_BODY:-$(cat)}"

_CONFIG_FILE="${AUTODUCKS_CONFIG:-.autoducks/autoducks.json}"

# Command namespace (validated; falls back to empty — bare short forms — on
# garbage). NAMESPACE = command with a single optional leading '/' stripped.
NAMESPACE=""
if [[ -f "$_CONFIG_FILE" ]] && command -v jq &>/dev/null; then
  NAMESPACE=$(jq -r '.command // ""' "$_CONFIG_FILE" 2>/dev/null || true)
fi
[[ "$NAMESPACE" =~ ^$|^/?[a-z0-9-]+$ ]] || NAMESPACE=""
NAMESPACE="${NAMESPACE#/}"

# Namespace set:   directive line is `/<namespace> <verb> ...`
# Namespace empty: directive line is any line starting with `/<verb> ...`
if [[ -n "$NAMESPACE" ]]; then
  _DIRECTIVE_RE="^/${NAMESPACE}[[:space:]]+[^[:space:]]+.*"
else
  _DIRECTIVE_RE="^/[^[:space:]]+.*"
fi

DIRECTIVE=$(printf '%s\n' "$BODY" \
  | grep -oE "$_DIRECTIVE_RE" \
  | head -1 || echo "")

COMMAND=""
ORIGINAL_COMMAND=""
MODEL=""
EFFORT=""
MAX_TURNS=""
MAX_ITERATIONS=""
MODE=""
AUTO_CHAIN=""
STEERING_LEFTOVER=()
TRAILING_BODY=""

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
    for _agent in architect engineer execute fix revert close review rework defer resolve; do
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
    architect|engineer|execute|fix|revert|close|review|rework|defer|resolve) return 0 ;;
    *) return 1 ;;
  esac
}

# Verbs that can appear in a #auto: chain: they MUST have a workflow_dispatch
# entry point and a chain::_workflow_for mapping. Utilities (fix/revert/close)
# are comment-only (no workflow_dispatch) and are intentionally excluded.
is_chainable_verb() {
  case "$1" in
    architect|engineer|execute|review) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Steering-prompt token classifier ─────────────────────────────────
# Mirrors the recognized-token forms matched by the directive-token loop
# below, without mutating any state. Used only to decide which leading
# tokens on the directive line are directive syntax (and so stripped from
# the steering prompt) versus free-text prose (kept verbatim).
is_directive_token() {
  local tok="$1" _lc _t
  _lc=$(echo "$tok" | tr '[:upper:]' '[:lower:]')
  [[ "$_lc" =~ ^#auto:(.+)$ ]] && return 0
  [[ "$_lc" =~ ^model:(.+)$ ]] && return 0
  [[ "$_lc" =~ ^effort:(.+)$ ]] && return 0
  [[ "$_lc" =~ ^turns:([0-9]+)$ ]] && return 0
  [[ "$_lc" =~ ^iters:([0-9]+)$ ]] && return 0
  [[ "$_lc" =~ ^iterations:([0-9]+)$ ]] && return 0
  [[ "$_lc" =~ ^mode:(.+)$ ]] && return 0
  _t=$(echo "$_lc" | tr -d ',.!?:;#')
  case "$_t" in
    opus|sonnet|haiku) return 0 ;;
    off|none|no-think|low|med|medium|high|max|ultra|ultrathink) return 0 ;;
    turns=*|max-turns=*|max_turns=*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -n "$DIRECTIVE" ]]; then
  read -ra TOKENS <<< "$DIRECTIVE"
  if [[ -n "$NAMESPACE" ]]; then
    COMMAND="${TOKENS[1]:-}"
    ARG_START=2
  else
    COMMAND="${TOKENS[0]:-}"
    COMMAND="${COMMAND#/}"
    ARG_START=1
  fi
  COMMAND=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | tr -d ',.!?:;')
  ORIGINAL_COMMAND="$COMMAND"
  COMMAND=$(normalize_verb "$COMMAND")

  for tok in "${TOKENS[@]:$ARG_START}"; do
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
        is_chainable_verb "$_v" || continue
        # dedupe (loop protection: a verb may appear at most once in a chain)
        case "+${_chain_out}+" in *"+${_v}+"*) continue ;; esac
        if (( _count >= 5 )); then break; fi
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
        opus)     MODEL="claude-opus-5" ;;
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
      if (( _v > 0 && _v <= 1000 )); then MAX_TURNS="$_v"; fi
      continue
    fi
    if [[ "$_lc" =~ ^iters:([0-9]+)$ || "$_lc" =~ ^iterations:([0-9]+)$ ]]; then
      _v="${BASH_REMATCH[1]}"
      (( _v >= 1 && _v <= 10 )) && MAX_ITERATIONS="$_v"
      continue
    fi
    if [[ "$_lc" =~ ^mode:(.+)$ ]]; then
      _md=$(echo "${BASH_REMATCH[1]}" | tr -d ',.!?;')
      case "$_md" in
        waves|sequential) MODE="$_md" ;;
        fan-out|fanout)   MODE="waves" ;;
        seq)              MODE="sequential" ;;
      esac
      continue
    fi

    t=$(echo "$_lc" | tr -d ',.!?:;#')
    case "$t" in
      # Model aliases (positional)
      opus)                    MODEL="claude-opus-5" ;;
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
        if [[ "$_v" =~ ^[0-9]+$ ]] && (( _v > 0 && _v <= 1000 )); then MAX_TURNS="$_v"; fi ;;
    esac
  done

  # ── Steering prompt: capture the free-text remainder ────────────────
  # Strip a *leading run* of recognized directive tokens (verb already
  # removed via TOKENS[$ARG_START-1]); the first unrecognized token flips
  # into "prose" mode, after which every token — even one that looks like a
  # model:/effort:/turns: token — is kept verbatim, untouched.
  _in_directive_zone=1
  for tok in "${TOKENS[@]:$ARG_START}"; do
    if [[ "$_in_directive_zone" -eq 1 ]] && is_directive_token "$tok"; then
      continue
    fi
    _in_directive_zone=0
    STEERING_LEFTOVER+=("$tok")
  done

  _DIRECTIVE_LINE_NUM=$(printf '%s\n' "$BODY" \
    | grep -nE "$_DIRECTIVE_RE" | head -1 | cut -d: -f1)
  TRAILING_BODY=$(printf '%s\n' "$BODY" | tail -n +"$((_DIRECTIVE_LINE_NUM + 1))")
fi

# ── Assemble steering prompt: leftover directive-line tokens + trailing
# body lines, verbatim, trimmed of surrounding whitespace, then
# base64-encoded to a single line so it survives the $GITHUB_OUTPUT
# step-output channel unmangled.
STEERING_LINE=""
[[ ${#STEERING_LEFTOVER[@]} -gt 0 ]] && STEERING_LINE="${STEERING_LEFTOVER[*]}"

STEERING_PROMPT=""
if [[ -n "$STEERING_LINE" && -n "$TRAILING_BODY" ]]; then
  STEERING_PROMPT="${STEERING_LINE}"$'\n'"${TRAILING_BODY}"
elif [[ -n "$STEERING_LINE" ]]; then
  STEERING_PROMPT="$STEERING_LINE"
elif [[ -n "$TRAILING_BODY" ]]; then
  STEERING_PROMPT="$TRAILING_BODY"
fi

STEERING_PROMPT="${STEERING_PROMPT#"${STEERING_PROMPT%%[![:space:]]*}"}"
STEERING_PROMPT="${STEERING_PROMPT%"${STEERING_PROMPT##*[![:space:]]}"}"

STEERING_PROMPT_B64=$(printf '%s' "$STEERING_PROMPT" | base64 | tr -d '\n')

echo "command=$COMMAND"
echo "original_command=$ORIGINAL_COMMAND"
echo "model=$MODEL"
echo "effort=$EFFORT"
echo "max_turns=$MAX_TURNS"
echo "max_iterations=$MAX_ITERATIONS"
echo "mode=$MODE"
echo "auto_chain=$AUTO_CHAIN"
echo "steering_prompt=$STEERING_PROMPT_B64"
