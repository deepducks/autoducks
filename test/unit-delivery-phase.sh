#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/delivery-phase.sh
# Run: bash test/unit-delivery-phase.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Stub the git provider's only dependency used by delivery_phase::started.
# MOCK_BRANCH (if set) is returned whenever the requested pattern is a
# prefix of it; otherwise nothing is returned — no network/gh access needed.
MOCK_BRANCH=""
git::find_branches_matching() {
  local pattern="$1"
  if [[ -n "$MOCK_BRANCH" && "$MOCK_BRANCH" == ${pattern}* ]]; then
    echo "$MOCK_BRANCH"
  fi
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/delivery-phase.sh"

check_true() { # label issue labels
  if delivery_phase::started "$2" "$3"; then
    pass "$1"
  else
    fail "$1 — expected true (rc 0), got rc 1"
  fi
}

check_false() { # label issue labels
  if delivery_phase::started "$2" "$3"; then
    fail "$1 — expected false (rc 1), got rc 0"
  else
    pass "$1"
  fi
}

echo "── Work:* labels ──"
MOCK_BRANCH=""
check_true "Work:orchestrating label" 42 $'Design:done\nWork:orchestrating'
check_true "Work:coding label" 42 $'Design:done\nWork:coding'
check_true "Work:done label" 42 $'Design:done\nWork:done'

echo "── pipeline branch, no Work:* label ──"
MOCK_BRANCH="feature/42-user-auth"
check_true "feature branch exists, no Work label" 42 $'Design:done\nTactics:approved'

MOCK_BRANCH="fix/42-login-crash"
check_true "fix branch exists, no Work label" 42 $'Design:done\nTactics:approved'

echo "── discovery: no pipeline branch, no Work:* label ──"
MOCK_BRANCH=""
check_false "discovery phase (Design:*/Tactics:* only)" 42 $'Design:done\nTactics:approved'

echo "── title-independence ──"
# The branch's slug tail need not match the issue's current title — only the
# feature/<N>- or fix/<N>- prefix and issue number are ever inspected.
MOCK_BRANCH="feature/42-a-completely-different-slug-9999999999"
check_true "branch slug differs from current title, still detected" 42 ""

# ---------------------------------------------------------------------------
echo ""
echo "═══ delivery-phase: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
