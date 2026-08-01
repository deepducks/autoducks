#!/usr/bin/env bash
# Unit tests for the metarepo gitlink pin contract (#119): delivery pins the
# child's default-branch tip, late reconciliation only fast-forwards, and a
# child delivery PR with no check runs gets its required check re-fired.
# Run: bash test/unit-metarepo-gitlink-pin.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export REPO="acme/meta"

# ── Fakes ────────────────────────────────────────────────────────────────
# submodule-deliver.sh and metarepo.sh only ever touch the outside world
# through `gh`, `git::resolve_token` and metarepo::slug_for_path, so the whole
# decision surface can be driven from files in $SCRATCH.
FAKE_TIP=""            # child default-branch tip
FAKE_COMPARE_STATUS=""  # .status returned by the compare API
FAKE_ROLLUP_COUNT=0     # entries in statusCheckRollup
RETRIGGER_LOG="$SCRATCH/retriggers"
: > "$RETRIGGER_LOG"

git::resolve_token() { printf 'tok'; }
metarepo::slug_for_path() { echo "acme/$1"; }
git::retrigger_child_check() { echo "$1 $2" >> "$RETRIGGER_LOG"; return 0; }

gh() {
  local args="$*"
  case "$args" in
    *"/commits/"*)      printf '%s' "$FAKE_TIP" ;;
    *"/compare/"*)      printf '%s' "$FAKE_COMPARE_STATUS" ;;
    *statusCheckRollup*) printf '%s' "$FAKE_ROLLUP_COUNT" ;;
    *)                   return 0 ;;
  esac
}

source "$REPO_ROOT/.autoducks/providers/git/github/submodule-deliver.sh"

echo "── git::_child_pin_after_merge: the pin is the default-branch tip ──"

# The bug: delivery returned the feature tip even when the merge produced a new
# commit on the child's default branch, so the parent pinned a SHA its base did
# not carry.
FAKE_TIP="ffffff1"
read -r pin repin <<< "$(git::_child_pin_after_merge acme/child main tok aaaaaa1)"
if [[ "$pin" == "ffffff1" && "$repin" == "1" ]]; then
  pass "merge commit on the child → pin the tip and request a re-pin"
else
  fail "merge commit on the child → expected 'ffffff1 1', got '$pin $repin'"
fi

# Fast-forward delivery: the tip IS the feature tip, so no re-pin is needed and
# the parent's existing gitlink is already correct.
FAKE_TIP="aaaaaa1"
read -r pin repin <<< "$(git::_child_pin_after_merge acme/child main tok aaaaaa1)"
if [[ "$pin" == "aaaaaa1" && "$repin" == "0" ]]; then
  pass "fast-forward delivery → pin unchanged, no re-pin"
else
  fail "fast-forward delivery → expected 'aaaaaa1 0', got '$pin $repin'"
fi

# Degraded API: never invent a pin — fall back to the old behaviour rather than
# emitting an empty gitlink.
FAKE_TIP=""
read -r pin repin <<< "$(git::_child_pin_after_merge acme/child main tok aaaaaa1)"
if [[ "$pin" == "aaaaaa1" && "$repin" == "0" ]]; then
  pass "unreadable tip → fall back to the feature tip, no re-pin"
else
  fail "unreadable tip → expected 'aaaaaa1 0', got '$pin $repin'"
fi

echo "── git::_child_has_checks / _child_assert_checks (#119c) ──"

FAKE_ROLLUP_COUNT=2
if git::_child_has_checks acme/child 7 tok; then
  pass "a PR with check runs reports as having checks"
else
  fail "a PR with check runs must report as having checks"
fi

FAKE_ROLLUP_COUNT=0
if git::_child_has_checks acme/child 7 tok; then
  fail "an empty rollup must NOT report as having checks"
else
  pass "an empty rollup reports as having no checks"
fi

# The happy path used to arm --auto and walk away. Now an empty rollup re-fires
# the required check via the draft→ready toggle.
: > "$RETRIGGER_LOG"
FAKE_ROLLUP_COUNT=0
AUTODUCKS_CHECK_ASSERT_ATTEMPTS=2 AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS=0 \
  git::_child_assert_checks acme/child 7 tok >/dev/null 2>&1 || true
