#!/usr/bin/env bash
# Offline unit tests for the `/agent` verb in
# .autoducks/core/config/parse-directive.sh: positional agent-name capture,
# charset validation, and interaction with namespaces / custom triggers.
#
# Run via scripts/tests/run.sh, or directly:
# bash scripts/tests/parse-directive-agent.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/parse-directive.sh"
CONFIG="$REPO_ROOT/.autoducks/autoducks.json"

PASS=0
FAIL=0
pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

# assert_out LABEL [CONFIG_FILE] BODY key=value [key=value ...]
# If the 2nd positional arg looks like a file path that exists, it's used as
# AUTODUCKS_CONFIG; otherwise the repo default config is used and that arg is
# the BODY.
assert_out() {
  local label="$1"; shift
  local cfg="$CONFIG"
  if [[ -f "${1:-}" ]]; then
    cfg="$1"; shift
  fi
  local body="$1"; shift
  echo "[$label]"
  local out
  out=$(COMMENT_BODY="$body" AUTODUCKS_CONFIG="$cfg" bash "$SCRIPT" </dev/null)
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

# ---------------------------------------------------------------------------
echo "── /agent: positional agent-name capture ──"

assert_out "/agent foo -> agent_name=foo, empty steering" "/agent foo" \
  "command=agent" "agent_name=foo" "agent_name_error="
assert_steering "/agent foo -> empty steering_prompt" "/agent foo" ""

assert_out "/agent foo model:opus rest of prose" \
  "/agent foo model:opus rest of prose" \
  "command=agent" "agent_name=foo" "model=claude-opus-5" "agent_name_error="
assert_steering "/agent foo model:opus rest of prose -> steering is the prose" \
  "/agent foo model:opus rest of prose" "rest of prose"

assert_out "/agent alone -> empty agent_name, no error, catalog mode" "/agent" \
  "command=agent" "agent_name=" "agent_name_error="

assert_out "/agent BAD_NAME -> invalid-name, agent_name stays empty" "/agent BAD_NAME" \
  "command=agent" "agent_name=" "agent_name_error=invalid-name"

assert_out "/agent sonnet -> name captured, NOT parsed as a model alias" "/agent sonnet" \
  "command=agent" "agent_name=sonnet" "model="

# ---------------------------------------------------------------------------
echo "── /agent: namespace and custom-trigger interaction ──"

TMP_QUACK=$(mktemp)
echo '{"command": "quack", "triggers": {}}' > "$TMP_QUACK"
assert_out "/quack agent foo under command:\"quack\"" "$TMP_QUACK" "/quack agent foo" \
  "command=agent" "agent_name=foo"
rm -f "$TMP_QUACK"

TMP_ALIAS=$(mktemp)
echo '{"triggers": {"agent": ["ask"]}}' > "$TMP_ALIAS"
assert_out "triggers.agent:[ask] makes /ask foo resolve to agent" "$TMP_ALIAS" "/ask foo" \
  "command=agent" "agent_name=foo"
rm -f "$TMP_ALIAS"

# ---------------------------------------------------------------------------
echo "── generate-trigger-conditions.sh: 'agent' is a reserved built-in ──"

GEN_SCRIPT="$REPO_ROOT/.autoducks/core/config/generate-trigger-conditions.sh"
TMP_COLLIDE=$(mktemp)
echo '{"triggers": {"engineer": ["agent"]}}' > "$TMP_COLLIDE"
if AUTODUCKS_CONFIG="$TMP_COLLIDE" bash "$GEN_SCRIPT" >/tmp/gen-out 2>&1; then
  fail "expected generate-trigger-conditions.sh to reject 'agent' alias, but it succeeded"
else
  if grep -q "collides with built-in" /tmp/gen-out; then
    pass "aliasing 'agent' onto another agent is rejected as a built-in collision"
  else
    fail "rejected for the wrong reason: $(cat /tmp/gen-out)"
  fi
fi
rm -f "$TMP_COLLIDE" /tmp/gen-out

# ---------------------------------------------------------------------------
echo ""
echo "=== parse-directive /agent (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
