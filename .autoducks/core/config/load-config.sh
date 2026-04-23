#!/usr/bin/env bash
set -euo pipefail

# ── Locate .autoducks root ──────────────────────────────────────────
if [[ -n "${AUTODUCKS_ROOT:-}" ]]; then
  : # already set by caller
else
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Walk up until we find autoducks.json (max 10 levels)
  _depth=0
  while [[ "$_depth" -lt 10 ]]; do
    if [[ -f "$_dir/autoducks.json" ]]; then
      AUTODUCKS_ROOT="$_dir"
      break
    fi
    _dir="$(dirname "$_dir")"
    (( _depth++ ))
  done
  if [[ -z "${AUTODUCKS_ROOT:-}" ]]; then
    echo "load-config: could not find autoducks.json" >&2
    exit 1
  fi
fi
export AUTODUCKS_ROOT

# ── Read config ─────────────────────────────────────────────────────
_config="$AUTODUCKS_ROOT/autoducks.json"
if [[ ! -f "$_config" ]]; then
  echo "load-config: $_config not found" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "load-config: jq is required but not installed" >&2
  exit 1
fi

# ── Provider env vars ───────────────────────────────────────────────
export AUTODUCKS_ITS_PROVIDER
AUTODUCKS_ITS_PROVIDER="$(jq -r '.providers.its // empty' "$_config")"

export AUTODUCKS_GIT_PROVIDER
AUTODUCKS_GIT_PROVIDER="$(jq -r '.providers.git // empty' "$_config")"

export AUTODUCKS_LLM_PROVIDER
AUTODUCKS_LLM_PROVIDER="$(jq -r '.providers.llm // empty' "$_config")"

# ── Defaults (global + per-agent override) ─────────────────────────
_agent_defaults="{}"
if [[ -n "${AUTODUCKS_AGENT:-}" ]]; then
  _agent_config="$AUTODUCKS_ROOT/agents/$AUTODUCKS_AGENT/defaults.json"
  if [[ -f "$_agent_config" ]]; then
    _agent_defaults="$(cat "$_agent_config")"
  fi
fi

_merged="$(jq -s '.[0].defaults * .[1]' "$_config" <(echo "$_agent_defaults"))"

export AUTODUCKS_MODEL
AUTODUCKS_MODEL="$(echo "$_merged" | jq -r '.model // empty')"

export AUTODUCKS_REASONING
AUTODUCKS_REASONING="$(echo "$_merged" | jq -r '.reasoning // empty')"

export AUTODUCKS_BASE_BRANCH
AUTODUCKS_BASE_BRANCH="$(echo "$_merged" | jq -r '.base_branch // empty')"

# ── Source provider interfaces ──────────────────────────────────────
source "$AUTODUCKS_ROOT/providers/its/interface.sh"
source "$AUTODUCKS_ROOT/providers/git/interface.sh"

# Only source LLM interface outside GitHub Actions runtime
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  source "$AUTODUCKS_ROOT/providers/llm/interface.sh"
fi