if [[ "$(cat "$RETRIGGER_LOG")" == "7 acme/child" ]]; then
  pass "no checks after the assert window → re-trigger the child's required check"
else
  fail "no checks after the assert window → expected a re-trigger, got '$(cat "$RETRIGGER_LOG")'"
fi

: > "$RETRIGGER_LOG"
FAKE_ROLLUP_COUNT=1
AUTODUCKS_CHECK_ASSERT_ATTEMPTS=2 AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS=0 \
  git::_child_assert_checks acme/child 7 tok >/dev/null 2>&1 || true
if [[ -s "$RETRIGGER_LOG" ]]; then
  fail "checks already present → must NOT re-trigger, got '$(cat "$RETRIGGER_LOG")'"
else
  pass "checks already present → no re-trigger"
fi

echo "── check_recovery::action escalation (#119c) ──"

source "$REPO_ROOT/.autoducks/core/orchestration/check-recovery.sh"

check_action() { # label expected zero_rounds retriggered [recovery_rounds]
  local label="$1" expected="$2"; shift 2
  local got; got="$(check_recovery::action "$@")"
  [[ "$got" == "$expected" ]] && pass "$label" || fail "$label — expected '$expected', got '$got'"
}

# Grace window before doing anything: a check that simply has not appeared yet
# must not be mistaken for one that never will.
check_action "round 1, no re-trigger yet → wait"          wait      1 "" 2
check_action "round 2 hits the window → retrigger"        retrigger 2 "" 2
check_action "round 5 but never re-triggered → retrigger" retrigger 5 "" 2

# After the toggle, twice the window before giving up.
check_action "just re-triggered, round 2 → wait"          wait      2 1 2
check_action "re-triggered, round 5 → still wait"         wait      5 1 2
check_action "re-triggered, round 6 → fail"               fail      6 1 2
check_action "re-triggered, round 9 → fail"               fail      9 1 2

# The window is configurable, and never re-triggers twice.
check_action "recovery_rounds=1 → retrigger on round 1"   retrigger 1 "" 1
check_action "recovery_rounds=1, re-triggered, round 3"   fail      3 1 1
check_action "recovery_rounds=4 → wait at round 3"        wait      3 "" 4

# Garbage in must not become an accidental 'fail'.
check_action "non-numeric rounds → wait"                  wait      abc "" 2
check_action "zero/garbage window falls back to 2"        retrigger 2 "" abc

echo "── metarepo::pin_relation: only fast-forwards are safe ──"

# metarepo.sh needs a couple of helpers from the wider config surface; stub the
# ones it reaches for so it can be sourced standalone.
AUTODUCKS_METAREPO="true"
metarepo::enabled() { [[ "${AUTODUCKS_METAREPO:-false}" == "true" ]]; }
source "$REPO_ROOT/.autoducks/core/config/metarepo.sh"
# Re-stub anything metarepo.sh redefined.
metarepo::slug_for_path() { echo "acme/$1"; }
git::resolve_token() { printf 'tok'; }

got="$(metarepo::pin_relation acme/child abc123 abc123)"
[[ "$got" == "identical" ]] && pass "same SHA → identical (no API call needed)" \
  || fail "same SHA → expected identical, got '$got'"

FAKE_COMPARE_STATUS="behind"
got="$(metarepo::pin_relation acme/child abc123 def456)"
[[ "$got" == "behind" ]] && pass "pin is an ancestor of the tip → behind (safe to move)" \
  || fail "pin is an ancestor of the tip → expected behind, got '$got'"

FAKE_COMPARE_STATUS="ahead"
got="$(metarepo::pin_relation acme/child abc123 def456)"
[[ "$got" == "ahead" ]] && pass "pin is ahead of the tip → ahead (delivery not merged yet)" \
  || fail "pin is ahead of the tip → expected ahead, got '$got'"

FAKE_COMPARE_STATUS="diverged"
got="$(metarepo::pin_relation acme/child abc123 def456)"
[[ "$got" == "diverged" ]] && pass "rewritten history → diverged" \
  || fail "rewritten history → expected diverged, got '$got'"

