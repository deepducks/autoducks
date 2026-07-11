#!/usr/bin/env bash
# Unit tests for .autoducks/core/context/resolve-context.sh
# Run: bash test/unit-resolve-context.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_AUTODUCKS_ROOT="$REPO_ROOT/.autoducks"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# resolve-context.sh (and the modules it sources) resolve everything off
# $AUTODUCKS_ROOT/core/..., and it reads $AUTODUCKS_ROOT/autoducks.json
# directly — symlink the real `core` tree into a scratch root so each test
# can swap in its own autoducks.json without touching the repo's.
CONFIG_ROOT="$SCRATCH/autoducks-root"
mkdir -p "$CONFIG_ROOT"
ln -s "$REAL_AUTODUCKS_ROOT/core" "$CONFIG_ROOT/core"
export AUTODUCKS_ROOT="$CONFIG_ROOT"

write_config() {
  printf '%s' "$1" > "$CONFIG_ROOT/autoducks.json"
}
write_config '{}'

# ---------------------------------------------------------------------------
# its::* / git::* stubs — table-driven, same convention as unit-context-parts.sh.
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

gh() {
  GH_CALLED=1
  echo "unexpected gh call: $*" >&2
  return 1
}

# shellcheck source=/dev/null
source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"

# ---------------------------------------------------------------------------
# /tmp housekeeping — resolve_context always writes real canonical /tmp
# paths (that's its contract), so scrub them between scenarios.
# ---------------------------------------------------------------------------
RC_TMP_FILES=(
  /tmp/issue-request.md /tmp/issue-body-raw.md /tmp/issue-comments.md
  /tmp/issue-meta.md /tmp/design-zone.md /tmp/tactical-zone-current.md
  /tmp/task-spec.md /tmp/design-plan.md /tmp/task-criteria.md
  /tmp/pr-diff.patch /tmp/pr-meta.md /tmp/security-guidelines.md
  /tmp/context-manifest.json
  /tmp/design-problem_statement.md /tmp/design-proposed_solution.md
  /tmp/design-technical_design.md /tmp/design-dependencies.md
  /tmp/design-constraints.md /tmp/design-out_of_scope.md
)
rc_clean_tmp() { rm -f "${RC_TMP_FILES[@]}"; }

# ===========================================================================
# [1] Architect defaults — issue_comments injected on a FIRST-PASS body
#     (no tactical markers) — today's architect pre.sh only appends comments
#     on revision; the resolver's "every turn" default now injects them here
#     too.
# ===========================================================================
echo "[1] architect defaults — first-pass body gets comments injected"
rc_clean_tmp
ISSUE_JSON[500]=$(jq -n '{title: "Feature Title", body: "Feature body line 1.\nLine 2."}')
COMMENTS_JSON[500]='[{"author":"alice","body":"Looks good"},{"author":"bob","body":"Needs tweaks"}]'

resolve_context architect 500

REF="$SCRATCH/ref1.md"
echo "${ISSUE_JSON[500]}" | jq -r '"# " + .title + "\n\n" + .body' > "$REF"
{
  echo ""
  echo "## Reviewer feedback / adjustments (steer the revision)"
  echo ""
  echo "${COMMENTS_JSON[500]}" | jq -r '.[] | "### " + .author + "\n\n" + .body + "\n\n---\n"'
} >> "$REF"

if cmp -s "$REF" /tmp/issue-request.md; then
  pass "issue-request.md matches today's revision-shaped output, on a first-pass body"
else
  fail "issue-request.md mismatch"
  diff "$REF" /tmp/issue-request.md || true
fi

REF_RAW="$SCRATCH/ref1-raw.md"
echo "${ISSUE_JSON[500]}" | jq -r '.body' > "$REF_RAW"
if cmp -s "$REF_RAW" /tmp/issue-body-raw.md; then
  pass "issue-body-raw.md matches"
else
  fail "issue-body-raw.md mismatch"
fi

# ===========================================================================
# [2] Architect defaults — revision-shaped body (tactical markers present)
#     still injects comments identically.
# ===========================================================================
echo "[2] architect defaults — revision body also gets comments injected"
rc_clean_tmp
ISSUE_JSON[501]=$(jq -n '{title: "Feature Title", body: "Design prose.\n\n<!-- autoducks:tactical:begin -->\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [601]\n```\n<!-- autoducks:tactical:end -->\n"}')
COMMENTS_JSON[501]='[{"author":"alice","body":"Looks good"}]'

resolve_context architect 501

