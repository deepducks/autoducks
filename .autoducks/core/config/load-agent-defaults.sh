#!/usr/bin/env bash
set -euo pipefail

: "${AUTODUCKS_AGENT:?AUTODUCKS_AGENT env var required}"

_root="${AUTODUCKS_ROOT:-.autoducks}"
_cfg="$_root/agents/${AUTODUCKS_AGENT}/defaults.json"
_global="$_root/autoducks.json"
_model=$(jq -r '.model // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.model // empty' "$_global")
_reasoning=$(jq -r '.reasoning // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.reasoning // empty' "$_global")
echo "model=${_model:-claude-sonnet-5}"
echo "reasoning=${_reasoning:-high}"