FAKE_COMPARE_STATUS=""
got="$(metarepo::pin_relation acme/child abc123 def456)"
[[ "$got" == "unknown" ]] && pass "unreadable compare → unknown (never assumed safe)" \
  || fail "unreadable compare → expected unknown, got '$got'"

got="$(metarepo::pin_relation "" abc123 def456)"
[[ "$got" == "unknown" ]] && pass "missing slug → unknown" \
  || fail "missing slug → expected unknown, got '$got'"

echo "── metarepo::reconcile_gitlinks moves only 'behind' pins ──"

# Real git repos: a parent with one gitlink, and a bare origin to push to.
setup_parent() {
  local pinned="$1" root="$SCRATCH/rc.$RANDOM"
  mkdir -p "$root/origin" "$root/work"
  git init -q --bare "$root/origin"
  git init -q -b feature/1-x "$root/work"
  (
    cd "$root/work"
    git config user.email t@t; git config user.name t
    echo x > README.md; git add README.md
    git update-index --add --cacheinfo "160000,${pinned},child"
    git commit -qm init
    git remote add origin "$root/origin"
    git push -q origin HEAD:refs/heads/feature/1-x
  )
  printf '%s' "$root"
}

run_reconcile() { # root tip compare_status → prints the resulting gitlink
  local root="$1" tip="$2" status="$3"
  (
    cd "$root/work"
    FAKE_TIP="$tip"
    FAKE_COMPARE_STATUS="$status"
    export REPO="acme/meta"
    git::configure_identity() { git config user.email t@t; git config user.name t; }
    # No credential for the parent, so the function leaves the fixture's local
    # `origin` alone instead of rewriting it to a github.com URL. This also
    # exercises the no-token branch.
    git::resolve_token() { case "$1" in acme/meta) printf '' ;; *) printf 'tok' ;; esac; }
    metarepo::reconcile_gitlinks feature/1-x child >/dev/null 2>&1 || true
    git rev-parse "HEAD:child" 2>/dev/null || echo MISSING
  )
}

# Same, but returns the function's STDOUT (the "a reconcile was pushed" signal).
reconcile_stdout() { # root tip compare_status
  local root="$1" tip="$2" status="$3"
  (
    cd "$root/work"
    FAKE_TIP="$tip"
    FAKE_COMPARE_STATUS="$status"
    export REPO="acme/meta"
    git::configure_identity() { git config user.email t@t; git config user.name t; }
    git::resolve_token() { case "$1" in acme/meta) printf '' ;; *) printf 'tok' ;; esac; }
    metarepo::reconcile_gitlinks feature/1-x child 2>/dev/null || true
  )
}

PIN_OLD="1111111111111111111111111111111111111111"
PIN_NEW="2222222222222222222222222222222222222222"

root="$(setup_parent "$PIN_OLD")"
got="$(run_reconcile "$root" "$PIN_NEW" behind)"
[[ "$got" == "$PIN_NEW" ]] && pass "behind → gitlink fast-forwarded to the tip" \
  || fail "behind → expected $PIN_NEW, got $got"

# And the move must be pushed, not just committed locally — otherwise the PR
# GitHub merges still carries the stale pin.
pushed="$(git -C "$root/origin" rev-parse "refs/heads/feature/1-x:child" 2>/dev/null || echo MISSING)"
[[ "$pushed" == "$PIN_NEW" ]] && pass "behind → the reconcile commit is pushed to the PR head" \
  || fail "behind → expected origin to carry $PIN_NEW, got $pushed"

root="$(setup_parent "$PIN_OLD")"
got="$(run_reconcile "$root" "$PIN_NEW" ahead)"
[[ "$got" == "$PIN_OLD" ]] && pass "ahead → gitlink left alone (would regress the pin)" \
  || fail "ahead → expected $PIN_OLD, got $got"

root="$(setup_parent "$PIN_OLD")"
got="$(run_reconcile "$root" "$PIN_NEW" diverged)"
[[ "$got" == "$PIN_OLD" ]] && pass "diverged → gitlink left alone for a human" \
  || fail "diverged → expected $PIN_OLD, got $got"

