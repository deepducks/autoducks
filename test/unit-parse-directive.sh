#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/parse-directive.sh
# Run: bash test/unit-parse-directive.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/parse-directive.sh"
CONFIG="$REPO_ROOT/.autoducks/autoducks.json"

PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: run with COMMENT_BODY and assert selected output lines.
#   assert_out LABEL BODY key=value [key=value ...]
# Only the given keys are asserted; AUTODUCKS_CONFIG defaults to repo config.
# ---------------------------------------------------------------------------
assert_out() {
  local label="$1" body="$2"; shift 2
  echo "[$label]"
  local out
  out=$(COMMENT_BODY="$body" AUTODUCKS_CONFIG="${TEST_CONFIG:-$CONFIG}" bash "$SCRIPT" </dev/null)
  local want key got
  for want in "$@"; do
    key="${want%%=*}"
    got=$(printf '%s\n' "$out" | grep "^${key}=" || true)
    if [[ "$got" == "$want" ]]; then
      pass "$want"
    else
      fail "want '$want' — got '$got'"
    fi
  done
}

# ---------------------------------------------------------------------------
echo "── canonical verbs and built-in aliases ──"

assert_out "canonical architect" "/quack architect" \
  "command=architect" "original_command=architect" "model=" "effort=" "auto_chain="

assert_out "alias design → architect" "/quack design" \
  "command=architect" "original_command=design"

assert_out "canonical engineer" "/quack engineer" "command=engineer"
assert_out "alias tactics → engineer" "/quack tactics" \
  "command=engineer" "original_command=tactics"

assert_out "canonical execute" "/quack execute" "command=execute"
assert_out "alias run → execute" "/quack run" "command=execute" "original_command=run"
assert_out "alias work → execute" "/quack work" "command=execute" "original_command=work"

assert_out "fix passthrough" "/quack fix" "command=fix"
assert_out "revert passthrough" "/quack revert" "command=revert"
assert_out "close passthrough" "/quack close" "command=close"

assert_out "uppercase verb is lowercased" "/quack ARCHITECT" "command=architect"

echo "── retired aliases are NOT normalized (D8) ──"
assert_out "devise stays raw" "/quack devise" "command=devise"
assert_out "plan stays raw" "/quack plan" "command=plan"
assert_out "drilldown stays raw" "/quack drilldown" "command=drilldown"
assert_out "specify stays raw" "/quack specify" "command=specify"
assert_out "start stays raw" "/quack start" "command=start"

echo "── prefix handling ──"
assert_out "old /agents prefix is ignored" "/agents execute" "command=" "model="
assert_out "directive mid-comment ignored (must be line start)" \
  "please /quack execute" "command="
assert_out "directive on later line" $'some context\n/quack execute opus' \
  "command=execute" "model=claude-opus-4-8"

echo "── model overrides ──"
assert_out "positional opus" "/quack execute opus" "model=claude-opus-4-8"
assert_out "positional sonnet" "/quack execute sonnet" "model=claude-sonnet-5"
assert_out "positional haiku" "/quack execute haiku" "model=claude-haiku-4-5"
assert_out "named model:opus" "/quack execute model:opus" "model=claude-opus-4-8"
assert_out "named model:claude-sonnet-5" "/quack execute model:claude-sonnet-5" \
  "model=claude-sonnet-5"
assert_out "unknown model ignored" "/quack execute model:gpt-4" "model="

echo "── effort overrides ──"
assert_out "positional high" "/quack execute high" \
  "effort=high" "think_phrase=Think very hard before writing."
assert_out "positional max" "/quack execute max" "effort=max"
assert_out "named effort:low" "/quack execute effort:low" \
  "effort=low" "think_phrase=Think before writing."
assert_out "named effort:medium" "/quack execute effort:med" "effort=medium"
assert_out "effort off yields empty think phrase" "/quack execute effort:off" \
  "effort=off" "think_phrase="
assert_out "no effort yields empty (defaults win downstream)" "/quack execute" \
  "effort=" "think_phrase="
assert_out "combined model+effort" "/quack architect opus max" \
  "model=claude-opus-4-8" "effort=max"

echo "── max_turns overrides ──"
assert_out "turns:5" "/quack execute turns:5" "max_turns=5"
assert_out "turns=12" "/quack execute turns=12" "max_turns=12"
assert_out "max-turns=7" "/quack execute max-turns=7" "max_turns=7"
assert_out "max_turns=9" "/quack execute max_turns=9" "max_turns=9"
assert_out "turns:0 rejected" "/quack execute turns:0" "max_turns="
assert_out "turns:1001 rejected" "/quack execute turns:1001" "max_turns="
assert_out "turns garbage rejected" "/quack execute turns=abc" "max_turns="

echo "── #auto: chaining ──"
assert_out "single chain" "/quack architect #auto:engineer" "auto_chain=engineer"
assert_out "multi chain" "/quack architect #auto:engineer+execute" \
  "auto_chain=engineer+execute"
assert_out "chain aliases normalized" "/quack architect #auto:tactics+run" \
  "auto_chain=engineer+execute"
assert_out "chain dedupes verbs" "/quack architect #auto:engineer+engineer+execute" \
  "auto_chain=engineer+execute"
assert_out "invalid chain verbs filtered" "/quack architect #auto:engineer+banana" \
  "auto_chain=engineer"
assert_out "wholly invalid chain empty" "/quack architect #auto:banana" "auto_chain="
assert_out "chain with other tokens" "/quack architect opus #auto:engineer turns:3" \
  "auto_chain=engineer" "model=claude-opus-4-8" "max_turns=3"

echo "── no directive ──"
assert_out "empty body" "" "command=" "model=" "effort=" "max_turns=" "auto_chain="
assert_out "unrelated comment" "great work!" "command="

# ---------------------------------------------------------------------------
echo "── configurable prefix + custom aliases ──"
TMP_CFG=$(mktemp)
cat > "$TMP_CFG" <<'JSON'
{
  "command": "/duck",
  "triggers": {
    "architect": [],
    "engineer": ["plan-it"],
    "execute": ["ship"],
    "fix": [],
    "revert": [],
    "close": []
  }
}
JSON

TEST_CONFIG="$TMP_CFG" assert_out "custom prefix honored" "/duck execute" "command=execute"
TEST_CONFIG="$TMP_CFG" assert_out "default prefix rejected under custom prefix" \
  "/quack execute" "command="
TEST_CONFIG="$TMP_CFG" assert_out "custom alias → canonical verb" "/duck plan-it" \
  "command=engineer" "original_command=plan-it"
TEST_CONFIG="$TMP_CFG" assert_out "custom execute alias" "/duck ship" "command=execute"
TEST_CONFIG="$TMP_CFG" assert_out "custom alias in chain" "/duck architect #auto:ship" \
  "auto_chain=execute"

# Malformed prefix in config falls back to /quack
TMP_CFG2=$(mktemp)
echo '{"command": "quack no-slash", "triggers": {}}' > "$TMP_CFG2"
TEST_CONFIG="$TMP_CFG2" assert_out "garbage prefix falls back to /quack" \
  "/quack execute" "command=execute"

rm -f "$TMP_CFG" "$TMP_CFG2"

# ---------------------------------------------------------------------------
echo ""
echo "═══ parse-directive: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
