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
echo "── canonical verbs and built-in aliases (bare form, default namespace) ──"

assert_out "canonical architect" "/architect" \
  "command=architect" "original_command=architect" "model=" "effort=" "auto_chain="

assert_out "alias design → architect" "/design" \
  "command=architect" "original_command=design"

assert_out "canonical engineer" "/engineer" "command=engineer"
assert_out "alias tactics → engineer" "/tactics" \
  "command=engineer" "original_command=tactics"

assert_out "canonical execute" "/execute" "command=execute"
assert_out "alias run → execute" "/run" "command=execute" "original_command=run"
assert_out "alias work → execute" "/work" "command=execute" "original_command=work"

assert_out "fix passthrough" "/fix" "command=fix"
assert_out "revert passthrough" "/revert" "command=revert"
assert_out "close passthrough" "/close" "command=close"
assert_out "rework passthrough" "/rework" "command=rework" "original_command=rework"
assert_out "defer passthrough" "/defer" "command=defer" "original_command=defer"

assert_out "uppercase verb is lowercased" "/ARCHITECT" "command=architect"

echo "── retired aliases are NOT normalized (D8) ──"
assert_out "devise stays raw" "/devise" "command=devise"
assert_out "plan stays raw" "/plan" "command=plan"
assert_out "drilldown stays raw" "/drilldown" "command=drilldown"
assert_out "specify stays raw" "/specify" "command=specify"
assert_out "start stays raw" "/start" "command=start"

echo "── directive position handling ──"
assert_out "directive mid-comment ignored (must be line start)" \
  "please /run" "command="
assert_out "prose containing /fixed does not fire or normalize to fix" \
  "I just /fixed a typo" "command="
assert_out "directive on later line" $'some context\n/execute opus' \
  "command=execute" "model=claude-opus-4-8"

echo "── model overrides ──"
assert_out "positional opus" "/execute opus" "model=claude-opus-4-8"
assert_out "positional sonnet" "/execute sonnet" "model=claude-sonnet-5"
assert_out "positional haiku" "/execute haiku" "model=claude-haiku-4-5"
assert_out "named model:opus" "/execute model:opus" "model=claude-opus-4-8"
assert_out "named model:claude-sonnet-5" "/execute model:claude-sonnet-5" \
  "model=claude-sonnet-5"
assert_out "unknown model ignored" "/execute model:gpt-4" "model="

echo "── effort overrides ──"
assert_out "positional high" "/execute high" \
  "effort=high" "think_phrase=Think very hard before writing."
assert_out "positional max" "/execute max" "effort=max"
assert_out "named effort:low" "/execute effort:low" \
  "effort=low" "think_phrase=Think before writing."
assert_out "named effort:medium" "/execute effort:med" "effort=medium"
assert_out "effort off yields empty think phrase" "/execute effort:off" \
  "effort=off" "think_phrase="
assert_out "no effort yields empty (defaults win downstream)" "/execute" \
  "effort=" "think_phrase="
assert_out "combined model+effort" "/architect opus max" \
  "model=claude-opus-4-8" "effort=max"
assert_out "model:opus effort:max" "/execute model:opus effort:max" \
  "model=claude-opus-4-8" "effort=max"

echo "── max_turns overrides ──"
assert_out "turns:5" "/execute turns:5" "max_turns=5"
assert_out "turns=12" "/execute turns=12" "max_turns=12"
assert_out "max-turns=7" "/execute max-turns=7" "max_turns=7"
assert_out "max_turns=9" "/execute max_turns=9" "max_turns=9"
assert_out "turns:0 rejected" "/execute turns:0" "max_turns="
assert_out "turns:1001 rejected" "/execute turns:1001" "max_turns="
assert_out "turns garbage rejected" "/execute turns=abc" "max_turns="

echo "── #auto: chaining ──"
assert_out "single chain" "/architect #auto:engineer" "auto_chain=engineer"
assert_out "multi chain" "/architect #auto:engineer+execute" \
  "auto_chain=engineer+execute"
assert_out "chain aliases normalized" "/architect #auto:tactics+run" \
  "auto_chain=engineer+execute"
assert_out "chain dedupes verbs" "/architect #auto:engineer+engineer+execute" \
  "auto_chain=engineer+execute"
assert_out "invalid chain verbs filtered" "/architect #auto:engineer+banana" \
  "auto_chain=engineer"
assert_out "wholly invalid chain empty" "/architect #auto:banana" "auto_chain="
assert_out "chain with other tokens" "/architect opus #auto:engineer turns:3" \
  "auto_chain=engineer" "model=claude-opus-4-8" "max_turns=3"
assert_out "architect #auto:engineer+execute matches prior /quack equivalent" \
  "/architect #auto:engineer+execute" "command=architect" "auto_chain=engineer+execute"

