#!/usr/bin/env bash
set -euo pipefail

: "${AUTODUCKS_AGENT:?AUTODUCKS_AGENT env var required}"

# Honor AUTODUCKS_ROOT like load-config.sh does (#167); fall back to the
# repo-root-relative default used by the workflow steps.
_root="${AUTODUCKS_ROOT:-.autoducks}"
_cfg="$_root/agents/${AUTODUCKS_AGENT}/defaults.json"
_global="$_root/autoducks.json"
_model=$(jq -r '.model // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.model // empty' "$_global")
_effort=$(jq -r '.effort // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.effort // empty' "$_global")
_max_turns=$(jq -r '.max_turns // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.max_turns // empty' "$_global")

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
