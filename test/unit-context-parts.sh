#!/usr/bin/env bash
# Unit tests for .autoducks/core/context/context-parts.sh
# Run: bash test/unit-context-parts.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# context-parts.sh sources parse-waves.sh / tactical-zone.sh / verify-loop.sh
# via $AUTODUCKS_ROOT, same as every other core module.
export AUTODUCKS_ROOT="$REPO_ROOT/.autoducks"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# its::* / git::* stubs — table-driven so each test can point an issue/PR
# number at canned JSON without a real ITS/git provider.
# ---------------------------------------------------------------------------
declare -A ISSUE_JSON=()
declare -A COMMENTS_JSON=()
declare -A PR_JSON=()
declare -A PR_DIFF=()
GH_CALLED=0

its::get_issue() {
  local n="$1"
  if [[ -z "${ISSUE_JSON[$n]:-}" ]]; then
    return 1
  fi
  echo "${ISSUE_JSON[$n]}"
}

its::list_comments() {
  local n="$1"
  echo "${COMMENTS_JSON[$n]:-[]}"
}

git::get_pr() {
  local n="$1"
  if [[ -z "${PR_JSON[$n]:-}" ]]; then
    return 1
  fi
  echo "${PR_JSON[$n]}"
}

git::get_pr_diff() {
  local n="$1"
  printf '%s' "${PR_DIFF[$n]:-}"
}

# Any accidental direct `gh` call inside a materializer must be caught.
gh() {
  GH_CALLED=1
  echo "unexpected gh call: $*" >&2
  return 1
}

# shellcheck source=/dev/null
source "$AUTODUCKS_ROOT/core/context/context-parts.sh"

OUT="$SCRATCH/out.md"

# ---------------------------------------------------------------------------
# Test: issue_metadata — exact output of the inlined reference snippet
# ---------------------------------------------------------------------------
echo "[1] context_part::issue_metadata"
ISSUE_JSON[100]='{"title":"T","body":"B","labels":["bug","priority-high"],"type":"Bug","author":"alice"}'
context_part::issue_metadata 100 "$OUT"
EXPECTED=$'## Issue metadata\n\n- Labels: bug, priority-high\n- Type: Bug\n- Author: alice'
if [[ "$(cat "$OUT")" == "$EXPECTED" ]]; then
  pass "matches the reference snippet's exact output"
else
  fail "mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: issue_metadata — missing fields degrade to n/a, empty labels
# ---------------------------------------------------------------------------
echo "[2] context_part::issue_metadata — missing fields"
ISSUE_JSON[101]='{"title":"T","body":"B"}'
context_part::issue_metadata 101 "$OUT"
EXPECTED=$'## Issue metadata\n\n- Labels: \n- Type: n/a\n- Author: n/a'
if [[ "$(cat "$OUT")" == "$EXPECTED" ]]; then
  pass "n/a defaults and empty label join"
else
  fail "mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: issue_comments — exact output of the inlined reference snippet
# ---------------------------------------------------------------------------
echo "[3] context_part::issue_comments"
COMMENTS_JSON[100]='[{"author":"alice","body":"first comment"},{"author":"bob","body":"second"}]'
context_part::issue_comments 100 "$OUT"
EXPECTED=$(printf '### alice\n\nfirst comment\n\n---\n\n### bob\n\nsecond\n\n---\n')
if [[ "$(cat "$OUT")" == "$EXPECTED" ]]; then
  pass "matches the reference snippet's exact output"
else
  fail "mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: issue_comments — no comments → empty file, not an error
# ---------------------------------------------------------------------------
echo "[4] context_part::issue_comments — empty source"
COMMENTS_JSON[102]='[]'
context_part::issue_comments 102 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "empty comment list → empty output file"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: issue_title / issue_description
# ---------------------------------------------------------------------------
echo "[5] context_part::issue_title / issue_description"
ISSUE_JSON[103]='{"title":"My Issue Title","body":"My issue body.\nSecond line."}'
context_part::issue_title 103 "$OUT"
[[ "$(cat "$OUT")" == "My Issue Title" ]] && pass "issue_title" || fail "issue_title mismatch: $(cat "$OUT")"
context_part::issue_description 103 "$OUT"
[[ "$(cat "$OUT")" == $'My issue body.\nSecond line.' ]] && pass "issue_description" || fail "issue_description mismatch: $(cat "$OUT")"

