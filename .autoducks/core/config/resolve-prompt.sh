#!/usr/bin/env bash
set -euo pipefail

# ── Resolve the assembled agent prompt ──────────────────────────────
# Provider-agnostic: emits the final prompt to stdout for the calling
# provider action to substitute {{THINK_PHRASE}} into.
#
# Input:  PROMPT_FILE     — shipped prompt path, e.g. .autoducks/agents/engineer/prompt.md
#         AUTODUCKS_AGENT — agent name (optional; derived from PROMPT_FILE's
#                            parent directory when unset)
#
# Resolution (repo-local overrides under .autoducks/custom/), each step
# optional and skipped when its file is absent:
#   1. base          — .autoducks/custom/agents/<agent>/prompt.md if present,
#                       else PROMPT_FILE verbatim
#   2. + global       — .autoducks/custom/instructions.md, appended under
#                       "# Repository-specific instructions"
#   3. + per-agent    — .autoducks/custom/agents/<agent>/instructions.md,
#                       appended under "# Repository-specific instructions (<agent>)"
#
# {{THINK_PHRASE}} is left untouched; the caller substitutes it after assembly.
# With no .autoducks/custom/ present, output is byte-for-byte `cat "$PROMPT_FILE"`.

: "${PROMPT_FILE:?PROMPT_FILE env var required}"

AGENT="${AUTODUCKS_AGENT:-$(basename "$(dirname "$PROMPT_FILE")")}"

CUSTOM_ROOT=".autoducks/custom"
CUSTOM_PROMPT="$CUSTOM_ROOT/agents/$AGENT/prompt.md"
GLOBAL_INSTRUCTIONS="$CUSTOM_ROOT/instructions.md"
AGENT_INSTRUCTIONS="$CUSTOM_ROOT/agents/$AGENT/instructions.md"

if [[ -f "$CUSTOM_PROMPT" ]]; then
  cat "$CUSTOM_PROMPT"
else
  cat "$PROMPT_FILE"
fi

if [[ -f "$GLOBAL_INSTRUCTIONS" ]]; then
  printf '\n\n# Repository-specific instructions\n\n'
  cat "$GLOBAL_INSTRUCTIONS"
fi

if [[ -f "$AGENT_INSTRUCTIONS" ]]; then
  printf '\n\n# Repository-specific instructions (%s)\n\n' "$AGENT"
  cat "$AGENT_INSTRUCTIONS"
fi
