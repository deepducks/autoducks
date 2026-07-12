#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/resolve-prompt.sh
#
# Exercises the repo-local prompt-override resolution chain in a sandbox
# with a fake .autoducks/ tree (real repo files are never touched):
#   1. no custom/            → output == shipped prompt, byte-for-byte
#   2. custom prompt.md      → full replacement of the base
#   3. global instructions.md → appended under its heading
#   4. per-agent instructions.md → appended after the global block
#   5. all three combined    → custom base + both appends, in order
#   6. agent name            → derived from PROMPT_FILE's parent directory
#
# Run: bash test/unit-resolve-prompt.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/resolve-prompt.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

SANDBOX="$SCRATCH/sandbox"
mkdir -p "$SANDBOX/.autoducks/agents/engineer"

ENGINEER_PROMPT_REL=".autoducks/agents/engineer/prompt.md"
SHIPPED_CONTENT=$'You are the engineer agent.\n'
printf '%s' "$SHIPPED_CONTENT" > "$SANDBOX/$ENGINEER_PROMPT_REL"

GLOBAL_CONTENT=$'Follow repo lint rules strictly.\n'
AGENT_CONTENT=$'Engineer-specific: run tests before opening a PR.\n'
CUSTOM_PROMPT_CONTENT=$'Custom engineer prompt, fully replacing the shipped one.\n'

# run_resolve [PROMPT_FILE_REL] — runs resolve-prompt.sh with cwd set to the
# sandbox root (its custom/ lookups are relative to cwd), AUTODUCKS_AGENT
# left unset so the agent name is always derived from PROMPT_FILE.
run_resolve() {
  local prompt_file="${1:-$ENGINEER_PROMPT_REL}"
  ( cd "$SANDBOX" && env -u AUTODUCKS_AGENT PROMPT_FILE="$prompt_file" bash "$SCRIPT" )
}

clean_custom() {
  rm -rf "$SANDBOX/.autoducks/custom"
}

# assert_file_eq LABEL EXPECTED_FILE ACTUAL_FILE
assert_file_eq() {
  local label="$1" expected="$2" actual="$3"
  if diff -q "$expected" "$actual" > /dev/null 2>&1; then
    pass "$label"
  else
    fail "$label — diff:
$(diff "$expected" "$actual" || true)"
  fi
}

# ---------------------------------------------------------------------------
echo "── 1. no custom/ present → output is byte-for-byte the shipped prompt ──"
clean_custom
run_resolve > "$SCRATCH/out1"
assert_file_eq "output matches shipped prompt.md verbatim" \
  "$SANDBOX/$ENGINEER_PROMPT_REL" "$SCRATCH/out1"

# ---------------------------------------------------------------------------
echo "── 2. custom prompt.md → full replacement, no appends ──"
clean_custom
mkdir -p "$SANDBOX/.autoducks/custom/agents/engineer"
printf '%s' "$CUSTOM_PROMPT_CONTENT" > "$SANDBOX/.autoducks/custom/agents/engineer/prompt.md"
run_resolve > "$SCRATCH/out2"
printf '%s' "$CUSTOM_PROMPT_CONTENT" > "$SCRATCH/expected2"
assert_file_eq "output is the custom prompt with nothing appended" \
  "$SCRATCH/expected2" "$SCRATCH/out2"

# ---------------------------------------------------------------------------
echo "── 3. global instructions.md → appended under its heading ──"
clean_custom
mkdir -p "$SANDBOX/.autoducks/custom"
printf '%s' "$GLOBAL_CONTENT" > "$SANDBOX/.autoducks/custom/instructions.md"
run_resolve > "$SCRATCH/out3"
{
  printf '%s' "$SHIPPED_CONTENT"
  printf '\n\n# Repository-specific instructions\n\n'
  printf '%s' "$GLOBAL_CONTENT"
} > "$SCRATCH/expected3"
assert_file_eq "shipped prompt + global instructions under heading" \
  "$SCRATCH/expected3" "$SCRATCH/out3"

# ---------------------------------------------------------------------------
echo "── 4. global + per-agent instructions → per-agent appended after global ──"
clean_custom
mkdir -p "$SANDBOX/.autoducks/custom/agents/engineer"
printf '%s' "$GLOBAL_CONTENT" > "$SANDBOX/.autoducks/custom/instructions.md"
printf '%s' "$AGENT_CONTENT" > "$SANDBOX/.autoducks/custom/agents/engineer/instructions.md"
run_resolve > "$SCRATCH/out4"
{
  printf '%s' "$SHIPPED_CONTENT"
  printf '\n\n# Repository-specific instructions\n\n'
  printf '%s' "$GLOBAL_CONTENT"
  printf '\n\n# Repository-specific instructions (engineer)\n\n'
  printf '%s' "$AGENT_CONTENT"
} > "$SCRATCH/expected4"
assert_file_eq "global block precedes the per-agent block" \
  "$SCRATCH/expected4" "$SCRATCH/out4"

# ---------------------------------------------------------------------------
echo "── 5. all three combined → custom base + both appends, in order ──"
clean_custom
mkdir -p "$SANDBOX/.autoducks/custom/agents/engineer"
printf '%s' "$CUSTOM_PROMPT_CONTENT" > "$SANDBOX/.autoducks/custom/agents/engineer/prompt.md"
printf '%s' "$GLOBAL_CONTENT" > "$SANDBOX/.autoducks/custom/instructions.md"
printf '%s' "$AGENT_CONTENT" > "$SANDBOX/.autoducks/custom/agents/engineer/instructions.md"
run_resolve > "$SCRATCH/out5"
{
  printf '%s' "$CUSTOM_PROMPT_CONTENT"
  printf '\n\n# Repository-specific instructions\n\n'
  printf '%s' "$GLOBAL_CONTENT"
  printf '\n\n# Repository-specific instructions (engineer)\n\n'
  printf '%s' "$AGENT_CONTENT"
} > "$SCRATCH/expected5"
assert_file_eq "custom base + global append + per-agent append, in order" \
  "$SCRATCH/expected5" "$SCRATCH/out5"

# ---------------------------------------------------------------------------
echo "── 6. agent name is derived from PROMPT_FILE's parent directory ──"
clean_custom
mkdir -p "$SANDBOX/.autoducks/agents/reviewer" "$SANDBOX/.autoducks/custom/agents/reviewer"
REVIEWER_SHIPPED=$'You are the reviewer agent.\n'
REVIEWER_AGENT_CONTENT=$'Reviewer-specific: check for security issues.\n'
printf '%s' "$REVIEWER_SHIPPED" > "$SANDBOX/.autoducks/agents/reviewer/prompt.md"
printf '%s' "$REVIEWER_AGENT_CONTENT" > "$SANDBOX/.autoducks/custom/agents/reviewer/instructions.md"
run_resolve ".autoducks/agents/reviewer/prompt.md" > "$SCRATCH/out7"
{
  printf '%s' "$REVIEWER_SHIPPED"
  printf '\n\n# Repository-specific instructions (reviewer)\n\n'
  printf '%s' "$REVIEWER_AGENT_CONTENT"
} > "$SCRATCH/expected7"
assert_file_eq "AUTODUCKS_AGENT unset — 'reviewer' derived from PROMPT_FILE and its instructions.md picked up" \
  "$SCRATCH/expected7" "$SCRATCH/out7"

# ---------------------------------------------------------------------------
echo ""
echo "═══ resolve-prompt: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
