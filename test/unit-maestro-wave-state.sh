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
MAESTRO_CID_FILE="/tmp/autoducks-maestro-comment-id"
trap 'rm -rf "$SCRATCH"; rm -f "$MAESTRO_CID_FILE" /tmp/autoducks-status-comment-id.*' EXIT
rm -f "$MAESTRO_CID_FILE" /tmp/autoducks-status-comment-id.*

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

# Persistent-comment store (shared across the two run_maestro invocations
# below, just like a real GitHub issue's comments persist across separate
# workflow runs) — backs the its::list_comments / its::update_comment /
# its::comment_issue trio the gh shim serves further down.
MOCK_COMMENTS_FILE="$SCRATCH/comments.json"
echo "[]" > "$MOCK_COMMENTS_FILE"

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
    if [[ "$*" == *"--json state,stateReason"* ]]; then
      # Task-issue state lookup (DONE_TASKS closed-as-completed union) — a
      # dedicated per-task fixture, separate from the issue body/labels file
      # used by its::get_issue, so tests can set state without reshaping the
      # full mock issue.
      if [[ -f "$MOCK_ISSUE_DIR/$id.state.json" ]]; then
        jq -r '(.state // "") + " " + (.stateReason // "")' "$MOCK_ISSUE_DIR/$id.state.json"
      else
        echo " "
      fi
    elif [[ -f "$MOCK_ISSUE_DIR/$id.json" ]]; then
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
    # its::comment_issue — append a new bot comment to the persistent store
    # (backs its::list_comments for the marker rediscovery a later run does).
    new_id=$(( $(jq 'length' "$MOCK_COMMENTS_FILE" 2>/dev/null || echo 0) + 1000 ))
    jq --arg body "$body" --argjson id "$new_id" \
      '. + [{id: $id, author: "github-actions[bot]", body: $body}]' \
      "$MOCK_COMMENTS_FILE" > "$MOCK_COMMENTS_FILE.tmp" && mv "$MOCK_COMMENTS_FILE.tmp" "$MOCK_COMMENTS_FILE"
    echo "https://github.com/x/y/issues/$id#issuecomment-$new_id"
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
  "api "*"/issues/"*"/comments")
    # its::list_comments ISSUE_ID — GET repos/<repo>/issues/<n>/comments
    cat "${MOCK_COMMENTS_FILE:-/dev/null}" 2>/dev/null || echo "[]"
    ;;
  "api "*"/issues/comments/"*)
    # its::update_comment COMMENT_ID BODY — PATCH repos/<repo>/issues/comments/<id>
    cid="${2##*/}"
    prev=""
    body=""
    for arg in "$@"; do
      [[ "$prev" == "-f" ]] && body="${arg#body=}"
      prev="$arg"
    done
    jq --arg id "$cid" --arg body "$body" \
      'map(if (.id | tostring) == $id then .body = $body else . end)' \
      "$MOCK_COMMENTS_FILE" > "$MOCK_COMMENTS_FILE.tmp" && mv "$MOCK_COMMENTS_FILE.tmp" "$MOCK_COMMENTS_FILE"
    {
      echo "=== update comment #$cid ==="
      echo "$body"
      echo "=== end ==="
    } >> "$COMMENT_LOG"
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_maestro [EXTRA_ENV=val ...] — invokes the real run.sh as a subprocess
# with the shim first on PATH; stdout/stderr land in scratch files so callers
# can assert on both the exit code and the [maestro] log lines. Each call
# simulates a fresh GHA runner: the /tmp same-run cache
# orchestrator_comment::upsert relies on, and the per-feature status-comment
# id file status_comment::start/report() rely on, are cleared first — forcing
# rediscovery of a prior run's persistent comment via its::list_comments +
# the embedded marker, and (for the transient comment) proving a later
# event-driven run genuinely has no access to an earlier human run's /tmp
# state, rather than a lucky same-process /tmp hit. Extra KEY=VALUE args
# (e.g. COMMENT_ID=1 to simulate a human-triggered run) are forwarded as
# additional env vars.
run_maestro() {
  local rc=0
  rm -f "$MAESTRO_CID_FILE" /tmp/autoducks-status-comment-id.*
  env \
    PATH="$SCRATCH/bin:$PATH" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    GH_CAPTURE_DIR="$GH_CAPTURE_DIR" \
    DISPATCH_LOG="$DISPATCH_LOG" \
    COMMENT_LOG="$COMMENT_LOG" \
    MOCK_MERGED_PRS_FILE="$MOCK_MERGED_PRS_FILE" \
    MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" \
    MOCK_COMMENTS_FILE="$MOCK_COMMENTS_FILE" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    FEATURE_ISSUE="$FEATURE" \
    RUN_ID=1 \
    "$@" \
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

# --- 🌊 summary partitions Dispatched vs Skipped consistently, #-prefixed ---
if grep -q '🌊 \*\*Wave 1 of 2 dispatched: Wave 1\*\*' "$COMMENT_LOG" \
  && grep -q '\*\*Dispatched:\*\* #502' "$COMMENT_LOG" \
  && grep -q '\*\*Skipped (already done or in flight):\*\* #501 #503' "$COMMENT_LOG"; then
  pass "🌊 summary partitions Dispatched (#502) vs Skipped (#501, #503) consistently with the dispatch log"
else
  fail "🌊 summary did not match the expected partition: $(cat "$COMMENT_LOG")"
fi

# --- Single marker-anchored comment created (not the event-driven fallback) ---
COMMENTS_AFTER_RUN1=$(jq 'length' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENTS_AFTER_RUN1" -eq 1 ]]; then
  pass "run 1: exactly one persistent orchestration comment exists"
else
  fail "run 1: expected exactly 1 comment, found $COMMENTS_AFTER_RUN1: $(cat "$MOCK_COMMENTS_FILE")"
fi

COMMENT_ID_AFTER_RUN1=$(jq -r '.[0].id' "$MOCK_COMMENTS_FILE")
if jq -e --arg marker "<!-- autoducks:maestro-status:$FEATURE -->" \
  '.[0].body | contains($marker)' "$MOCK_COMMENTS_FILE" >/dev/null; then
  pass "the persistent comment carries the per-feature marker"
else
  fail "marker missing from the persistent comment: $(jq -r '.[0].body' "$MOCK_COMMENTS_FILE")"
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

if grep -q '\*\*Skipped (already done or in flight):\*\* #501 #502 #503' "$COMMENT_LOG"; then
  pass "run 2: all of Wave 1 (#501, #502, #503) now reports skipped/in-flight — guard and is_done converge"
else
  fail "run 2: expected all of Wave 1 skipped, comment log: $(tail -20 "$COMMENT_LOG")"
fi

# --- Single-comment convergence: run 2 must rediscover and EDIT run 1's
# comment (via its::list_comments + the marker), never post a second one. ---
COMMENTS_AFTER_RUN2=$(jq 'length' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENTS_AFTER_RUN2" -eq 1 ]]; then
  pass "run 2: still exactly one persistent orchestration comment — no growing stack"
else
  fail "run 2: expected exactly 1 comment, found $COMMENTS_AFTER_RUN2: $(cat "$MOCK_COMMENTS_FILE")"
fi

COMMENT_ID_AFTER_RUN2=$(jq -r '.[0].id' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENT_ID_AFTER_RUN2" == "$COMMENT_ID_AFTER_RUN1" ]]; then
  pass "run 2 edited the SAME comment (#$COMMENT_ID_AFTER_RUN1) run 1 created, not a new one"
else
  fail "comment id changed across runs (run1=$COMMENT_ID_AFTER_RUN1, run2=$COMMENT_ID_AFTER_RUN2) — a second comment was posted instead of edited"
fi

if grep -q "update comment #$COMMENT_ID_AFTER_RUN1" "$COMMENT_LOG"; then
  pass "run 2 went through the PATCH edit path (rediscovered via its::list_comments), not a fresh post"
else
  fail "run 2 did not PATCH the existing comment: $(cat "$COMMENT_LOG")"
fi

if jq -e '.[0].body | contains("Wave 1 of 2 dispatched")' "$MOCK_COMMENTS_FILE" >/dev/null \
  && jq -e '.[0].body | contains("#501 #502 #503")' "$MOCK_COMMENTS_FILE" >/dev/null; then
  pass "the single persistent comment reflects run 2's updated narration"
else
  fail "persistent comment body not updated as expected: $(jq -r '.[0].body' "$MOCK_COMMENTS_FILE")"
fi

# =============================================================================
# Human multi-wave transient status comment — must not linger on "Running…"
#
# Reproduces the ggondim review scenario: a human-triggered `/execute`
# (COMMENT_ID set) posts the bot-owned transient "Running…" status comment
# and dispatches wave 1 (a non-terminal report()). Pipeline completion then
# happens on a separate, event-driven runner (COMMENT_ID=0) that — on a real
# GHA runner — never shares the human run's /tmp id file. Asserts the
# transient comment is resolved by the human run itself rather than left
# stuck on "Running…" forever waiting for a terminal report() call that can
# never see it.
# =============================================================================
echo "── Human multi-wave /execute: transient status comment must not linger ──"

FEATURE=600
TASK_E=601
TASK_F=602

FEATURE_BODY_HUMAN=$(cat <<EOF
## Plan

\`\`\`yaml
waves:
  - name: Wave 1
    tasks: [$TASK_E, $TASK_F]
\`\`\`

## Progress

- [ ] #$TASK_E Task E \`P0\`
- [ ] #$TASK_F Task F \`P0\`
EOF
)

jq -n --arg body "$FEATURE_BODY_HUMAN" \
  '{title: "Add widget", body: $body, labels: ["Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE.json"

echo "[]" > "$MOCK_MERGED_PRS_FILE"
echo "[]" > "$MOCK_OPEN_PRS_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
: > "$DISPATCH_LOG"
: > "$COMMENT_LOG"

# --- Run A: human-triggered, dispatches wave 1 (non-terminal report) -------
RC_A=0
run_maestro COMMENT_ID=1 || RC_A=$?
[[ "$RC_A" -eq 0 ]] \
  && pass "human run: maestro exits 0" \
  || fail "human run: rc=$RC_A: $(tail -10 "$SCRATCH/stderr.log")"

[[ "$(count_of "issue_number=$TASK_E" "$DISPATCH_LOG")" -eq 1 && "$(count_of "issue_number=$TASK_F" "$DISPATCH_LOG")" -eq 1 ]] \
  && pass "human run: wave 1 (#$TASK_E, #$TASK_F) dispatched" \
  || fail "human run: expected both tasks dispatched, dispatch log: $(cat "$DISPATCH_LOG")"

MARKER="<!-- autoducks:maestro-status:$FEATURE -->"
COMMENTS_AFTER_HUMAN_RUN=$(jq 'length' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENTS_AFTER_HUMAN_RUN" -eq 2 ]]; then
  pass "human run: exactly two comments exist (transient status + persistent orchestration)"
else
  fail "human run: expected exactly 2 comments, found $COMMENTS_AFTER_HUMAN_RUN: $(cat "$MOCK_COMMENTS_FILE")"
fi

TRANSIENT_BODY=$(jq -r --arg marker "$MARKER" \
  '[.[] | select((.body // "") | contains($marker) | not)] | .[0].body // empty' "$MOCK_COMMENTS_FILE")
if [[ -n "$TRANSIENT_BODY" ]] && echo "$TRANSIENT_BODY" | grep -q '✅' && echo "$TRANSIENT_BODY" | grep -q 'finished working'; then
  pass "human run: transient status comment resolved to ✅ finished, not left at Running…"
else
  fail "human run: transient status comment not resolved: $TRANSIENT_BODY"
fi
if echo "$TRANSIENT_BODY" | grep -qi 'running on'; then
  fail "human run: transient status comment still shows the Running… headline"
else
  pass "human run: transient status comment no longer shows the Running… headline"
fi

# --- Run B: event-driven completion (COMMENT_ID=0), separate runner --------
# Both wave-1 tasks are now merged, so this run finds all waves complete —
# the terminal report() call the reviewer's scenario centers on.
jq -n --arg e "$TASK_E" --arg f "$TASK_F" \
  '[{number: 960, title: "Task E done", body: ("Implements task E.\n\nFixes #" + $e)},
    {number: 961, title: "Task F done", body: ("Implements task F.\n\nFixes #" + $f)}]' \
  > "$MOCK_MERGED_PRS_FILE"
echo "[]" > "$MOCK_OPEN_PRS_FILE"

RC_B=0
run_maestro || RC_B=$?
[[ "$RC_B" -eq 0 ]] \
  && pass "event-driven completion run: maestro exits 0" \
  || fail "event-driven completion run: rc=$RC_B: $(tail -10 "$SCRATCH/stderr.log")"

COMMENTS_AFTER_RUN_B=$(jq 'length' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENTS_AFTER_RUN_B" -eq 2 ]]; then
  pass "event-driven completion run: still exactly two comments — no new Running… comment posted"
else
  fail "event-driven completion run: expected exactly 2 comments, found $COMMENTS_AFTER_RUN_B: $(cat "$MOCK_COMMENTS_FILE")"
fi

TRANSIENT_BODY_AFTER_B=$(jq -r --arg marker "$MARKER" \
  '[.[] | select((.body // "") | contains($marker) | not)] | .[0].body // empty' "$MOCK_COMMENTS_FILE")
if echo "$TRANSIENT_BODY_AFTER_B" | grep -q '✅' && ! echo "$TRANSIENT_BODY_AFTER_B" | grep -qi 'running on'; then
  pass "event-driven completion run: transient comment remains resolved, never reverts to Running…"
else
  fail "event-driven completion run: transient comment regressed: $TRANSIENT_BODY_AFTER_B"
fi

PERSISTENT_BODY_AFTER_B=$(jq -r --arg marker "$MARKER" \
  '[.[] | select((.body // "") | contains($marker))] | .[0].body // empty' "$MOCK_COMMENTS_FILE")
if echo "$PERSISTENT_BODY_AFTER_B" | grep -q 'All waves complete'; then
  pass "event-driven completion run: persistent orchestration comment reflects final wave state"
else
  fail "event-driven completion run: persistent comment did not reflect completion: $PERSISTENT_BODY_AFTER_B"
fi

echo ""

# =============================================================================
# Human single-task /execute (M7) — transient status comment must not linger
# on the duplicate / no-dispatch branch.
#
# Reproduces AUDIT-PR-inconsistencies-2026-07-09.md finding M7: a single-task
# feature (no `waves:` block, IS_SINGLE=true) whose Developer task PR is
# already open but unmerged. FEATURE_DONE is derived from merged PRs only, so
# it is false; prevent_duplicate_dispatch then finds the open `fixes #<FEATURE>`
# PR and returns 1 (duplicate). Pre-fix, the inner `if` had no `else`, so
# report() never ran on this branch and the transient "Running…" comment
# lingered forever. Asserts the else added to run.sh resolves it to ✅.
# =============================================================================
echo "── Human single-task /execute: transient status comment must not linger (M7) ──"

FEATURE=700

FEATURE_BODY_SINGLE=$(cat <<EOF
## Plan

Single task — the Engineer collapsed the plan into the feature issue itself
(no sub-tasks, no \`waves:\` block).
EOF
)

jq -n --arg body "$FEATURE_BODY_SINGLE" \
  '{title: "Add widget", body: $body, labels: ["Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE.json"

echo "[]" > "$MOCK_MERGED_PRS_FILE"
jq -n --arg t "$FEATURE" \
  '[{number: 970, title: "Task PR in progress", headRefName: "feature/700-add-widget",
     body: ("Working on it.\n\nFixes #" + $t), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]' \
  > "$MOCK_OPEN_PRS_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
: > "$DISPATCH_LOG"
: > "$COMMENT_LOG"

# --- Mid-build run: task PR already open — the duplicate-guard / no-dispatch
# branch that pre-fix never called report() on. --------------------------
RC_MIDBUILD=0
run_maestro COMMENT_ID=1 || RC_MIDBUILD=$?
[[ "$RC_MIDBUILD" -eq 0 ]] \
  && pass "single-task mid-build run: maestro exits 0" \
  || fail "single-task mid-build run: rc=$RC_MIDBUILD: $(tail -10 "$SCRATCH/stderr.log")"

[[ "$(count_of "issue_number=$FEATURE" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "single-task mid-build run: Developer NOT dispatched — duplicate guard fired" \
  || fail "single-task mid-build run: Developer was dispatched despite an open task PR: $(cat "$DISPATCH_LOG")"

MARKER_SINGLE="<!-- autoducks:maestro-status:$FEATURE -->"
COMMENTS_AFTER_MIDBUILD=$(jq 'length' "$MOCK_COMMENTS_FILE")
if [[ "$COMMENTS_AFTER_MIDBUILD" -eq 2 ]]; then
  pass "single-task mid-build run: exactly two comments exist (transient status + persistent orchestration)"
else
  fail "single-task mid-build run: expected exactly 2 comments, found $COMMENTS_AFTER_MIDBUILD: $(cat "$MOCK_COMMENTS_FILE")"
fi

TRANSIENT_BODY_MIDBUILD=$(jq -r --arg marker "$MARKER_SINGLE" \
  '[.[] | select((.body // "") | contains($marker) | not)] | .[0].body // empty' "$MOCK_COMMENTS_FILE")
if [[ -n "$TRANSIENT_BODY_MIDBUILD" ]] && echo "$TRANSIENT_BODY_MIDBUILD" | grep -q '✅' && echo "$TRANSIENT_BODY_MIDBUILD" | grep -q 'finished working'; then
  pass "single-task mid-build run: transient status comment resolved to ✅ finished, not left at Running… (M7 fix)"
else
  fail "single-task mid-build run: transient status comment not resolved: $TRANSIENT_BODY_MIDBUILD"
fi
if echo "$TRANSIENT_BODY_MIDBUILD" | grep -qi 'running on'; then
  fail "single-task mid-build run: transient status comment still shows the Running… headline (M7 regression)"
else
  pass "single-task mid-build run: transient status comment no longer shows the Running… headline"
fi

# --- First-run companion: no open PR yet — the Developer IS dispatched and
# the transient comment still resolves to ✅. Locks in the un-gated happy
# path alongside the mid-build fix above. -------------------------------
FEATURE=701

jq -n --arg body "$FEATURE_BODY_SINGLE" \
  '{title: "Add gadget", body: $body, labels: ["Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE.json"

echo "[]" > "$MOCK_MERGED_PRS_FILE"
echo "[]" > "$MOCK_OPEN_PRS_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
: > "$DISPATCH_LOG"
: > "$COMMENT_LOG"

RC_FIRSTRUN=0
run_maestro COMMENT_ID=1 || RC_FIRSTRUN=$?
[[ "$RC_FIRSTRUN" -eq 0 ]] \
  && pass "single-task first run: maestro exits 0" \
  || fail "single-task first run: rc=$RC_FIRSTRUN: $(tail -10 "$SCRATCH/stderr.log")"

[[ "$(count_of "issue_number=$FEATURE" "$DISPATCH_LOG")" -eq 1 ]] \
  && pass "single-task first run: Developer dispatched — no open PR yet" \
  || fail "single-task first run: expected exactly one dispatch for #$FEATURE, dispatch log: $(cat "$DISPATCH_LOG")"

MARKER_FIRSTRUN="<!-- autoducks:maestro-status:$FEATURE -->"
TRANSIENT_BODY_FIRSTRUN=$(jq -r --arg marker "$MARKER_FIRSTRUN" \
  '[.[] | select((.body // "") | contains($marker) | not)] | .[0].body // empty' "$MOCK_COMMENTS_FILE")
if [[ -n "$TRANSIENT_BODY_FIRSTRUN" ]] && echo "$TRANSIENT_BODY_FIRSTRUN" | grep -q '✅' && ! echo "$TRANSIENT_BODY_FIRSTRUN" | grep -qi 'running on'; then
  pass "single-task first run: transient status comment resolved to ✅ finished (happy path unaffected)"
else
  fail "single-task first run: transient status comment not resolved: $TRANSIENT_BODY_FIRSTRUN"
fi

echo ""

# =============================================================================
# Closed-as-completed no-PR task (Fix 3 part 2) — a no-code task that never
# opens a sub-PR must still count as done once its issue is closed as
# genuinely COMPLETED, so its wave advances instead of re-dispatching it
# forever. A sibling task closed as NOT_PLANNED must NOT be masked as done.
#
#   Wave 1: task G (closed COMPLETED, no PR ever) — done, never (re-)dispatched
#   Wave 2: task H (closed NOT_PLANNED, no PR)    — NOT done, still dispatched
# =============================================================================
echo "── Maestro: closed-as-completed no-PR task counts as done, not_planned does not ──"

FEATURE=800
TASK_G=801   # Wave 1 — closed COMPLETED, no PR — must count as done
TASK_H=802   # Wave 2 — closed NOT_PLANNED, no PR — must NOT count as done

FEATURE_BODY_NOCODE=$(cat <<EOF
## Plan

\`\`\`yaml
waves:
  - name: Wave 1
    tasks: [$TASK_G]
  - name: Wave 2
    tasks: [$TASK_H]
\`\`\`

## Progress

- [ ] #$TASK_G Task G \`P0\`
- [ ] #$TASK_H Task H \`P0\`
EOF
)

jq -n --arg body "$FEATURE_BODY_NOCODE" \
  '{title: "No-code tasks", body: $body, labels: ["Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE.json"

jq -n '{state: "CLOSED", stateReason: "COMPLETED"}' > "$MOCK_ISSUE_DIR/$TASK_G.state.json"
jq -n '{state: "CLOSED", stateReason: "NOT_PLANNED"}' > "$MOCK_ISSUE_DIR/$TASK_H.state.json"

echo "[]" > "$MOCK_MERGED_PRS_FILE"
echo "[]" > "$MOCK_OPEN_PRS_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
: > "$DISPATCH_LOG"
: > "$COMMENT_LOG"

RC_NOCODE1=0
run_maestro || RC_NOCODE1=$?
[[ "$RC_NOCODE1" -eq 0 ]] \
  && pass "no-code run 1: maestro exits 0" \
  || fail "no-code run 1: rc=$RC_NOCODE1: $(tail -10 "$SCRATCH/stderr.log")"

grep -qx "\\[maestro\\] Done tasks: $TASK_G" "$SCRATCH/stderr.log" \
  && pass "DONE_TASKS contains the closed-completed no-PR task G (#$TASK_G), not the not_planned task H" \
  || fail "expected 'Done tasks: $TASK_G', log has: $(grep '\[maestro\] Done tasks' "$SCRATCH/stderr.log" || echo none)"

grep -qx "\\[maestro\\] Dispatching wave 1: Wave 2" "$SCRATCH/stderr.log" \
  && pass "Wave 1 (closed-completed G) reached done — Maestro advanced to Wave 2" \
  || fail "expected Wave 2 to be dispatched next, log has: $(grep '\[maestro\] Dispatching' "$SCRATCH/stderr.log" || echo none)"

[[ "$(count_of "issue_number=$TASK_G" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "no-code run 1: closed-completed task G (#$TASK_G) never dispatched" \
  || fail "G (#$TASK_G) was dispatched despite being closed-completed: $(cat "$DISPATCH_LOG")"

[[ "$(count_of "issue_number=$TASK_H" "$DISPATCH_LOG")" -eq 1 ]] \
  && pass "no-code run 1: not_planned task H (#$TASK_H) is NOT masked as done — still dispatched" \
  || fail "expected exactly one dispatch for #$TASK_H, dispatch log: $(cat "$DISPATCH_LOG")"

CAPTURED_BODY_NOCODE="$GH_CAPTURE_DIR/$FEATURE.md"
if [[ -f "$CAPTURED_BODY_NOCODE" ]] \
  && grep -q "^- \[x\] #$TASK_G " "$CAPTURED_BODY_NOCODE" \
  && grep -q "^- \[ \] #$TASK_H " "$CAPTURED_BODY_NOCODE"; then
  pass "feature checkboxes: only the closed-completed task #$TASK_G flipped to done"
else
  fail "feature checkboxes did not match the no-code fixture: $(cat "$CAPTURED_BODY_NOCODE" 2>/dev/null || echo 'no capture')"
fi

# --- Re-run: convergence — the closed-completed task is never re-dispatched ---
RC_NOCODE2=0
run_maestro || RC_NOCODE2=$?
[[ "$RC_NOCODE2" -eq 0 ]] \
  && pass "no-code run 2: maestro exits 0" \
  || fail "no-code run 2: rc=$RC_NOCODE2: $(tail -10 "$SCRATCH/stderr.log")"

[[ "$(count_of "issue_number=$TASK_G" "$DISPATCH_LOG")" -eq 0 ]] \
  && pass "no-code run 2: closed-completed task G (#$TASK_G) still never dispatched — no infinite re-dispatch" \
  || fail "G (#$TASK_G) was dispatched across the two runs despite being closed-completed: $(cat "$DISPATCH_LOG")"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ maestro-wave-state: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