# ---------------------------------------------------------------------------
# Test: issue_title / issue_description — absent issue → empty, no error
# ---------------------------------------------------------------------------
echo "[6] context_part::issue_title — absent issue"
context_part::issue_title 999999 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "absent issue → empty output file, no non-zero exit"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: task_title / task_description — same contract as issue_* (a distinct
# catalog id for when the resolver targets a task issue).
# ---------------------------------------------------------------------------
echo "[7] context_part::task_title / task_description"
ISSUE_JSON[104]='{"title":"Task Title","body":"Task body."}'
context_part::task_title 104 "$OUT"
[[ "$(cat "$OUT")" == "Task Title" ]] && pass "task_title" || fail "task_title mismatch: $(cat "$OUT")"
context_part::task_description 104 "$OUT"
[[ "$(cat "$OUT")" == "Task body." ]] && pass "task_description" || fail "task_description mismatch: $(cat "$OUT")"

# ---------------------------------------------------------------------------
# Test: task_criteria — enumerates tasks via parse_waves (reviewer/pre.sh L130)
# ---------------------------------------------------------------------------
echo "[8] context_part::task_criteria"
ISSUE_JSON[200]=$(jq -n '{title: "Feature", body: "## Plan\n\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [201, 202]\n```\n"}')
ISSUE_JSON[201]='{"title":"Task A","body":"Criteria A."}'
ISSUE_JSON[202]='{"title":"Task B","body":"Criteria B."}'
context_part::task_criteria 200 "$OUT"
if grep -q '## Task #201 — Task A' "$OUT" && grep -q '## Task #202 — Task B' "$OUT" \
   && grep -q 'Criteria A.' "$OUT" && grep -q 'Criteria B.' "$OUT"; then
  pass "enumerates every task's title + body"
else
  fail "missing expected task content: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: task_criteria — no waves block → empty file (best-effort, no error)
# ---------------------------------------------------------------------------
echo "[9] context_part::task_criteria — no waves block"
ISSUE_JSON[203]='{"title":"Standalone","body":"Just prose, no plan."}'
context_part::task_criteria 203 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "no waves block → empty output file"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: prior_feedback — ITERATION=1 (first attempt) → empty, no lookup needed
# ---------------------------------------------------------------------------
echo "[10] context_part::prior_feedback — first attempt"
export ITERATION=1
COMMENTS_JSON[300]='[{"author":"github-actions[bot]","body":"<!-- autoducks:check-feedback -->\nLint failed."}]'
context_part::prior_feedback 300 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "ITERATION=1 → empty output file"
else
  fail "expected empty output on first attempt, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: prior_feedback — ITERATION>1 (retry) → marker-anchored feedback
# ---------------------------------------------------------------------------
echo "[11] context_part::prior_feedback — retry"
export ITERATION=2
context_part::prior_feedback 300 "$OUT"
if grep -q 'Lint failed.' "$OUT" && grep -q '## Previous check failure' "$OUT"; then
  pass "retry surfaces the marker-anchored feedback comment"
else
  fail "missing expected feedback: $(cat "$OUT")"
fi
unset ITERATION

# ---------------------------------------------------------------------------
# Test: prior_feedback — ITERATION>1 but no marker comment → empty
# ---------------------------------------------------------------------------
echo "[12] context_part::prior_feedback — retry, no marker comment"
export ITERATION=2
COMMENTS_JSON[301]='[{"author":"alice","body":"just a regular comment"}]'
context_part::prior_feedback 301 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "no marker-anchored comment → empty output file"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi
unset ITERATION

# ---------------------------------------------------------------------------
# Test: pr_diff
# ---------------------------------------------------------------------------
echo "[13] context_part::pr_diff"
PR_DIFF[400]=$'diff --git a/foo.txt b/foo.txt\nindex 111..222 100644\n--- a/foo.txt\n+++ b/foo.txt\n@@ -1 +1 @@\n-old\n+new\n'
context_part::pr_diff 400 "$OUT"
if [[ "$(cat "$OUT")" == "$(printf '%s' "${PR_DIFF[400]}")" ]]; then
  pass "reproduces git::get_pr_diff output byte-for-byte"
else
  fail "mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: pr_meta — derives changed files from the diff, not `gh pr view`
# ---------------------------------------------------------------------------
echo "[14] context_part::pr_meta"
PR_JSON[400]='{"number":400,"title":"My PR","baseRefName":"main","headRefName":"feature/x","state":"OPEN"}'
context_part::pr_meta 400 "$OUT"
if grep -q '# PR #400: My PR' "$OUT" && grep -q '\- Base: main' "$OUT" \
   && grep -q '\- Head: feature/x' "$OUT" && grep -q '\- State: OPEN' "$OUT" \
   && grep -q '\- foo.txt' "$OUT"; then
  pass "PR metadata + changed files derived from the diff"
else
  fail "missing expected content: $(cat "$OUT")"
fi
if [[ "$GH_CALLED" -eq 0 ]]; then
  pass "no direct gh call"
else
  fail "pr_meta called gh directly"
fi

# ---------------------------------------------------------------------------
# Test: pr_meta — absent PR → empty file, no error
# ---------------------------------------------------------------------------
echo "[15] context_part::pr_meta — absent PR"
context_part::pr_meta 999999 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "absent PR → empty output file"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: security_guidelines — file present
# ---------------------------------------------------------------------------
echo "[16] context_part::security_guidelines — present"
GUIDELINES_FILE="$SCRATCH/security-guidelines.md"
echo "Never commit secrets." > "$GUIDELINES_FILE"
AUTODUCKS_REVIEW_SECURITY_GUIDELINES="$GUIDELINES_FILE" context_part::security_guidelines 1 "$OUT"
if [[ "$(cat "$OUT")" == "Never commit secrets." ]]; then
  pass "reproduces the guidelines file byte-for-byte"
else
  fail "mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: security_guidelines — file absent → empty, no error
# ---------------------------------------------------------------------------
echo "[17] context_part::security_guidelines — absent"
AUTODUCKS_REVIEW_SECURITY_GUIDELINES="$SCRATCH/does-not-exist.md" context_part::security_guidelines 1 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "missing file → empty output file"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: design.full / plan — markers present, split into design vs. plan zone
# ---------------------------------------------------------------------------
echo "[18] context_part::design.full / plan — markers present"
ISSUE_JSON[500]=$(jq -n '{
  title: "Feature",
  body: "## Design\n\nSome design prose.\n\n<!-- autoducks:tactical:begin -->\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [1]\n```\n<!-- autoducks:tactical:end -->\n"
}')
context_part::design.full 500 "$OUT"
if grep -q 'Some design prose.' "$OUT" && ! grep -q 'waves:' "$OUT"; then
  pass "design.full contains only the design zone"
else
  fail "design.full mismatch: $(cat "$OUT")"
fi
context_part::plan 500 "$OUT"
if grep -q 'waves:' "$OUT" && ! grep -q 'Some design prose.' "$OUT"; then
  pass "plan contains only the tactical zone"
else
  fail "plan mismatch: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: design.full / plan — no markers → whole body is design, plan is empty
# ---------------------------------------------------------------------------
echo "[19] context_part::design.full / plan — no markers"
ISSUE_JSON[501]='{"title":"Feature","body":"Just prose, no plan yet."}'
context_part::design.full 501 "$OUT"
if [[ "$(cat "$OUT")" == "Just prose, no plan yet." ]]; then
  pass "design.full is the whole body when no markers exist"
else
  fail "mismatch: $(cat "$OUT")"
fi
context_part::plan 501 "$OUT"
if [[ ! -s "$OUT" ]]; then
  pass "plan is empty when no markers exist"
else
  fail "expected empty output, got: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test: design.full / plan — absent issue → empty, no error
# ---------------------------------------------------------------------------
echo "[20] context_part::design.full / plan — absent issue"
context_part::design.full 999999 "$OUT"
[[ ! -s "$OUT" ]] && pass "design.full: absent issue → empty" || fail "expected empty, got: $(cat "$OUT")"
context_part::plan 999999 "$OUT"
[[ ! -s "$OUT" ]] && pass "plan: absent issue → empty" || fail "expected empty, got: $(cat "$OUT")"

echo ""
echo "── Summary: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
