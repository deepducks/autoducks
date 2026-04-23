#!/usr/bin/env bash
set -euo pipefail

# LLM provider interface
# Sources the concrete implementation from providers/llm/$AUTODUCKS_LLM_PROVIDER/
#
# Note: in GitHub Actions the actual LLM invocation is handled by the
# composite action, not by shell.  This interface exists for non-GHA
# runtimes or testing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${AUTODUCKS_LLM_PROVIDER:?AUTODUCKS_LLM_PROVIDER must be set (e.g. \"claude-code\")}"

PROVIDER_DIR="${SCRIPT_DIR}/${AUTODUCKS_LLM_PROVIDER}"

if [[ ! -d "$PROVIDER_DIR" ]]; then
  echo "ERROR: LLM provider directory not found: ${PROVIDER_DIR}" >&2
  exit 1
fi

# Source all .sh files from the provider implementation directory
for f in "${PROVIDER_DIR}"/*.sh; do
  [[ -f "$f" ]] || continue
  # shellcheck source=/dev/null
  source "$f"
done

# ── Required function signatures ──────────────────────────────────────────
#
#   llm::invoke_agent(prompt_file, model, reasoning)  → exit code

REQUIRED_FUNCTIONS=(
  "llm::invoke_agent"
)

missing=0
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  if [[ "$(type -t "$fn" 2>/dev/null)" != "function" ]]; then
    echo "ERROR: LLM provider '${AUTODUCKS_LLM_PROVIDER}' does not implement required function: ${fn}" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
