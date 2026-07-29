#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/fold-duplicate.sh —
# fold_duplicate::close is the shared "fold DUP into CANONICAL" action
# used by both merge.sh (/merge) and post.sh (triage dedup). Asserts the
# label-create → its::add_label → its::close_issue (not_planned) →
# its::link_sub_issue ordering, and that a re-run on an already-closed
# duplicate is a safe no-op. Driven with mocked gh/its::* calls — same
# style as test/unit-rework-labels.sh.
# Run: bash test/unit-fold-duplicate.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

LOG=$(mktemp)
reset() { : > "$LOG"; }

# Mocks — gh (label create), its::add_label / its::close_issue /
# its::link_sub_issue. All calls are appended to one log, in call order,
# for sequence assertions.
gh() { echo "GH:$*" >> "$LOG"; }
its::add_label()    { echo "ADD:$1|$2" >> "$LOG"; }
its::close_issue()  { echo "CLOSE:$1|$2|$3" >> "$LOG"; }
its::link_sub_issue() { echo "LINK:$1|$2" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="merge"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/fold-duplicate.sh"

echo "── fold_duplicate::close: ordered sequence ──"
reset
label::_invalidate
fold_duplicate::close "42" "7"

# label::ensure adds one `gh label list` cache-fill call ahead of the
# create, since it needs to check for a case-variant before creating.
if [[ "$(wc -l < "$LOG")" -eq 5 ]]; then
  pass "exactly 5 calls made"
else
  fail "expected 5 calls, got: $(cat "$LOG")"
fi

mapfile -t LINES < "$LOG"
if [[ "${LINES[0]}" == GH:label\ list* ]]; then
  pass "step 1: gh label list (label::ensure cache fill)"
else
  fail "step 1 not gh label list: ${LINES[0]:-<missing>}"
fi
if [[ "${LINES[1]}" == GH:label\ create\ Duplicate* ]]; then
  pass "step 2: gh label create Duplicate"
else
  fail "step 2 not gh label create: ${LINES[1]:-<missing>}"
fi
if [[ "${LINES[2]}" == "ADD:42|Duplicate" ]]; then
  pass "step 3: its::add_label DUP Duplicate"
else
  fail "step 3 not its::add_label: ${LINES[2]:-<missing>}"
fi
if [[ "${LINES[3]}" == "CLOSE:42|Duplicate of #7.|not_planned" ]]; then
  pass "step 4: its::close_issue DUP ... not_planned"
else
  fail "step 4 not its::close_issue not_planned: ${LINES[3]:-<missing>}"
fi
if [[ "${LINES[4]}" == "LINK:42|7" ]]; then
  pass "step 5: its::link_sub_issue DUP CANONICAL"
else
  fail "step 5 not its::link_sub_issue: ${LINES[4]:-<missing>}"
fi

echo "── fold_duplicate::close: idempotent no-op when every step fails (already closed) ──"
reset
label::_invalidate
gh() { echo "GH:$*" >> "$LOG"; return 1; }
its::add_label()    { echo "ADD:$1|$2" >> "$LOG"; return 1; }
its::close_issue()  { echo "CLOSE:$1|$2|$3" >> "$LOG"; return 1; }
its::link_sub_issue() { echo "LINK:$1|$2" >> "$LOG"; return 1; }

if fold_duplicate::close "42" "7"; then
  pass "fold_duplicate::close succeeds even when every downstream call fails"
else
  fail "fold_duplicate::close propagated a failure from a downstream call"
fi
if [[ "$(wc -l < "$LOG")" -eq 5 ]]; then
  pass "all 5 steps (list, create, add, close, link) still attempted despite failures"
else
  fail "not all steps attempted: $(cat "$LOG")"
fi

# Restore non-failing mocks for a second, back-to-back re-run.
gh() { echo "GH:$*" >> "$LOG"; }
its::add_label()    { echo "ADD:$1|$2" >> "$LOG"; }
its::close_issue()  { echo "CLOSE:$1|$2|$3" >> "$LOG"; }
its::link_sub_issue() { echo "LINK:$1|$2" >> "$LOG"; }

echo "── fold_duplicate::close: safe to re-run back-to-back (idempotent) ──"
reset
label::_invalidate
fold_duplicate::close "42" "7"
fold_duplicate::close "42" "7"
# First call: list + create + add + close + link (5). Second call: the
# label is now cached under its exact casing, so label::ensure short-circuits
# with no gh call at all — add + close + link only (3). 5 + 3 = 8.
if [[ "$(wc -l < "$LOG")" -eq 8 ]]; then
  pass "second re-run reuses the cached label (no repeat gh label list/create) without erroring"
else
  fail "re-run did not repeat cleanly: $(cat "$LOG")"
fi

rm -f "$LOG"

echo ""
echo "═══ fold-duplicate: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
