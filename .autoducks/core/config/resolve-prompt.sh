#!/usr/bin/env bash
set -euo pipefail

# ── Resolve the assembled agent prompt ──────────────────────────────
# Provider-agnostic: emits the final prompt to stdout for the calling
# provider action to consume.
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
#   4. + plugins      — for each plugin listed in .autoducks/autoducks.json's
#                       "plugins" array, in declared order, honoring that
#                       plugin's own "targets" scope (see plugin.json). The
#                       package directory is resolved from each entry's
#                       "source" the same way apply-plugins.sh's
#                       resolve_source does: a "./relative" or
#                       ".autoducks/plugins/<name>" path is used in place,
#                       a "github:" source maps to the vendored
#                       ".autoducks/plugins/<name>" (cloned there at compile
#                       time). From that resolved dir:
#                       prompts/instructions.md is injected only when the
#                       manifest's "prompts.global" is true, and
#                       prompts/agents/<agent>/instructions.md only when
#                       "prompts.agents" lists <agent>; both appended under
#                       a single "# Plugin instructions" heading. Read
#                       directly at assembly time — no generated file.
#                       Skipped entirely when jq is absent or autoducks.json
#                       has no "plugins" array.
#
# With no .autoducks/custom/ and no enabled plugins, output is byte-for-byte
# `cat "$PROMPT_FILE"`.

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

# ── Plugin prompt fragments (declared "plugins" order in autoducks.json) ──
AUTODUCKS_CONFIG=".autoducks/autoducks.json"
PLUGIN_FRAGMENTS=()

if command -v jq &>/dev/null && [[ -f "$AUTODUCKS_CONFIG" ]]; then
  PLUGIN_ENTRIES="$(jq -c '.plugins[]? // empty' "$AUTODUCKS_CONFIG" 2>/dev/null)" || PLUGIN_ENTRIES=""

  while IFS= read -r PLUGIN_ENTRY; do
    if [[ -z "$PLUGIN_ENTRY" ]]; then
      continue
    fi

    PLUGIN_NAME="$(jq -r '.name // empty' <<< "$PLUGIN_ENTRY")"
    PLUGIN_SOURCE="$(jq -r '.source // empty' <<< "$PLUGIN_ENTRY")"
    if [[ -z "$PLUGIN_NAME" ]]; then
      continue
    fi

    # Resolve the package dir the same way apply-plugins.sh's resolve_source
    # does: "./relative" and ".autoducks/plugins/<name>" are used in place,
    # a "github:" source was vendored by the compiler to
    # ".autoducks/plugins/<name>". Best-effort — an unresolvable source
    # falls back to the vendored path rather than aborting prompt assembly.
    case "$PLUGIN_SOURCE" in
      ./*)
        PLUGIN_DIR="${PLUGIN_SOURCE#./}"
        ;;
      .autoducks/plugins/*)
        PLUGIN_DIR="$PLUGIN_SOURCE"
        ;;
      *)
        PLUGIN_DIR=".autoducks/plugins/$PLUGIN_NAME"
        ;;
    esac
    PLUGIN_MANIFEST="$PLUGIN_DIR/plugin.json"

    # No manifest, or a manifest with no "targets", targets every agent;
    # otherwise AGENT must be listed for this plugin to contribute anything.
    TARGETS_AGENT=1
    if [[ -f "$PLUGIN_MANIFEST" ]]; then
      TARGETS_AGENT="$(jq -r --arg agent "$AGENT" \
        'if (.targets // null) == null then 1 elif (.targets | index($agent)) != null then 1 else 0 end' \
        "$PLUGIN_MANIFEST" 2>/dev/null)" || TARGETS_AGENT=0
    fi
    if [[ "$TARGETS_AGENT" != "1" ]]; then
      continue
    fi

    # Injection is gated on the manifest's "prompts.global" / "prompts.agents"
    # fields (plugin.schema.json), not on file existence alone.
    PROMPTS_GLOBAL="false"
    PROMPTS_AGENT="false"
    if [[ -f "$PLUGIN_MANIFEST" ]]; then
      PROMPTS_GLOBAL="$(jq -r '(.prompts.global // false) == true' "$PLUGIN_MANIFEST" 2>/dev/null)" || PROMPTS_GLOBAL="false"
      PROMPTS_AGENT="$(jq -r --arg agent "$AGENT" \
        '(.prompts.agents // []) | index($agent) != null' \
        "$PLUGIN_MANIFEST" 2>/dev/null)" || PROMPTS_AGENT="false"
    fi

    PLUGIN_GLOBAL="$PLUGIN_DIR/prompts/instructions.md"
    PLUGIN_AGENT_INSTRUCTIONS="$PLUGIN_DIR/prompts/agents/$AGENT/instructions.md"

    if [[ "$PROMPTS_GLOBAL" == "true" && -f "$PLUGIN_GLOBAL" ]]; then
      PLUGIN_FRAGMENTS+=("$PLUGIN_GLOBAL")
    fi
    if [[ "$PROMPTS_AGENT" == "true" && -f "$PLUGIN_AGENT_INSTRUCTIONS" ]]; then
      PLUGIN_FRAGMENTS+=("$PLUGIN_AGENT_INSTRUCTIONS")
    fi
  done <<< "$PLUGIN_ENTRIES"
fi

if [[ "${#PLUGIN_FRAGMENTS[@]}" -gt 0 ]]; then
  printf '\n\n# Plugin instructions\n'
  for PLUGIN_FRAGMENT in "${PLUGIN_FRAGMENTS[@]}"; do
    printf '\n'
    cat "$PLUGIN_FRAGMENT"
  done
fi
