#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/commit-lint.sh
# Run: bash test/unit-commit-lint.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Mock the git provider — parameterized by MOCK_PRS_JSON.
git::list_open_prs() {
  echo "$MOCK_PRS_JSON"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/robustness/commit-lint.sh"

export AUTODUCKS_INTEGRATION_BRANCH="main"

# check_warns LABEL COMMIT_MESSAGE EXPECT_WARN(0/1)
check_warns() {
  local label="$1" message="$2" expect="$3" out rc
  if out="$(commit_lint::scan "$message")"; then rc=0; else rc=$?; fi

  if [[ "$rc" -ne 0 ]]; then
    fail "$label — commit_lint::scan must exit 0 (warn-only), got $rc"
    return
  fi

  if [[ "$expect" == "1" ]]; then
    if [[ "$out" == *"::warning::"* ]]; then pass "$label"; else fail "$label — expected a warning, got: $out"; fi
  else
    if [[ "$out" != *"::warning::"* ]]; then pass "$label"; else fail "$label — expected no warning, got: $out"; fi
  fi
}

echo "── commit_lint::scan ──"

MOCK_PRS_JSON='[{"headRefName": "feature/42-foo", "body": "", "number": 7}]'
check_warns "closing keyword vs an issue with an open delivery PR warns" "Fixes #42" "1"

MOCK_PRS_JSON='[{"headRefName": "feature/42-foo", "body": "", "number": 7}]'
check_warns "non-closing 'refs #N' never warns" "See also, refs #42" "0"

MOCK_PRS_JSON='[{"headRefName": "feature/42-foo", "body": "", "number": 7}]'
check_warns "non-closing 're #N' never warns" "Follow-up, re #42" "0"

MOCK_PRS_JSON='[]'
check_warns "closing keyword vs an issue with no open delivery PR never warns" "Closes #99" "0"

# ---------------------------------------------------------------------------
echo ""
echo "═══ commit-lint: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
