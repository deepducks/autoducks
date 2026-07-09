#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/branch-prefix.sh
# Run: bash test/unit-branch-prefix.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Mock the ITS provider — parameterized by MOCK_ISSUE_JSON.
its::get_issue() {
  echo "$MOCK_ISSUE_JSON"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/branch-prefix.sh"

check() { # label expected actual
  if [[ "$3" == "$2" ]]; then pass "$1 → $2"; else fail "$1 — want '$2', got '$3'"; fi
}

echo "── branch_prefix_for_issue (D10) ──"
MOCK_ISSUE_JSON='{"type": "Bug", "labels": []}'
check "native type Bug" "fix" "$(branch_prefix_for_issue 1)"

MOCK_ISSUE_JSON='{"type": "Feature", "labels": ["Bug"]}'
check "label Bug (type Feature)" "fix" "$(branch_prefix_for_issue 1)"

MOCK_ISSUE_JSON='{"type": null, "labels": ["Bug", "Design:done"]}'
check "label Bug among others" "fix" "$(branch_prefix_for_issue 1)"

MOCK_ISSUE_JSON='{"type": "Feature", "labels": ["Feature"]}'
check "Feature issue" "feature" "$(branch_prefix_for_issue 1)"

MOCK_ISSUE_JSON='{"type": null, "labels": ["Bugfix"]}'
check "label Bugfix does NOT match Bug" "feature" "$(branch_prefix_for_issue 1)"

MOCK_ISSUE_JSON='{"type": null, "labels": []}'
check "untyped, unlabeled issue defaults to feature" "feature" "$(branch_prefix_for_issue 1)"

echo "── branch_prefix_of ──"
check "feature branch" "feature" "$(branch_prefix_of 'feature/42-user-auth')"
check "fix branch" "fix" "$(branch_prefix_of 'fix/57-login-crash')"
check "default branch falls back to feature" "feature" "$(branch_prefix_of 'main')"
check "unknown prefix falls back to feature" "feature" "$(branch_prefix_of 'hotfix/1-x')"

echo "── pipeline_branch_number ──"
check "feature branch number" "42" "$(pipeline_branch_number 'feature/42-user-auth')"
check "fix branch number" "57" "$(pipeline_branch_number 'fix/57-login-crash')"
check "task branch under feature" "42" "$(pipeline_branch_number 'feature/42-issue-43-1751941200')"
check "task branch under fix" "57" "$(pipeline_branch_number 'fix/57-issue-58-1751941200')"
check "main yields empty" "" "$(pipeline_branch_number 'main')"
check "non-pipeline branch yields empty" "" "$(pipeline_branch_number 'chore/cleanup')"

echo "── resolve_feature_num_from_pr ──"
check "pipeline feature head ignores PR body" "42" \
  "$(resolve_feature_num_from_pr 'feature/42-foo' "$(printf 'Closes #7\nCloses #8\nCloses #42')")"
check "pipeline fix head, tasks-first body" "13" \
  "$(resolve_feature_num_from_pr 'fix/13-bar' "$(printf 'Closes #7\nCloses #8\nCloses #13')")"
check "non-pipeline head takes last Closes ref" "42" \
  "$(resolve_feature_num_from_pr 'patch-1' "$(printf 'Closes #7\nCloses #42')")"
check "non-pipeline head with no Closes ref yields empty" "" \
  "$(resolve_feature_num_from_pr 'patch-1' 'no refs here')"

# FEATURE_NUM regression (Task #725): resolver/pre.sh used to take the FIRST
# `Closes #N` ref before falling back to the pipeline branch number — backwards
# from resolve_feature_num_from_pr's branch-number-first, last-ref-fallback
# contract. Pin both halves of the fix.
check "non-pipeline head takes the LAST of several Closes refs, not the first" "55" \
  "$(resolve_feature_num_from_pr 'patch-1' "$(printf 'Closes #101\nsome text\nCloses #102\nmore text\nCloses #55')")"
check "pipeline feature head resolves from the branch regardless of body ref order" "42" \
  "$(resolve_feature_num_from_pr 'feature/42-foo' "$(printf 'Closes #55\nCloses #102\nCloses #101')")"

# ---------------------------------------------------------------------------
echo ""
echo "═══ branch-prefix: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
