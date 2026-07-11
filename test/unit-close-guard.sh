#!/usr/bin/env bash
# Unit tests for .autoducks/agents/close-guard/run.sh — the invariant guard
# that reopens a feature/task issue closed while its delivery PR (resolved
# via resolve_feature_num_from_pr, branch-prefix.sh) is still open.
#
# Runs the real run.sh as a subprocess with `gh` shimmed out (no network
# access, no mutation of the real repo) — same technique as
# test/unit-maestro-wave-state.sh / test/unit-engineer-dor.sh. This exercises
# git::list_open_prs, its::reopen_issue, and its::comment_issue exactly as
# run.sh calls them, via their one shared choke point (`gh`).
#
# Run: bash test/unit-close-guard.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/.autoducks/agents/close-guard/run.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs.json"
GH_LOG="$SCRATCH/gh.log"
REOPEN_LOG="$SCRATCH/reopen.log"
COMMENT_LOG="$SCRATCH/comment.log"

# ── gh shim ───────────────────────────────────────────────────────────────
# close-guard/run.sh reaches the outside world only through
# git::list_open_prs / its::reopen_issue / its::comment_issue, which all
# bottom out in `gh`. Every invocation is appended to GH_LOG verbatim
# (backing the loop-safety assertion that no "issue close" ever fires);
# "pr list" additionally serves the canned MOCK_OPEN_PRS_FILE fixture, and
# "issue reopen" / "issue comment" additionally capture their args so tests
# can assert on exactly which issue was reopened and what was said.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr list")
    cat "${MOCK_OPEN_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]"
    ;;
  "issue reopen")
    echo "$3" >> "$REOPEN_LOG"
    ;;
  "issue comment")
    id="$3"
    prev=""
    body=""
    for arg in "$@"; do
      [[ "$prev" == "--body" ]] && body="$arg"
      prev="$arg"
    done
    {
      echo "=== issue #$id ==="
      echo "$body"
      echo "=== end ==="
    } >> "$COMMENT_LOG"
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_close_guard CLOSED_ISSUE — invokes the real run.sh as a subprocess with
# the shim first on PATH; stdout/stderr land in scratch files so callers can
# assert on both the exit code and the ::notice::/::warning:: annotations.
run_close_guard() {
  local closed_issue="$1"
  local rc=0
  env \
    PATH="$SCRATCH/bin:$PATH" \
    MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" \
    GH_LOG="$GH_LOG" \
    REOPEN_LOG="$REOPEN_LOG" \
    COMMENT_LOG="$COMMENT_LOG" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="x/y" \
    CLOSED_ISSUE="$closed_issue" \
    bash "$RUN_SH" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

: > "$GH_LOG"

# reset_logs — clears the per-scenario reopen/comment logs between scenarios,
# but deliberately leaves GH_LOG accumulating across the whole run so the
# loop-safety check (5) below sees every `gh` invocation made by every
# scenario, not just the last one.
reset_logs() {
  : > "$REOPEN_LOG"
  : > "$COMMENT_LOG"
}

# =============================================================================
# 1) Open PR on a pipeline branch feature/831-… resolves to #831
# =============================================================================
echo "── open delivery PR on feature/831-… reopens #831 and comments naming the PR ──"
reset_logs
jq -n '[{number: 900, title: "Delivery", headRefName: "feature/831-add-thing",
         body: "", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"

RC=0
run_close_guard 831 || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(cat "$SCRATCH/stderr.log")"
grep -qx "831" "$REOPEN_LOG" && pass "reopens #831" || fail "expected reopen of #831, got: $(cat "$REOPEN_LOG")"
grep -q "=== issue #831 ===" "$COMMENT_LOG" && pass "comments on #831" || fail "no comment on #831: $(cat "$COMMENT_LOG")"
grep -q "#900" "$COMMENT_LOG" && pass "comment names the open delivery PR #900" || fail "comment missing PR reference: $(cat "$COMMENT_LOG")"
grep -q "::warning::" "$SCRATCH/stdout.log" && pass "emits a ::warning:: annotation" || fail "no ::warning:: annotation: $(cat "$SCRATCH/stdout.log")"

# =============================================================================
# 2) Open PR on a non-pipeline head, resolved via body `Closes #831`
# =============================================================================
echo "── open delivery PR with body 'Closes #831' on a non-pipeline head reopens #831 ──"
reset_logs
jq -n '[{number: 901, title: "Delivery", headRefName: "patch-1",
         body: "Fixes the thing.\n\nCloses #831", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"

RC=0
run_close_guard 831 || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(cat "$SCRATCH/stderr.log")"
grep -qx "831" "$REOPEN_LOG" && pass "reopens #831" || fail "expected reopen of #831, got: $(cat "$REOPEN_LOG")"
grep -q "#901" "$COMMENT_LOG" && pass "comment names the open delivery PR #901" || fail "comment missing PR reference: $(cat "$COMMENT_LOG")"

# =============================================================================
# 3) Delivery PR already merged — absent from the open-PR list, an unrelated
#    open PR (for a different issue) must not cause a false-positive reopen.
# =============================================================================
echo "── delivery PR already merged (absent from open list) — no reopen ──"
reset_logs
jq -n '[{number: 902, title: "Unrelated", headRefName: "feature/555-other-thing",
         body: "", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"

RC=0
run_close_guard 831 || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(cat "$SCRATCH/stderr.log")"
[[ -s "$REOPEN_LOG" ]] && fail "unexpected reopen: $(cat "$REOPEN_LOG")" || pass "no reopen"
[[ -s "$COMMENT_LOG" ]] && fail "unexpected comment: $(cat "$COMMENT_LOG")" || pass "no comment"
grep -q "::notice::" "$SCRATCH/stdout.log" && pass "emits a ::notice:: annotation" || fail "no ::notice:: annotation: $(cat "$SCRATCH/stdout.log")"

# =============================================================================
# 4) No open PRs at all — no reopen
# =============================================================================
echo "── no open PRs at all — no reopen ──"
reset_logs
echo "[]" > "$MOCK_OPEN_PRS_FILE"

RC=0
run_close_guard 831 || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(cat "$SCRATCH/stderr.log")"
[[ -s "$REOPEN_LOG" ]] && fail "unexpected reopen: $(cat "$REOPEN_LOG")" || pass "no reopen"
[[ -s "$COMMENT_LOG" ]] && fail "unexpected comment: $(cat "$COMMENT_LOG")" || pass "no comment"

# =============================================================================
# 5) Loop safety — across every scenario above, the guard never itself
#    closes (or re-closes) an issue.
# =============================================================================
echo "── loop safety: no 'issue close' call in any scenario ──"
if grep -q "issue close" "$GH_LOG"; then
  fail "close-guard issued an 'issue close' call: $(grep 'issue close' "$GH_LOG")"
else
  pass "no 'issue close' call was made"
fi

echo ""
echo "═══ close-guard: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