REF2="$SCRATCH/ref2.md"
echo "${ISSUE_JSON[501]}" | jq -r '"# " + .title + "\n\n" + .body' > "$REF2"
{
  echo ""
  echo "## Reviewer feedback / adjustments (steer the revision)"
  echo ""
  echo "${COMMENTS_JSON[501]}" | jq -r '.[] | "### " + .author + "\n\n" + .body + "\n\n---\n"'
} >> "$REF2"

if cmp -s "$REF2" /tmp/issue-request.md; then
  pass "issue-request.md matches today's revision output byte-for-byte"
else
  fail "issue-request.md mismatch on revision body"
  diff "$REF2" /tmp/issue-request.md || true
fi

# ===========================================================================
# [3] Engineer defaults — issue-request.md / issue-body-raw.md / design-zone.md
#     byte-for-byte identical to today's outputs; issue_comments materializes
#     into a new (not previously read) file without disturbing the rest.
# ===========================================================================
echo "[3] engineer defaults — byte-for-byte today's outputs + new comments file"
rc_clean_tmp
ISSUE_JSON[510]=$(jq -n '{title: "Engineer Feature", body: "Some design prose.\nMore prose."}')
COMMENTS_JSON[510]='[{"author":"carol","body":"lgtm"}]'

resolve_context engineer 510

REF3="$SCRATCH/ref3.md"
echo "${ISSUE_JSON[510]}" | jq -r '"# " + .title + "\n\n" + .body' > "$REF3"
if cmp -s "$REF3" /tmp/issue-request.md; then
  pass "engineer issue-request.md byte-for-byte"
else
  fail "engineer issue-request.md mismatch"
  diff "$REF3" /tmp/issue-request.md || true
fi

REF3_RAW="$SCRATCH/ref3-raw.md"
echo "${ISSUE_JSON[510]}" | jq -r '.body' > "$REF3_RAW"
if cmp -s "$REF3_RAW" /tmp/issue-body-raw.md; then
  pass "engineer issue-body-raw.md byte-for-byte"
else
  fail "engineer issue-body-raw.md mismatch"
fi

# No tactical markers in this fixture → design.full is the whole body, same
# as split_body's own no-markers behavior (verified directly against the
# catalog function it routes through).
REF3_DESIGN="$SCRATCH/ref3-design.md"
context_part::design.full 510 "$REF3_DESIGN"
if cmp -s "$REF3_DESIGN" /tmp/design-zone.md; then
  pass "engineer design-zone.md matches context_part::design.full"
else
  fail "engineer design-zone.md mismatch"
fi

REF3_COMMENTS="$SCRATCH/ref3-comments.md"
context_part::issue_comments 510 "$REF3_COMMENTS"
if cmp -s "$REF3_COMMENTS" /tmp/issue-comments.md; then
  pass "engineer issue-comments.md materializes (new file, doesn't exist today)"
else
  fail "engineer issue-comments.md mismatch"
fi

# ===========================================================================
# [4] Developer defaults — task-spec.md byte-for-byte, including the
#     ITERATION>1 retry append.
# ===========================================================================
echo "[4] developer defaults — task-spec.md byte-for-byte, first attempt"
rc_clean_tmp
ISSUE_JSON[520]=$(jq -n '{title: "Task Title", body: "Do the thing."}')
unset ITERATION

resolve_context developer 520

REF4="$SCRATCH/ref4.md"
echo "${ISSUE_JSON[520]}" | jq -r '"# " + .title + "\n\n" + .body' > "$REF4"
if cmp -s "$REF4" /tmp/task-spec.md; then
  pass "developer task-spec.md byte-for-byte (ITERATION=1, no append)"
else
  fail "developer task-spec.md mismatch (first attempt)"
  diff "$REF4" /tmp/task-spec.md || true
fi

echo "[4b] developer defaults — ITERATION>1 retry append"
rc_clean_tmp
COMMENTS_JSON[520]=$(jq -n --arg marker "$AUTODUCKS_CHECK_FEEDBACK_MARKER" \
  '[{author:"github-actions[bot]", body: ($marker + "\nLint failed on line 3.")}]')
export ITERATION=2

resolve_context developer 520

