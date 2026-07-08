#!/usr/bin/env bash
set -euo pipefail

: "${AUTODUCKS_AGENT:?AUTODUCKS_AGENT env var required}"

_cfg=".autoducks/agents/${AUTODUCKS_AGENT}/defaults.json"
_global=".autoducks/autoducks.json"
_model=$(jq -r '.model // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.model // empty' "$_global")
_effort=$(jq -r '.effort // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.effort // empty' "$_global")
_max_turns=$(jq -r '.max_turns // empty' "$_cfg" 2>/dev/null || jq -r '.defaults.max_turns // empty' "$_global")
echo "model=${_model:-claude-sonnet-5}"
echo "effort=${_effort:-high}"
echo "max_turns=${_max_turns:-}"
