#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/parse-directive.sh
# Run: bash test/unit-parse-directive.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/parse-directive.sh"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: run the script with a given COMMENT_BODY and assert each of the
# four output lines matches exactly.
# ---------------------------------------------------------------------------
run_case() {
  local label="$1"
  local body="$2"
  local exp_command="$3"
  local exp_model="$4"
  local exp_reasoning="$5"
  local exp_think="$6"

  echo "[$label]"
  local out
  out=$(COMMENT_BODY="$body" bash "$SCRIPT" </dev/null)

  local got_command got_model got_reasoning got_think
  got_command=$(printf '%s\n' "$out" | grep '^command=' || true)
  got_model=$(printf '%s\n' "$out" | grep '^model=' || true)
  got_reasoning=$(printf '%s\n' "$out" | grep '^reasoning=' || true)
  got_think=$(printf '%s\n' "$out" | grep '^think_phrase=' || true)

  local want_command="command=$exp_command"
  local want_model="model=$exp_model"
  local want_reasoning="reasoning=$exp_reasoning"
  local want_think="think_phrase=$exp_think"

  if [[ "$got_command" == "$want_command" ]]; then
    pass "command line matches ($got_command)"
  else
    fail "command mismatch — want '$want_command', got '$got_command'"
  fi
  if [[ "$got_model" == "$want_model" ]]; then
    pass "model line matches ($got_model)"
  else
    fail "model mismatch — want '$want_model', got '$got_model'"
  fi
  if [[ "$got_reasoning" == "$want_reasoning" ]]; then
    pass "reasoning line matches ($got_reasoning)"
  else
    fail "reasoning mismatch — want '$want_reasoning', got '$got_reasoning'"
  fi
  if [[ "$got_think" == "$want_think" ]]; then
    pass "think_phrase line matches ($got_think)"
  else
    fail "think_phrase mismatch — want '$want_think', got '$got_think'"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: unset / no /agents line — all outputs empty
# ---------------------------------------------------------------------------
echo "[1] no /agents line — all empty"
out=$(COMMENT_BODY="" bash "$SCRIPT" </dev/null)
line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
if [[ "$line_count" == "4" ]]; then
  pass "emits exactly 4 lines"
else
  fail "expected 4 lines, got $line_count: '$out'"
fi
if [[ "$(printf '%s\n' "$out" | grep '^command=')" == "command=" ]]; then
  pass "command= is empty"
else
  fail "command not empty: '$(printf '%s\n' "$out" | grep '^command=')'"
fi
if [[ "$(printf '%s\n' "$out" | grep '^model=')" == "model=" ]]; then
  pass "model= is empty"
else
  fail "model not empty: '$(printf '%s\n' "$out" | grep '^model=')'"
fi
if [[ "$(printf '%s\n' "$out" | grep '^reasoning=')" == "reasoning=" ]]; then
  pass "reasoning= is empty"
else
  fail "reasoning not empty: '$(printf '%s\n' "$out" | grep '^reasoning=')'"
fi
if [[ "$(printf '%s\n' "$out" | grep '^think_phrase=')" == "think_phrase=" ]]; then
  pass "think_phrase= is empty"
else
  fail "think_phrase not empty: '$(printf '%s\n' "$out" | grep '^think_phrase=')'"
fi

# ---------------------------------------------------------------------------
# Test 2: /agents devise — command set, model/reasoning empty
# ---------------------------------------------------------------------------
run_case "2] /agents devise" \
  "/agents devise" \
  "devise" "" "" ""

# ---------------------------------------------------------------------------
# Test 3: /agents devise opus
# ---------------------------------------------------------------------------
run_case "3] /agents devise opus" \
  "/agents devise opus" \
  "devise" "claude-opus-4-7" "" ""

# ---------------------------------------------------------------------------
# Test 4: /agents devise sonnet
# ---------------------------------------------------------------------------
run_case "4] /agents devise sonnet" \
  "/agents devise sonnet" \
  "devise" "claude-sonnet-4-6" "" ""

# ---------------------------------------------------------------------------
# Test 5: /agents devise haiku
# ---------------------------------------------------------------------------
run_case "5] /agents devise haiku" \
  "/agents devise haiku" \
  "devise" "claude-haiku-4-5-20251001" "" ""

# ---------------------------------------------------------------------------
# Test 6: /agents devise sonnet high
# ---------------------------------------------------------------------------
run_case "6] /agents devise sonnet high" \
  "/agents devise sonnet high" \
  "devise" "claude-sonnet-4-6" "high" "Think very hard before writing."

# ---------------------------------------------------------------------------
# Test 7: /agents devise off
# ---------------------------------------------------------------------------
run_case "7] /agents devise off" \
  "/agents devise off" \
  "devise" "" "off" ""

# ---------------------------------------------------------------------------
# Test 8: /agents devise max
# ---------------------------------------------------------------------------
run_case "8] /agents devise max" \
  "/agents devise max" \
  "devise" "" "max" "Ultrathink — take extensive time to reason before writing."

# ---------------------------------------------------------------------------
# Test 9: /agents execute opus ultrathink
# ---------------------------------------------------------------------------
run_case "9] /agents execute opus ultrathink" \
  "/agents execute opus ultrathink" \
  "execute" "claude-opus-4-7" "max" "Ultrathink — take extensive time to reason before writing."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Unit Test Summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