root="$(setup_parent "$PIN_OLD")"
got="$(run_reconcile "$root" "" behind)"
[[ "$got" == "$PIN_OLD" ]] && pass "unreadable tip → gitlink left alone" \
  || fail "unreadable tip → expected $PIN_OLD, got $got"

root="$(setup_parent "$PIN_NEW")"
got="$(run_reconcile "$root" "$PIN_NEW" identical)"
[[ "$got" == "$PIN_NEW" ]] && pass "already at the tip → no-op" \
  || fail "already at the tip → expected $PIN_NEW, got $got"

# STDOUT contract: the poller anchors its check-run mirror on this, so "nothing
# moved" must be distinguishable from "the branch advanced for other reasons".
root="$(setup_parent "$PIN_OLD")"
got="$(reconcile_stdout "$root" "$PIN_NEW" behind)"
if [[ "$got" =~ ^[0-9a-f]{40}$ ]]; then
  pass "a pushed reconcile prints the new head SHA on stdout"
else
  fail "a pushed reconcile must print the new head SHA — got '$got'"
fi

root="$(setup_parent "$PIN_NEW")"
got="$(reconcile_stdout "$root" "$PIN_NEW" identical)"
if [[ -z "$got" ]]; then
  pass "a no-op reconcile prints nothing on stdout"
else
  fail "a no-op reconcile must print nothing — got '$got'"
fi

root="$(setup_parent "$PIN_OLD")"
got="$(reconcile_stdout "$root" "$PIN_NEW" ahead)"
if [[ -z "$got" ]]; then
  pass "a refused ('ahead') reconcile prints nothing on stdout"
else
  fail "a refused reconcile must print nothing — got '$got'"
fi

echo "── the delivery-check workflow wires the sibling re-pin ──"

for dir in ".autoducks/runtimes/github-actions" ".github/workflows"; do
  f="$REPO_ROOT/$dir/autoducks-delivery-check.yml"
  if grep -q "repin-siblings:" "$f"; then
    pass "$dir: repin-siblings job present"
  else
    fail "$dir: repin-siblings job missing"
  fi
  if grep -q "ready_for_review, closed\]" "$f"; then
    pass "$dir: pull_request closed is a trigger"
  else
    fail "$dir: pull_request closed is not a trigger"
  fi
  # The poller must not run on `closed` — it would start a check-run on a PR
  # that is already merged and poll it to the timeout.
  if grep -q "github.event.action != 'closed' &&" "$f"; then
    pass "$dir: the poller job is excluded on closed"
  else
    fail "$dir: the poller job is NOT excluded on closed"
  fi
  if [[ "$(grep -c "repin-open-parent-prs.sh" "$f")" -eq 2 ]]; then
    pass "$dir: both re-pin jobs run repin-open-parent-prs.sh"
  else
    fail "$dir: expected 2 repin-open-parent-prs.sh invocations, got $(grep -c "repin-open-parent-prs.sh" "$f")"
  fi
  # A direct push to the default branch fires no pull_request event, so without
  # its own trigger a hand-pushed gitlink bump strands every open parent PR.
  if grep -q "repin-on-base-push:" "$f"; then
    pass "$dir: repin-on-base-push job present"
  else
    fail "$dir: repin-on-base-push job missing"
  fi
  if grep -qE "^  push:$" "$f"; then
    pass "$dir: push is a trigger"
  else
    fail "$dir: push is not a trigger"
  fi
  if grep -q "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" "$f"; then
    pass "$dir: the push job is gated on the default branch"
  else
    fail "$dir: the push job is NOT gated on the default branch"
  fi
  # Every job must state which event it belongs to, so a push event cannot fall
  # through to the poller (which would start a check-run with no PR to gate).
  # Three such jobs now: repin-siblings, cleanup-child-branches (#182), and the
  # poller's own pull_request path.
  _guards="$(grep -c "github.event_name == 'pull_request' &&" "$f")"
  if [[ "$_guards" -eq 3 ]]; then
    pass "$dir: all three pull_request jobs assert the event name"
  else
    fail "$dir: expected 3 event_name guards, got $_guards"
  fi
done

echo ""
echo "═══ metarepo-gitlink-pin: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
