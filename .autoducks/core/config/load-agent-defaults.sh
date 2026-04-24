#!/usr/bin/env bash
set -euo pipefail

: "${AUTODUCKS_AGENT:?AUTODUCKS_AGENT env var required}"

_cfg=".autoducks/agents/${AUTODUCKS_AGENT}/defaults.json"
_global=".autoducks/autoducks.json"
_model=$(jq -r '.model // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.model // empty' "$_global")
_reasoning=$(jq -r '.reasoning // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.reasoning // empty' "$_global")
echo "model=${_model:-claude-sonnet-4-6}"
echo "reasoning=${_reasoning:-high}"