echo "── #auto: chain excludes non-dispatchable verbs (fix/revert/close) ──"
assert_out "chainable review survives (self-loop avoided via execute)" \
  "/execute #auto:review" "auto_chain=review"
assert_out "#auto:close dropped" "/architect #auto:close" "auto_chain="
assert_out "#auto:fix dropped" "/architect #auto:fix" "auto_chain="
assert_out "#auto:revert dropped" "/architect #auto:revert" "auto_chain="
assert_out "#auto:rework dropped" "/architect #auto:rework" "auto_chain="
assert_out "#auto:defer dropped" "/architect #auto:defer" "auto_chain="
assert_out "mixed chain filters non-chainable, keeps chainable" \
  "/architect #auto:engineer+close" "auto_chain=engineer"
assert_out "direct /review still routes (canonical, non-chain)" \
  "/review" "command=review"

echo "── no directive ──"
assert_out "empty body" "" "command=" "model=" "effort=" "max_turns=" "auto_chain="
assert_out "unrelated comment" "great work!" "command="

# ---------------------------------------------------------------------------
echo "── configurable namespace + custom aliases ──"
TMP_CFG=$(mktemp)
cat > "$TMP_CFG" <<'JSON'
{
  "command": "duck",
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

TEST_CONFIG="$TMP_CFG" assert_out "custom namespace honored" "/duck execute" "command=execute"
TEST_CONFIG="$TMP_CFG" assert_out "bare form rejected under custom namespace" \
  "/execute" "command="
TEST_CONFIG="$TMP_CFG" assert_out "custom alias → canonical verb" "/duck plan-it" \
  "command=engineer" "original_command=plan-it"
TEST_CONFIG="$TMP_CFG" assert_out "custom execute alias" "/duck ship" "command=execute"
TEST_CONFIG="$TMP_CFG" assert_out "custom alias in chain" "/duck architect #auto:ship" \
  "auto_chain=execute"

# Namespace set to "quack": two-token parsing still works, bare form doesn't fire.
TMP_CFG_QUACK=$(mktemp)
echo '{"command": "quack", "triggers": {}}' > "$TMP_CFG_QUACK"
TEST_CONFIG="$TMP_CFG_QUACK" assert_out "command:\"quack\" — /quack execute parses" \
  "/quack execute" "command=execute"
TEST_CONFIG="$TMP_CFG_QUACK" assert_out "command:\"quack\" — bare /execute does not fire" \
  "/execute" "command="

# Malformed namespace in config falls back to empty (bare short forms)
TMP_CFG2=$(mktemp)
echo '{"command": "quack no-slash", "triggers": {}}' > "$TMP_CFG2"
TEST_CONFIG="$TMP_CFG2" assert_out "garbage namespace falls back to bare form" \
  "/execute" "command=execute"
TEST_CONFIG="$TMP_CFG2" assert_out "garbage namespace: malformed args still ignored" \
  "/execute turns:0" "max_turns="

rm -f "$TMP_CFG" "$TMP_CFG_QUACK" "$TMP_CFG2"

# ---------------------------------------------------------------------------
# Helper: run with COMMENT_BODY and assert the decoded steering_prompt value.
#   assert_steering LABEL BODY EXPECTED_DECODED_PROSE
# ---------------------------------------------------------------------------
assert_steering() {
  local label="$1" body="$2" expected="$3"
  echo "[$label]"
  local out b64 decoded
  out=$(COMMENT_BODY="$body" AUTODUCKS_CONFIG="$CONFIG" bash "$SCRIPT" </dev/null)
  b64=$(printf '%s\n' "$out" | grep '^steering_prompt=' | cut -d= -f2-)
  if [[ -z "$b64" ]]; then
    decoded=""
  else
    decoded=$(printf '%s' "$b64" | base64 -d)
  fi
  if [[ "$decoded" == "$expected" ]]; then
    pass "steering_prompt decodes to '$expected'"
  else
    fail "want steering_prompt '$expected' — got '$decoded'"
  fi
}

echo "── steering_prompt: free-text remainder ──"

assert_steering "directive-only is empty" "/architect" ""

assert_steering "directive + prose" \
  "/architect please add a caching layer" \
  "please add a caching layer"

assert_steering "directive + tokens + prose" \
  "/execute opus turns:5 please add a caching layer" \
  "please add a caching layer"

assert_steering "multi-line prose" \
  $'/architect please review\nand consider caching layer\nfor performance' \
  $'please review\nand consider caching layer\nfor performance'

assert_steering "model:-like word mid-prose is not stripped" \
  "/architect lets discuss the model:xyz option further" \
  "lets discuss the model:xyz option further"

# ---------------------------------------------------------------------------
echo ""
echo "═══ parse-directive: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
