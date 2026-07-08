#!/usr/bin/env bash
# Maestro wave-state unit test — drives Phase 6-8 of run.sh (done-task
# derivation, wave-state computation, next-wave selection, and dispatch) for
# a partial-success wave:
#
#   Wave 1: task A (merged PR)         — done
#           task B (failed, no PR)     — re-dispatched
#           task C (open PR, healthy)  — already in flight, skipped
#   Wave 2: task D (untouched)
#
# Asserts:
#   - DONE_TASKS contains only A; Wave 1 stays "pending"; NEXT_WAVE resolves
#     to Wave 1 (the previous-wave gate keeps Wave 2 from being touched)
#   - the dispatched-vs-skipped partition, read from a captured dispatch log
#     (not stdout scraping alone)
#   - the 🌊 summary comment partitions Dispatched vs Skipped consistently
#     with the dispatch log
#   - G5: a task with an open PR converges to a single live dispatch even
#     across repeated Maestro re-runs while it is mid-build. (A first run
#     that fails *before* opening a PR — task B's scenario here — is instead
#     resolved by the Developer's own branch-resume guard, covered by
#     test/unit-idempotency.sh's G1: the queued re-run resumes the same
#     branch rather than cutting a second one, so the Maestro-level retry
#     asserted below never fans out into two live PRs.)
#
# Runs the real run.sh as a subprocess with `gh` shimmed out (no network
# access, no mutation of the real repo) — same technique as
# test/unit-idempotency.sh.
#
# Run: bash test/unit-maestro-wave-state.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/.autoducks/agents/maestro/run.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
FEATURE=500
TASK_A=501   # Wave 1 — merged PR, done
TASK_B=502   # Wave 1 — failed run, no PR at all
TASK_C=503   # Wave 1 — open PR, healthy/in-flight
TASK_D=504   # Wave 2 — untouched

MOCK_ISSUE_DIR="$SCRATCH/issues"
GH_CAPTURE_DIR="$SCRATCH/captured"
DISPATCH_LOG="$SCRATCH/dispatch.log"
COMMENT_LOG="$SCRATCH/comments.log"
mkdir -p "$MOCK_ISSUE_DIR" "$GH_CAPTURE_DIR"
: > "$DISPATCH_LOG"
: > "$COMMENT_LOG"

MOCK_MERGED_PRS_FILE="$SCRATCH/merged_prs.json"
MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs.json"

jq -n --arg t "$TASK_A" \
  '[{number: 900, title: "Task A done", body: ("Implements task A.\n\nFixes #" + $t)}]' \
  > "$MOCK_MERGED_PRS_FILE"

# Only C has an open PR to begin with — B's run failed before ever cutting
# a branch, so there is nothing to find for it yet.
jq -n --arg t "$TASK_C" \
  '[{number: 950, title: "Task C in progress", headRefName: "feature/500-add-search/task/503-c",
     body: ("Working on task C.\n\nFixes #" + $t), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"