REF4B="$SCRATCH/ref4b.md"
echo "${ISSUE_JSON[520]}" | jq -r '"# " + .title + "\n\n" + .body' > "$REF4B"
{
  echo ""
  echo "## Previous check failure"
  echo ""
  echo "${COMMENTS_JSON[520]}" | jq -r \
    --arg marker "$AUTODUCKS_CHECK_FEEDBACK_MARKER" \
    '[.[] | select((.author == "github-actions[bot]" or .author == "github-actions")
                   and ((.body // "") | contains($marker)))]
     | sort_by(.updated_at // .created_at // "") | last | .body // empty'
} >> "$REF4B"

if cmp -s "$REF4B" /tmp/task-spec.md; then
  pass "developer task-spec.md byte-for-byte (ITERATION=2, retry feedback appended)"
else
  fail "developer task-spec.md mismatch (retry)"
  diff "$REF4B" /tmp/task-spec.md || true
fi
unset ITERATION

# ===========================================================================
# [5] Reviewer defaults — design-plan.md / task-criteria.md / pr-diff.patch /
#     pr-meta.md / security-guidelines.md.
# ===========================================================================
echo "[5] reviewer defaults — byte-for-byte today's outputs"
rc_clean_tmp
ISSUE_JSON[530]=$(jq -n '{title: "Feature For Review", body: "## Plan\n\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [531, 532]\n```\n"}')
ISSUE_JSON[531]='{"title":"Task A","body":"Criteria A."}'
ISSUE_JSON[532]='{"title":"Task B","body":"Criteria B."}'
PR_JSON[900]='{"number":900,"title":"My PR","baseRefName":"main","headRefName":"feature/x","state":"OPEN"}'
PR_DIFF[900]=$'diff --git a/foo.txt b/foo.txt\nindex 111..222 100644\n--- a/foo.txt\n+++ b/foo.txt\n@@ -1 +1 @@\n-old\n+new\n'

GUIDELINES_FILE="$SCRATCH/security-guidelines.md"
echo "Never commit secrets." > "$GUIDELINES_FILE"
export AUTODUCKS_REVIEW_SECURITY_GUIDELINES="$GUIDELINES_FILE"

resolve_context reviewer 900 530

REF5_PLAN="$SCRATCH/ref5-plan.md"
echo "${ISSUE_JSON[530]}" | jq -r '.title,.body' > "$REF5_PLAN"
if cmp -s "$REF5_PLAN" /tmp/design-plan.md; then
  pass "reviewer design-plan.md byte-for-byte"
else
  fail "reviewer design-plan.md mismatch"
  diff "$REF5_PLAN" /tmp/design-plan.md || true
fi

REF5_CRIT="$SCRATCH/ref5-criteria.md"
context_part::task_criteria 530 "$REF5_CRIT"
if cmp -s "$REF5_CRIT" /tmp/task-criteria.md; then
  pass "reviewer task-criteria.md matches context_part::task_criteria"
else
  fail "reviewer task-criteria.md mismatch"
fi

REF5_DIFF="$SCRATCH/ref5-diff.patch"
context_part::pr_diff 900 "$REF5_DIFF"
if cmp -s "$REF5_DIFF" /tmp/pr-diff.patch; then
  pass "reviewer pr-diff.patch matches context_part::pr_diff"
else
  fail "reviewer pr-diff.patch mismatch"
fi

REF5_META="$SCRATCH/ref5-meta.md"
context_part::pr_meta 900 "$REF5_META"
if cmp -s "$REF5_META" /tmp/pr-meta.md; then
  pass "reviewer pr-meta.md matches context_part::pr_meta"
else
  fail "reviewer pr-meta.md mismatch"
fi

REF5_SEC="$SCRATCH/ref5-security.md"
context_part::security_guidelines 900 "$REF5_SEC"
if cmp -s "$REF5_SEC" /tmp/security-guidelines.md; then
  pass "reviewer security-guidelines.md matches context_part::security_guidelines"
else
  fail "reviewer security-guidelines.md mismatch"
fi

if [[ "$GH_CALLED" -eq 0 ]]; then
  pass "no direct gh call anywhere in resolve_context"
else
  fail "resolve_context called gh directly"
fi

# ===========================================================================
# [6] /tmp/context-manifest.json — {agent, parts:[{id,file,bytes}]}
# ===========================================================================
echo "[6] context-manifest.json structure"
if [[ -f /tmp/context-manifest.json ]] \
   && [[ "$(jq -r '.agent' /tmp/context-manifest.json)" == "reviewer" ]] \
   && [[ "$(jq '.parts | length' /tmp/context-manifest.json)" -eq 7 ]] \
   && [[ "$(jq -r '.parts[] | select(.id == "pr_diff") | .file' /tmp/context-manifest.json)" == "/tmp/pr-diff.patch" ]] \
   && [[ "$(jq -r '.parts[] | select(.id == "pr_diff") | .bytes' /tmp/context-manifest.json)" -gt 0 ]]; then
  pass "manifest lists {id,file,bytes} per injected part"
else
  fail "manifest mismatch: $(cat /tmp/context-manifest.json)"
fi

# ===========================================================================
# [7] Validation — unknown part id
# ===========================================================================
echo "[7] validation — unknown part id aborts with a fix hint"
write_config '{"context": {"architect": {"parts": ["not_a_real_part"]}}}'
rc_clean_tmp
set +e
ERR_OUT="$(resolve_context architect 500 2>&1 1>/dev/null)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  pass "unknown part id returns non-zero"
else
  fail "expected non-zero return for unknown part id"
fi
if [[ "$ERR_OUT" == *"not_a_real_part"* && "$ERR_OUT" == *".context.architect.parts"* ]]; then
  pass "error message names the bad id and the fix location"
else
  fail "missing fix hint: $ERR_OUT"
fi

# ===========================================================================
# [8] Validation — part unavailable to this agent
# ===========================================================================
echo "[8] validation — part unavailable to this agent aborts with a fix hint"
write_config '{"context": {"architect": {"parts": ["pr_diff"]}}}'
rc_clean_tmp
set +e
ERR_OUT2="$(resolve_context architect 500 2>&1 1>/dev/null)"
RC2=$?
set -e
if [[ "$RC2" -ne 0 && "$ERR_OUT2" == *"pr_diff"* ]]; then
  pass "part unavailable to agent returns non-zero with a fix hint"
else
  fail "expected non-zero return + fix hint, got rc=$RC2: $ERR_OUT2"
fi

write_config '{}'

# ===========================================================================
# [9] Legacy fallback — design.<section> selected but the body has no
#     section markers degrades to the full design zone, logs ::notice::,
#     and never leaves the design empty.
# ===========================================================================
echo "[9] legacy fallback — no section markers degrades to design.full"
write_config '{"context": {"developer": {"parts": ["design.problem_statement"]}}}'
rc_clean_tmp
ISSUE_JSON[540]=$(jq -n '{title:"Task", body:"Do it."}')
ISSUE_JSON[550]=$(jq -n '{title:"Feature no markers", body:"Just prose, no design markers at all."}')

NOTICE_OUT="$(resolve_context developer 540 550 2>/dev/null)"

if [[ "$(cat /tmp/design-zone.md 2>/dev/null)" == "Just prose, no design markers at all." ]]; then
  pass "falls back to the full design zone, never empty"
else
  fail "design-zone.md should hold the full body: $(cat /tmp/design-zone.md 2>/dev/null || echo '<missing>')"
fi
if [[ ! -f /tmp/design-problem_statement.md || ! -s /tmp/design-problem_statement.md ]]; then
  pass "no dangling (empty) per-section file from the degraded selection"
else
  fail "design-problem_statement.md unexpectedly non-empty: $(cat /tmp/design-problem_statement.md)"
fi
if [[ "$NOTICE_OUT" == *"::notice::"* ]]; then
  pass "logs a ::notice:: for the legacy fallback"
else
  fail "expected a ::notice:: log line, got: $NOTICE_OUT"
fi

# ===========================================================================
# [10] design.full wins over an explicitly-selected design.<section> when
#      markers ARE present.
# ===========================================================================
echo "[10] design.full precedence over design.<section> when both selected"
write_config '{"context": {"engineer": {"parts": ["design.full", "design.problem_statement"]}}}'
rc_clean_tmp
ISSUE_JSON[560]=$(jq -n '{title:"Feature", body:"<!-- autoducks:design:problem_statement:begin -->\nThe problem.\n<!-- autoducks:design:problem_statement:end -->\n\n<!-- autoducks:tactical:begin -->\nplan here\n<!-- autoducks:tactical:end -->\n"}')

NOTICE_OUT2="$(resolve_context engineer 560 2>/dev/null)"

if [[ -f /tmp/design-zone.md ]] && grep -q "The problem." /tmp/design-zone.md; then
  pass "design.full is materialized"
else
  fail "design-zone.md missing expected content"
fi
if [[ ! -f /tmp/design-problem_statement.md ]]; then
  pass "the individually-selected design.<section> is dropped in favor of design.full"
else
  fail "design-problem_statement.md should not have been written"
fi
if [[ "$NOTICE_OUT2" == *"::notice::"* ]]; then
  pass "logs a ::notice:: for the design.full precedence"
else
  fail "expected a ::notice:: log line, got: $NOTICE_OUT2"
fi

write_config '{}'

echo ""
echo "── Summary: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
