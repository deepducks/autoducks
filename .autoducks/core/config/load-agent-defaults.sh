#!/usr/bin/env bash
set -euo pipefail

: "${AUTODUCKS_AGENT:?AUTODUCKS_AGENT env var required}"

# Honor AUTODUCKS_ROOT like load-config.sh does (#167); fall back to the
# repo-root-relative default used by the workflow steps.
_root="${AUTODUCKS_ROOT:-.autoducks}"
_cfg="$_root/agents/${AUTODUCKS_AGENT}/defaults.json"
_global="$_root/autoducks.json"
# Per-agent value wins; the repo-wide default fills the gap when the agent's
# file omits the key.
#
# `a || b` cannot express that: jq on a valid file that simply lacks the key
# exits 0 and prints nothing, so the fallback never runs and the repo-wide
# default is silently discarded. It only fired when the agent file was missing
# or malformed — i.e. never, in practice. Test emptiness instead, which is what
# the tools_default block below already does correctly.
_agent_key() { jq -r "${1} // empty" "$_cfg" 2>/dev/null || true; }
_global_key() { jq -r "${1} // empty" "$_global" 2>/dev/null || true; }

_model=$(_agent_key '.model')
[[ -z "$_model" ]] && _model=$(_global_key '.defaults.model')
_effort=$(_agent_key '.effort')
[[ -z "$_effort" ]] && _effort=$(_global_key '.defaults.effort')
_max_turns=$(_agent_key '.max_turns')
[[ -z "$_max_turns" ]] && _max_turns=$(_global_key '.defaults.max_turns')

# Universal default grant, overridable per-agent via "tools_default".
_tools_default="$(jq -c '.tools_default // empty' "$_cfg" 2>/dev/null || echo '')"
[[ -z "$_tools_default" || "$_tools_default" == "null" ]] \
  && _tools_default="$(jq -c '.defaults.tools // []' "$_global")"

# Per-agent base grant.
_agent_tools="$(jq -c '.tools // []' "$_cfg" 2>/dev/null || echo '[]')"

# Effective = unique(agent base ∪ universal default), order-stable, CSV.
_tools="$(jq -rn \
  --argjson a "$_agent_tools" --argjson d "$_tools_default" \
  '($a + $d) | unique_by(.) | join(",")' 2>/dev/null || true)"

echo "model=${_model:-claude-sonnet-5}"
echo "effort=${_effort:-high}"
echo "max_turns=${_max_turns:-}"
echo "tools=${_tools}"