# ── Two-wave fixture: Wave 1 = A, B, C; Wave 2 = D ───────────────────────
FEATURE_BODY=$(cat <<EOF
## Plan

\`\`\`yaml
waves:
  - name: Wave 1
    tasks: [$TASK_A, $TASK_B, $TASK_C]
  - name: Wave 2
    tasks: [$TASK_D]
\`\`\`

## Progress

- [ ] #$TASK_A Task A \`P0\`
- [ ] #$TASK_B Task B \`P0\`
- [ ] #$TASK_C Task C \`P0\`
- [ ] #$TASK_D Task D \`P0\`
EOF
)

jq -n --arg body "$FEATURE_BODY" \
  '{title: "Add search", body: $body, labels: ["Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE.json"

# ── gh shim ───────────────────────────────────────────────────────────────
# run.sh reaches the outside world only through its::*/git::* provider
# functions, which all bottom out in `gh`. Putting a fake `gh` first on PATH
# stubs git::list_merged_prs/git::list_open_prs (their `pr list` calls
# return the canned fixtures below) and captures every
# git::dispatch_workflow call (`gh workflow run`) verbatim to DISPATCH_LOG,
# while letting the real run.sh execute completely unmodified.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view")
    id="$3"
    if [[ -f "$MOCK_ISSUE_DIR/$id.json" ]]; then
      cat "$MOCK_ISSUE_DIR/$id.json"
    else
      echo '{}'
    fi
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
    echo "https://github.com/x/y/issues/$id#issuecomment-777"
    ;;
  "issue edit")
    id="$3"
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "--body-file" ]]; then
        cp "$arg" "$GH_CAPTURE_DIR/$id.md"
      fi
      prev="$arg"
    done
    ;;
  "pr list")
    state="open"
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "--state" ]] && state="$arg"
      prev="$arg"
    done
    case "$state" in
      open)   cat "${MOCK_OPEN_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
      merged) cat "${MOCK_MERGED_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
      *)      echo "[]" ;;
    esac
    ;;
  "workflow run")
    echo "=== gh $* ===" >> "$DISPATCH_LOG"
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_maestro — invokes the real run.sh as a subprocess with the shim first
# on PATH; stdout/stderr land in scratch files so callers can assert on
# both the exit code and the [maestro] log lines.
run_maestro() {
  local rc=0
  env \
    PATH="$SCRATCH/bin:$PATH" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    GH_CAPTURE_DIR="$GH_CAPTURE_DIR" \
    DISPATCH_LOG="$DISPATCH_LOG" \
    COMMENT_LOG="$COMMENT_LOG" \
    MOCK_MERGED_PRS_FILE="$MOCK_MERGED_PRS_FILE" \
    MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    FEATURE_ISSUE="$FEATURE" \
    RUN_ID=1 \
    bash "$RUN_SH" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

count_of() {
  # count_of PATTERN FILE — occurrence count, tolerant of zero matches under set -e
  grep -c "$1" "$2" 2>/dev/null || true
}

# =============================================================================
# Run 1 — partial-success wave: A merged, B failed/no-PR, C open/in-flight
# =============================================================================
echo "── Maestro: partial-success Wave 1 (A done, B retried, C in flight) ──"

RC1=0
run_maestro || RC1=$?
[[ "$RC1" -eq 0 ]] \
  && pass "run 1: maestro exits 0" \
  || fail "run 1: rc=$RC1: $(tail -10 "$SCRATCH/stderr.log")"

# --- DONE_TASKS / wave state / NEXT_WAVE (Phase 6-7), from [maestro] logs ---
grep -qx '\[maestro\] Found 2 waves' "$SCRATCH/stderr.log" \
  && pass "two waves parsed from the fixture plan" \
  || fail "expected 2 waves, log has: $(grep '\[maestro\] Found' "$SCRATCH/stderr.log" || echo none)"

grep -qx "\\[maestro\\] Done tasks: $TASK_A" "$SCRATCH/stderr.log" \
  && pass "DONE_TASKS contains only A ($TASK_A)" \
  || fail "expected 'Done tasks: $TASK_A', log has: $(grep '\[maestro\] Done tasks' "$SCRATCH/stderr.log" || echo none)"

grep -qx "\\[maestro\\] Dispatching wave 0: Wave 1" "$SCRATCH/stderr.log" \
  && pass "NEXT_WAVE resolves to Wave 1 (index 0), not Wave 2 — previous-wave gate holds" \
  || fail "expected wave 0 (Wave 1) to be dispatched, log has: $(grep '\[maestro\] Dispatching' "$SCRATCH/stderr.log" || echo none)"

# Independent corroboration of DONE_TASKS: the feature issue's checkboxes,
# captured from the real body-file update_checkboxes() wrote via
# its::update_issue_body — only #501 should have flipped to [x].
CAPTURED_BODY="$GH_CAPTURE_DIR/$FEATURE.md"
if [[ -f "$CAPTURED_BODY" ]] \
  && grep -q "^- \[x\] #$TASK_A " "$CAPTURED_BODY" \
  && grep -q "^- \[ \] #$TASK_B " "$CAPTURED_BODY" \
  && grep -q "^- \[ \] #$TASK_C " "$CAPTURED_BODY" \
  && grep -q "^- \[ \] #$TASK_D " "$CAPTURED_BODY"; then
  pass "feature checkboxes: only #$TASK_A flipped to done"
else
  fail "feature checkboxes did not match the partial-success fixture: $(cat "$CAPTURED_BODY" 2>/dev/null || echo 'no capture')"
fi

# --- Dispatched vs skipped partition, from the captured dispatch log ---
[[ "$(count_of "issue_number=$TASK_B" "$DISPATCH_LOG")" -eq 1 ]] \
  && pass "dispatch log: B (#$TASK_B) dispatched — re-attempt after its failed run" \
  || fail "expected exactly one dispatch for #$TASK_B, dispatch log: $(cat "$DISPATCH_LOG")"

[[ "$(count_of "issue_number=$TASK_A" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "dispatch log: A (#$TASK_A) never dispatched — skipped via is_done" \
  || fail "A (#$TASK_A) was dispatched despite already being done: $(cat "$DISPATCH_LOG")"

[[ "$(count_of "issue_number=$TASK_C" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "dispatch log: C (#$TASK_C) skipped — already has an open PR" \
  || fail "C (#$TASK_C) was dispatched despite an open PR: $(cat "$DISPATCH_LOG")"

[[ "$(count_of "issue_number=$TASK_D" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "dispatch log: D (#$TASK_D, Wave 2) untouched" \
  || fail "D (#$TASK_D) was dispatched even though Wave 2 must wait: $(cat "$DISPATCH_LOG")"

# --- 🌊 summary partitions Dispatched vs Skipped consistently ---
if grep -q '🌊 \*\*Wave 1 of 2 dispatched: Wave 1\*\*' "$COMMENT_LOG" \
  && grep -q '\*\*Dispatched:\*\* 502' "$COMMENT_LOG" \
  && grep -q '\*\*Skipped (already done or in flight):\*\* 501 503' "$COMMENT_LOG"; then
  pass "🌊 summary partitions Dispatched (502) vs Skipped (501, 503) consistently with the dispatch log"
else
  fail "🌊 summary did not match the expected partition: $(cat "$COMMENT_LOG")"
fi

echo ""

# =============================================================================
# G5 — single-live-dispatch convergence: re-running while B is mid-build
# must never dispatch it a second time.
# =============================================================================
echo "── G5: a task with an open PR converges to a single live dispatch ──"

# Simulate the Developer having picked up B's dispatch from run 1 and opened
# a (still-unmerged) PR for it — the mid-build state the re-run must respect.
jq -n --arg c "$TASK_C" --arg b "$TASK_B" \
  '[{number: 950, title: "Task C in progress", headRefName: "feature/500-add-search/task/503-c",
     body: ("Working on task C.\n\nFixes #" + $c), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"},
    {number: 951, title: "Task B in progress", headRefName: "feature/500-add-search/task/502-b",
     body: ("Working on task B.\n\nFixes #" + $b), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"

RC2=0
run_maestro || RC2=$?
[[ "$RC2" -eq 0 ]] \
  && pass "run 2 (mid-build re-run): maestro exits 0" \
  || fail "run 2: rc=$RC2: $(tail -10 "$SCRATCH/stderr.log")"

[[ "$(count_of "issue_number=$TASK_B" "$DISPATCH_LOG")" -eq 1 ]] \
  && pass "G5: #$TASK_B was dispatched exactly once across both runs — never twice while its PR is open" \
  || fail "G5 violated: #$TASK_B dispatch count across both runs is $(count_of "issue_number=$TASK_B" "$DISPATCH_LOG"), expected 1: $(cat "$DISPATCH_LOG")"

if grep -q '\*\*Skipped (already done or in flight):\*\* 501 502 503' "$COMMENT_LOG"; then
  pass "run 2: all of Wave 1 (501, 502, 503) now reports skipped/in-flight — guard and is_done converge"
else
  fail "run 2: expected all of Wave 1 skipped, comment log: $(tail -20 "$COMMENT_LOG")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ maestro-wave-state: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
