#!/usr/bin/env bash
# Regression tests for #176 — arming auto-merge must not delete the head branch,
# and must not happen on undetermined mergeability.
# Run: bash test/unit-submodule-deliver-auto-merge.sh
#
# What happened: `gh pr merge --merge --auto --delete-branch` armed auto-merge and
# deleted the branch in the same call. `--auto` defers the merge until required
# checks pass; `--delete-branch` does not wait. GitHub closes a PR whose head
# branch disappears, so on PR #1140 the sequence auto_merge_enabled → closed,
# auto_merge_disabled, head_ref_deleted took three seconds, nothing merged, and
# the resolver dispatched afterwards died at `actions/checkout`.
#
# It misdiagnoses badly — the symptom reads as "the resolver could not resolve the
# conflicts", when the resolver never evaluated one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELIVER="$REPO_ROOT/.autoducks/providers/git/github/submodule-deliver.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export REPO="acme/meta"

# ---------------------------------------------------------------------------
echo "── the asynchronous merge never deletes the branch ──"

# Strip comments first: the fix documents the old call verbatim.
CODE="$SCRATCH/deliver.stripped"
sed 's/^[[:space:]]*#.*$//' "$DELIVER" > "$CODE"

if grep -q -- '--auto' "$CODE"; then
  pass "there is still an --auto call to guard"
else
  fail "no --auto call found — this test has lost its subject"
fi

if grep -- '--auto' "$CODE" | grep -q -- '--delete-branch'; then
  fail "an --auto merge still carries --delete-branch — this is #176"
else
  pass "no --auto merge carries --delete-branch"
fi

# The synchronous merges SHOULD delete: by the time gh returns, the merge is done.
sync_deletes=$(grep -- 'gh pr merge' "$CODE" | grep -v -- '--auto' | grep -c -- '--delete-branch' || true)
if [[ "$sync_deletes" -ge 1 ]]; then
  pass "synchronous merges still delete the branch ($sync_deletes)"
else
  fail "the synchronous merges stopped deleting the branch — that is a different regression"
fi

# ---------------------------------------------------------------------------
echo "── auto-merge is armed only on a definitive MERGEABLE ──"

if grep -q '"\$mergeable" != "MERGEABLE"' "$CODE"; then
  pass "the guard refuses anything that is not MERGEABLE"
else
  fail "the guard no longer keys on MERGEABLE — an UNKNOWN PR can be armed again"
fi

# The old shape, which let UNKNOWN/UNKNOWN through.
if grep -q 'mergeable" == "UNKNOWN" && .*BEHIND' "$CODE"; then
  fail "the old UNKNOWN-only-if-BEHIND guard is back"
else
  pass "the old UNKNOWN-only-if-BEHIND guard is gone"
fi

# ---------------------------------------------------------------------------
echo "── why that matters: the poll gives up on UNKNOWN ──"

# Fakes. submodule-deliver only reaches the outside world through `gh` and
# git::resolve_token, so the whole decision surface is drivable from here.
git::resolve_token() { printf 'tok'; }
metarepo::slug_for_path() { echo "acme/$1"; }

FAKE_MERGEABLE="UNKNOWN"
FAKE_STATE="UNKNOWN"
# The poll runs inside a command substitution, so a shell variable counter would
# be incremented in a subshell and never seen here. Count through a file.
GH_LOG="$SCRATCH/gh-calls"
gh() {
  case "$*" in
    *mergeable*)
      echo x >> "$GH_LOG"
      printf '{"mergeable":"%s","mergeStateStatus":"%s"}' "$FAKE_MERGEABLE" "$FAKE_STATE" ;;
    *) return 0 ;;
  esac
}
gh_calls() { wc -l < "$GH_LOG" 2>/dev/null | tr -d ' '; }
# shellcheck source=/dev/null
source "$DELIVER"

# Budget of 2 attempts with no sleep, so the test does not wait 30 seconds.
FAKE_MERGEABLE="UNKNOWN"; FAKE_STATE="UNKNOWN"; : > "$GH_LOG"
out="$(git::_child_wait_for_mergeable acme/child 7 tok 2 0 2>/dev/null)"
if [[ "$out" == "UNKNOWN UNKNOWN" ]]; then
  pass "an exhausted poll returns UNKNOWN — the state the guard must refuse"
else
  fail "exhausted poll returned '$out', expected 'UNKNOWN UNKNOWN'"
fi
if [[ "$(gh_calls)" -eq 2 ]]; then
  pass "it spends its whole budget before giving up ($(gh_calls) attempts)"
else
  fail "polled $(gh_calls) times, expected 2"
fi

FAKE_MERGEABLE="CONFLICTING"; FAKE_STATE="DIRTY"; : > "$GH_LOG"
out="$(git::_child_wait_for_mergeable acme/child 7 tok 5 0 2>/dev/null)"
if [[ "$out" == "CONFLICTING DIRTY" && "$(gh_calls)" -eq 1 ]]; then
  pass "a definitive CONFLICTING returns immediately"
else
  fail "CONFLICTING returned '$out' after $(gh_calls) call(s)"
fi

FAKE_MERGEABLE="MERGEABLE"; FAKE_STATE="CLEAN"; : > "$GH_LOG"
out="$(git::_child_wait_for_mergeable acme/child 7 tok 5 0 2>/dev/null)"
if [[ "$out" == "MERGEABLE CLEAN" && "$(gh_calls)" -eq 1 ]]; then
  pass "a definitive MERGEABLE returns immediately"
else
  fail "MERGEABLE returned '$out' after $(gh_calls) call(s)"
fi

# The combination the bug needed: UNKNOWN without BEHIND. Under the old guard
# this was "safe to arm"; it is the state a freshly-created PR reports.
FAKE_MERGEABLE="UNKNOWN"; FAKE_STATE="UNKNOWN"
read -r m s <<< "$(git::_child_wait_for_mergeable acme/child 7 tok 1 0 2>/dev/null)"
if [[ "$m" != "MERGEABLE" ]]; then
  pass "UNKNOWN/UNKNOWN is not MERGEABLE, so the new guard stops it"
else
  fail "UNKNOWN/UNKNOWN read as MERGEABLE"
fi

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
