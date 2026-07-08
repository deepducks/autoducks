#!/usr/bin/env bash
# Regression test: the "Run LLM agent" step must be id: llm, and its
# error_subtype output must be forwarded into Post-execution's env as
# LLM_ERROR_SUBTYPE, in both the runtime source and the .github mirror.
# Run: bash test/unit-llm-error-subtype-wiring.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

FILES=(
  ".autoducks/runtimes/github-actions/autoducks-developer.yml"
  ".autoducks/runtimes/github-actions/autoducks-fix.yml"
  ".github/workflows/autoducks-developer.yml"
  ".github/workflows/autoducks-fix.yml"
)

# Prints the lines of the step starting at a "- name: <step_name>" line, up
# to (but excluding) the next step at the same indentation.
step_block() {
  local path="$1" step_name="$2"
  awk -v step="- name: $step_name" '
    $0 ~ "^      " step "$" { in_block=1; print; next }
    in_block && /^      - name:/ { exit }
    in_block { print }
  ' "$path"
}

for f in "${FILES[@]}"; do
  path="$REPO_ROOT/$f"

  if step_block "$path" "Run LLM agent" | grep -qE '^\s*id: llm\s*$'; then
    pass "$f: Run LLM agent step has id: llm"
  else
    fail "$f: Run LLM agent step is missing id: llm"
  fi

  if step_block "$path" "Post-execution" | grep -qF 'LLM_ERROR_SUBTYPE: ${{ steps.llm.outputs.error_subtype }}'; then
    pass "$f: Post-execution env sets LLM_ERROR_SUBTYPE"
  else
    fail "$f: Post-execution env is missing LLM_ERROR_SUBTYPE"
  fi
done

echo ""
echo "═══ llm-error-subtype-wiring: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
