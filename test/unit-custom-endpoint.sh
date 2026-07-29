#!/usr/bin/env bash
# Unit tests for the custom Anthropic endpoint support in the Claude LLM
# provider: .autoducks/providers/llm/claude/resolve-endpoint.sh plus its wiring
# through action.yml and the nine LLM-backed workflows (+ their mirrors).
#
# Behaviour covered:
#   1. no ANTHROPIC_BASE_URL      → credentials pass through untouched, no env writes
#   2. base URL + auth token      → ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN exported
#   3. base URL + auth token only → auth token doubles as api_key (base-action needs one)
#   4. base URL + api key         → api key kept, no ANTHROPIC_AUTH_TOKEN exported
#   5. base URL + oauth token     → oauth suppressed (only valid on api.anthropic.com)
#   6. secrets are masked in the log
#   7. action.yml + workflows wire the inputs end to end
#
# Run: bash test/unit-custom-endpoint.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$REPO_ROOT/.autoducks/providers/llm/claude/resolve-endpoint.sh"
ACTION_FILE="$REPO_ROOT/.autoducks/providers/llm/claude/action.yml"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# run_resolve BASE_URL AUTH_TOKEN API_KEY OAUTH_TOKEN
# Executes the real step script against fresh $GITHUB_OUTPUT/$GITHUB_ENV files
# and exposes the results as OUT / ENV_OUT / LOG.
run_resolve() {
  local out="$SCRATCH/output" env_file="$SCRATCH/env" log="$SCRATCH/log"
  : > "$out"
  : > "$env_file"
  BASE_URL="$1" AUTH_TOKEN="$2" API_KEY="$3" OAUTH_TOKEN="$4" \
    GITHUB_OUTPUT="$out" GITHUB_ENV="$env_file" \
    bash "$RESOLVE" > "$log" 2>&1
  OUT="$(cat "$out")"
  ENV_OUT="$(cat "$env_file")"
  LOG="$(cat "$log")"
}

echo "── 1. default endpoint: credentials pass through ──"
run_resolve "" "" "sk-ant-key" "oauth-tok"
if grep -qx "api_key=sk-ant-key" <<< "$OUT"; then
  pass "api_key forwarded unchanged"
else
  fail "api_key not forwarded: $OUT"
fi
if grep -qx "oauth_token=oauth-tok" <<< "$OUT"; then
  pass "oauth_token forwarded unchanged"
else
  fail "oauth_token not forwarded: $OUT"
fi
if [[ -z "$ENV_OUT" ]]; then
  pass "nothing written to \$GITHUB_ENV"
else
  fail "unexpected \$GITHUB_ENV writes: $ENV_OUT"
fi

echo "── 2. custom endpoint: base URL and bearer token exported ──"
run_resolve "https://gw.example.com/anthropic" "gw-token" "" ""
if grep -qx "ANTHROPIC_BASE_URL=https://gw.example.com/anthropic" <<< "$ENV_OUT"; then
  pass "ANTHROPIC_BASE_URL exported to the job env"
else
  fail "ANTHROPIC_BASE_URL missing: $ENV_OUT"
fi
if grep -qx "ANTHROPIC_AUTH_TOKEN=gw-token" <<< "$ENV_OUT"; then
  pass "ANTHROPIC_AUTH_TOKEN exported to the job env"
else
  fail "ANTHROPIC_AUTH_TOKEN missing: $ENV_OUT"
fi

echo "── 3. custom endpoint with no separate api key ──"
if grep -qx "api_key=gw-token" <<< "$OUT"; then
  pass "auth token doubles as api_key so base-action's validation passes"
else
  fail "api_key not derived from the auth token: $OUT"
fi
if grep -qx "oauth_token=" <<< "$OUT"; then
  pass "oauth_token emitted empty"
else
  fail "oauth_token not empty: $OUT"
fi
if grep -qF "::add-mask::gw-token" <<< "$LOG"; then
  pass "auth token masked in the log"
else
  fail "auth token not masked: $LOG"
fi

echo "── 4. custom endpoint authenticated with x-api-key only ──"
run_resolve "https://gw.example.com/anthropic" "" "gw-key" ""
if grep -qx "api_key=gw-key" <<< "$OUT"; then
  pass "explicit api key kept"
else
  fail "api key not kept: $OUT"
fi
if grep -q "ANTHROPIC_AUTH_TOKEN" <<< "$ENV_OUT"; then
  fail "ANTHROPIC_AUTH_TOKEN exported without a bearer token: $ENV_OUT"
else
  pass "no ANTHROPIC_AUTH_TOKEN when none was configured"
fi
if grep -qF "::add-mask::gw-key" <<< "$LOG"; then
  pass "api key masked in the log"
else
  fail "api key not masked: $LOG"
fi

echo "── 5. custom endpoint wins over the subscription OAuth token ──"
run_resolve "https://gw.example.com/anthropic" "gw-token" "" "oauth-tok"
if grep -qx "oauth_token=" <<< "$OUT"; then
  pass "oauth_token suppressed when a custom endpoint is configured"
else
  fail "oauth_token leaked to a custom endpoint: $OUT"
fi
if grep -qx "api_key=gw-token" <<< "$OUT"; then
  pass "custom credential used instead"
else
  fail "custom credential not used: $OUT"
fi

echo "── 6. action.yml wiring ──"
for input in anthropic_base_url anthropic_auth_token; do
  if grep -qE "^  $input:" "$ACTION_FILE"; then
    pass "action.yml declares the $input input"
  else
    fail "action.yml is missing the $input input"
  fi
done
if grep -qF 'anthropic_api_key: ${{ steps.endpoint.outputs.api_key }}' "$ACTION_FILE"; then
  pass "claude-code-action receives the resolved api_key"
else
  fail "claude-code-action does not consume steps.endpoint.outputs.api_key"
fi
if grep -qF 'claude_code_oauth_token: ${{ steps.endpoint.outputs.oauth_token }}' "$ACTION_FILE"; then
  pass "claude-code-action receives the resolved oauth_token"
else
  fail "claude-code-action does not consume steps.endpoint.outputs.oauth_token"
fi

echo "── 7. workflow wiring (templates and mirrors) ──"
LLM_AGENTS=(architect engineer developer reviewer fix resolver rework defer product)
for dir in ".autoducks/runtimes/github-actions" ".github/workflows"; do
  for a in "${LLM_AGENTS[@]}"; do
    f="$REPO_ROOT/$dir/autoducks-$a.yml"
    label="$dir/autoducks-$a.yml"
    if grep -qF 'anthropic_base_url: ${{ secrets.ANTHROPIC_BASE_URL || vars.ANTHROPIC_BASE_URL }}' "$f"; then
      pass "$label: passes ANTHROPIC_BASE_URL"
    else
      fail "$label: does not pass ANTHROPIC_BASE_URL"
    fi
    if grep -qF 'anthropic_auth_token: ${{ secrets.ANTHROPIC_AUTH_TOKEN }}' "$f"; then
      pass "$label: passes ANTHROPIC_AUTH_TOKEN"
    else
      fail "$label: does not pass ANTHROPIC_AUTH_TOKEN"
    fi
  done
done

echo ""
echo "═══ custom-endpoint: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
