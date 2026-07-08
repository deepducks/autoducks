#!/usr/bin/env bash
# Idempotency smoke test — asserts the re-run invariants the pipeline must
# never weaken:
#   1. Architect: the tactical zone re-emitted on the issue body is
#      byte-identical across runs, no matter what the design zone LLM writes.
#   2. Engineer: revising a plan that keeps the same task refs preserves the
#      same task issue numbers (no duplicate task issues get minted).
#   3. Developer: a task whose PR has already merged into the base branch
#      trips the duplicate-skip guard (`duplicate_skip=true`) every time it
#      is re-dispatched, not just once.
#
# Runs the real agent pre.sh/post.sh scripts as subprocesses with `gh`
# shimmed out (same technique as test/unit-engineer-dor.sh) — no network
# access and no mutation of the real repo.
#
# Run: bash test/unit-idempotency.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/tactical-zone.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
MOCK_ISSUE_DIR="$SCRATCH/issues"
GH_CAPTURE_DIR="$SCRATCH/captured"
mkdir -p "$MOCK_ISSUE_DIR" "$GH_CAPTURE_DIR"

# ── Shared gh shim ────────────────────────────────────────────────────
# Every agent script reaches the outside world only through its::*/git::*
# provider functions, which all bottom out in `gh`. Putting a fake `gh`
# first on PATH lets the real pre.sh/post.sh run unmodified against canned
# fixtures instead of hitting GitHub.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

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
    echo "https://github.com/x/y/issues/$3#issuecomment-777"
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
  "issue close") : ;;
  "label create") : ;;
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
  "api")
    method="GET"
    path=""
    prevflag=""
    for arg in "${@:2}"; do
      if [[ "$prevflag" == "--method" ]]; then
        method="$arg"; prevflag=""; continue
      fi
      case "$arg" in
        --method) prevflag="--method"; continue ;;
        --*)      continue ;;
        *)        [[ -z "$path" ]] && path="$arg" ;;
      esac
    done
    if [[ "$method" == "POST" && "$path" == repos/*/issues ]]; then
      # Simulate creating a brand-new task issue. With an all-integer-ref
      # plan this branch should never be reached — if a regression starts
      # minting new issues for preserved refs, this makes it visible
      # (the resulting task number won't match the fixture) instead of
      # silently swallowing it.
      counter_file="$SCRATCH/next_issue_num"
      n=$(cat "$counter_file" 2>/dev/null || echo 900)
      n=$((n + 1))
      echo "$n" > "$counter_file"
      echo "{\"number\": $n, \"id\": $((n + 900000))}"
    elif [[ "$path" == repos/*/issues/[0-9]* ]]; then
      num="${path##*/}"
      echo "{\"id\": $((num + 900000))}"
    elif [[ "$path" == *comments* ]]; then
      echo "[]"
    fi
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_step <script> [KEY=VAL ...]
# Runs an agent pre.sh/post.sh as a real subprocess (its own `set -e`, its
# own ERR trap) with the shim first on PATH. Prints stderr and returns the
# script's exit code so callers can assert on it.
run_step() {
  local script="$1"; shift
  local rc=0
  env "$@" \
    PATH="$SCRATCH/bin:$PATH" \
    GH_LOG="$GH_LOG" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    GH_CAPTURE_DIR="$GH_CAPTURE_DIR" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    bash "$script" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

# =============================================================================
# 1. Architect — tactical zone byte-identical across runs
# =============================================================================
echo "── Architect: tactical zone survives re-runs untouched ──"

ARCHITECT_PRE="$REPO_ROOT/.autoducks/agents/architect/pre.sh"
ARCHITECT_POST="$REPO_ROOT/.autoducks/agents/architect/post.sh"
FEATURE_A=55

DESIGN_ZONE_ORIG=$'## Problem Statement\n\nOriginal design content, pre-revision.\n'
TACTICAL_CONTENT=$'## Plan\n\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [201]\n```\n\n## Progress\n\n- [ ] #201 Do the thing `P0`\n'

printf '%s' "$DESIGN_ZONE_ORIG" > "$SCRATCH/a_design.md"
printf '%s' "$TACTICAL_CONTENT" > "$SCRATCH/a_tactical.md"
assemble_body "$SCRATCH/a_design.md" "$SCRATCH/a_tactical.md" "$SCRATCH/a_body.md"

jq -n --rawfile body "$SCRATCH/a_body.md" \
  '{title: "Add search", body: $body, labels: ["Design:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE_A.json"

run_architect_round() {
  # run_architect_round <fake_llm_design_text> <out_body_file>
  local llm_design="$1" out="$2"
  rm -f /tmp/autoducks-pre-failed /tmp/tactical-zone-preserved.flag /tmp/tactical-zone-preserved.md /tmp/design-spec.md

  run_step "$ARCHITECT_PRE" ISSUE_NUM="$FEATURE_A" RUN_ID=1 COMMENT_ID=1 COMMENTER=alice \
    || { fail "architect pre.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }

  printf '%s' "$llm_design" > /tmp/design-spec.md

  run_step "$ARCHITECT_POST" ISSUE_NUM="$FEATURE_A" RUN_ID=1 COMMENT_ID=1 COMMENTER=alice \
    || { fail "architect post.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }

  cp "$GH_CAPTURE_DIR/$FEATURE_A.md" "$out"
}

run_architect_round "## Problem Statement

Design attempt one — the LLM's first re-draft of the design zone." "$SCRATCH/a_round1.md"

run_architect_round "## Problem Statement

Design attempt two — a completely different re-draft, different wording,
different length, to prove the tactical zone doesn't move with it." "$SCRATCH/a_round2.md"

split_body "$SCRATCH/a_round1.md" "$SCRATCH/a_design1_out.md" "$SCRATCH/a_tactical1_out.md"
split_body "$SCRATCH/a_round2.md" "$SCRATCH/a_design2_out.md" "$SCRATCH/a_tactical2_out.md"

if diff -q "$SCRATCH/a_design1_out.md" "$SCRATCH/a_design2_out.md" > /dev/null 2>&1; then
  fail "test setup issue: design zones should differ between rounds but didn't"
else
  pass "sanity: design zone did change between rounds (LLM output varied)"
fi

if diff -q "$SCRATCH/a_tactical1_out.md" "$SCRATCH/a_tactical2_out.md" > /dev/null 2>&1; then
  pass "tactical zone is byte-identical across Architect re-runs"
else
  fail "tactical zone diverged across Architect re-runs:"
  diff "$SCRATCH/a_tactical1_out.md" "$SCRATCH/a_tactical2_out.md" || true
fi

if grep -q 'tasks: \[201\]' "$SCRATCH/a_tactical1_out.md" && grep -q 'tasks: \[201\]' "$SCRATCH/a_tactical2_out.md"; then
  pass "tactical zone plan content preserved (waves/tasks intact)"
else
  fail "tactical zone plan content lost"
fi

echo ""

# =============================================================================
# 2. Engineer — task numbers preserved across a revision re-run
# =============================================================================
echo "── Engineer: task numbers survive a revision re-run ──"

ENGINEER_PRE="$REPO_ROOT/.autoducks/agents/engineer/pre.sh"
ENGINEER_POST="$REPO_ROOT/.autoducks/agents/engineer/post.sh"
FEATURE_E=42

DESIGN_ZONE_E=$'## Problem Statement\n\nDo the thing, engineer edition.\n'
TACTICAL_E=$'## Plan\n\n```yaml\nwaves:\n  - name: Wave 1\n    tasks: [101, 102]\n```\n\n## Progress\n\n- [ ] #101 Task A `P0`\n- [ ] #102 Task B `P0`\n'

printf '%s' "$DESIGN_ZONE_E" > "$SCRATCH/e_design.md"
printf '%s' "$TACTICAL_E" > "$SCRATCH/e_tactical.md"
assemble_body "$SCRATCH/e_design.md" "$SCRATCH/e_tactical.md" "$SCRATCH/e_body.md"

jq -n --rawfile body "$SCRATCH/e_body.md" \
  '{title: "Add search", body: $body, labels: ["Design:done", "Tactics:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE_E.json"

run_engineer_round() {
  # run_engineer_round <task_a_summary> <task_b_summary>
  local summary_a="$1" summary_b="$2"
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated /tmp/tactical-body.md /tmp/tasks.jsonl /tmp/parse-error.md /tmp/link-outcomes.tsv

  local env_file="$SCRATCH/e_github_env"
  : > "$env_file"

  run_step "$ENGINEER_PRE" ISSUE_NUM="$FEATURE_E" RUN_ID=1 COMMENT_ID=1 COMMENTER=alice \
      COMMAND=engineer GITHUB_ENV="$env_file" \
    || { fail "engineer pre.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }

  local is_revision old_numbers
  is_revision=$(grep '^IS_REVISION=' "$env_file" | tail -1 | cut -d= -f2-)
  old_numbers=$(grep '^OLD_NUMBERS=' "$env_file" | tail -1 | cut -d= -f2-)

  [[ "$is_revision" == "true" ]] \
    && pass "engineer pre.sh detected revision mode" \
    || fail "expected IS_REVISION=true, got '$is_revision'"
  [[ "${old_numbers% }" == "101 102" ]] \
    && pass "engineer pre.sh recovered OLD_NUMBERS=101 102" \
    || fail "expected OLD_NUMBERS='101 102', got '$old_numbers'"

  cat > /tmp/tactical-body.md <<EOF
## Plan

\`\`\`yaml
waves:
  - name: Wave 1
    tasks: [101, 102]
\`\`\`

## Progress

- [ ] #101 Task A \`P0\`
- [ ] #102 Task B \`P0\`

## Tasks

### 101 — Task A

**Summary:** $summary_a

**Tasks:**
- [ ] step one

**Acceptance Criteria:**
- [ ] criterion one

### 102 — Task B

**Summary:** $summary_b

**Tasks:**
- [ ] step one

**Acceptance Criteria:**
- [ ] criterion one
EOF

  AUTODUCKS_SUB_ISSUES_STATUS=unavailable \
    run_step "$ENGINEER_POST" ISSUE_NUM="$FEATURE_E" RUN_ID=1 COMMENT_ID=1 COMMENTER=alice \
      COMMAND=engineer IS_REVISION="$is_revision" OLD_NUMBERS="$old_numbers" \
    || { fail "engineer post.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }
}

: > "$GH_LOG"
run_engineer_round "Do task A (first pass)." "Do task B (first pass)."
grep -q 'Tasks created: 101 102\.' "$GH_LOG" \
  && pass "round 1: task numbers reported as 101 102" \
  || fail "round 1: expected 'Tasks created: 101 102.' in status comment, log has: $(grep -o 'Tasks created:[^.]*\.' "$GH_LOG" || echo none)"

: > "$GH_LOG"
run_engineer_round "Do task A (second pass — reworded by a fresh LLM run)." "Do task B (second pass — reworded)."
grep -q 'Tasks created: 101 102\.' "$GH_LOG" \
  && pass "round 2: task numbers still reported as 101 102 (no duplicates minted)" \
  || fail "round 2: expected 'Tasks created: 101 102.' in status comment, log has: $(grep -o 'Tasks created:[^.]*\.' "$GH_LOG" || echo none)"

if grep -qE 'repos/[^ ]*/issues["'"'"']? --method POST' "$GH_LOG"; then
  fail "round 2: a new issue-create POST was logged — task numbers were not preserved"
else
  pass "round 2: no new task issue was created"
fi

echo ""

# =============================================================================
# 3. Developer — duplicate-skip guard fires on a task with a merged PR
# =============================================================================
echo "── Developer: duplicate-skip guard fires on re-dispatch ──"

DEVELOPER_PRE="$REPO_ROOT/.autoducks/agents/developer/pre.sh"
TASK_D=10
BASE_BRANCH_D="feature/99-widget"

MOCK_OPEN_PRS_FILE="$SCRATCH/d_open_prs.json"
MOCK_MERGED_PRS_FILE="$SCRATCH/d_merged_prs.json"
echo '[]' > "$MOCK_OPEN_PRS_FILE"
jq -n --arg body "Implements the widget thing.

Fixes #$TASK_D" \
  '[{number: 555, title: "Task 10 done", headRefName: "feature/99-widget/task/10-thing", body: $body}]' \
  > "$MOCK_MERGED_PRS_FILE"

run_developer_round() {
  local out_file="$1"
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated
  : > "$out_file"

  MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" MOCK_MERGED_PRS_FILE="$MOCK_MERGED_PRS_FILE" \
    run_step "$DEVELOPER_PRE" ISSUE_NUM="$TASK_D" RUN_ID=1 COMMENT_ID=1 COMMENTER=bob \
      BASE_BRANCH="$BASE_BRANCH_D" GITHUB_OUTPUT="$out_file"
}

D_RC1=0
run_developer_round "$SCRATCH/d_output_run1" || D_RC1=$?
[[ "$D_RC1" -eq 0 ]] \
  && pass "round 1: developer pre.sh exits 0" \
  || fail "round 1: rc=$D_RC1: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^duplicate_skip=true$' "$SCRATCH/d_output_run1" \
  && pass "round 1: duplicate_skip=true emitted for a task with a merged PR" \
  || fail "round 1: duplicate_skip=true missing, got: $(cat "$SCRATCH/d_output_run1")"

D_RC2=0
run_developer_round "$SCRATCH/d_output_run2" || D_RC2=$?
[[ "$D_RC2" -eq 0 ]] \
  && pass "round 2: developer pre.sh exits 0" \
  || fail "round 2: rc=$D_RC2: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^duplicate_skip=true$' "$SCRATCH/d_output_run2" \
  && pass "round 2: duplicate_skip=true still fires on re-dispatch" \
  || fail "round 2: duplicate-skip guard stopped firing, got: $(cat "$SCRATCH/d_output_run2")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ idempotency: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
