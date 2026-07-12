#!/usr/bin/env bash
# Unit tests for the review-loop config knobs read by
# .autoducks/core/config/load-config.sh:
#   AUTODUCKS_REVIEW_MAX_ITERATIONS — clamped to [1,10], default 3, non-numeric
#     input also falls back to 3.
#   AUTODUCKS_REVIEW_AUTO_REWORK    — defaults to "true" when `review.auto_rework`
#     is unset in autoducks.json, and otherwise mirrors the configured value.
#
# Drives the real load-config.sh against a scratch AUTODUCKS_ROOT that
# symlinks the repo's real core/providers/agents (so every other export it
# performs — provider interfaces, command-string helper, agent defaults —
# resolves normally) but supplies its own autoducks.json per case, run in a
# subshell so load-config's `set -euo pipefail` and repeated top-level
# exports never leak between cases. Same scratch-root technique as
# test/unit-reviewer-max-turns.sh's gh-shim subprocess isolation.
# Run: bash test/unit-review-config-clamp.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_CONFIG="$REPO_ROOT/.autoducks/core/config/load-config.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT
ln -s "$REPO_ROOT/.autoducks/agents" "$SCRATCH_ROOT/agents"
ln -s "$REPO_ROOT/.autoducks/core" "$SCRATCH_ROOT/core"
ln -s "$REPO_ROOT/.autoducks/providers" "$SCRATCH_ROOT/providers"
ln -s "$REPO_ROOT/.autoducks/security-guidelines.md" "$SCRATCH_ROOT/security-guidelines.md"

# write_config REVIEW_JSON — (re)writes the scratch autoducks.json with the
# fixed provider/defaults scaffolding load-config.sh requires, varying only
# the `.review` block under test.
write_config() {
  local review_json="$1"
  cat > "$SCRATCH_ROOT/autoducks.json" <<EOF
{
  "providers": {"its": "github", "git": "github", "llm": "claude"},
  "defaults": {"model": "m", "effort": "high", "base_branch": "main", "merge_method": "auto"},
  "review": $review_json
}
EOF
}

# resolved REVIEW_JSON → echoes "max=<N> auto=<bool>" from a fresh load-config.sh run.
resolved() {
  write_config "$1"
  (
    export AUTODUCKS_ROOT="$SCRATCH_ROOT" AUTODUCKS_AGENT="reviewer" GITHUB_ACTIONS=true
    # shellcheck source=/dev/null
    source "$LOAD_CONFIG"
    echo "max=$AUTODUCKS_REVIEW_MAX_ITERATIONS auto=$AUTODUCKS_REVIEW_AUTO_REWORK"
  )
}

check() { # label review_json expected
  local got
  got="$(resolved "$2")"
  if [[ "$got" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 — expected '$3', got '$got'"
  fi
}

echo "── AUTODUCKS_REVIEW_MAX_ITERATIONS clamp ──"
check "no review.max_iterations → default 3"       '{}'                        "max=3 auto=true"
check "non-numeric max_iterations → default 3"     '{"max_iterations":"abc"}'  "max=3 auto=true"
check "max_iterations=0 (below range) → clamps to 1"  '{"max_iterations":0}'   "max=1 auto=true"
check "max_iterations=1 (in range) → unchanged"     '{"max_iterations":1}'     "max=1 auto=true"
check "max_iterations=10 (in range) → unchanged"    '{"max_iterations":10}'    "max=10 auto=true"
check "max_iterations=15 (above range) → clamps to 10" '{"max_iterations":15}' "max=10 auto=true"
check "max_iterations=5 (in range) → stays 5"       '{"max_iterations":5}'     "max=5 auto=true"

echo ""
echo "── AUTODUCKS_REVIEW_AUTO_REWORK default ──"
check "no review.auto_rework → defaults true"       '{}'                       "max=3 auto=true"
check "auto_rework:false → false"                   '{"auto_rework":false}'    "max=3 auto=false"
check "auto_rework:true (explicit) → true"           '{"auto_rework":true}'    "max=3 auto=true"
check "auto_rework:false alongside a valid max_iterations" \
  '{"auto_rework":false,"max_iterations":5}' "max=5 auto=false"

echo ""
echo "═══ review-config-clamp: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
