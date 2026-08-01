#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/assert-changes.sh
#
# assert_changes is now base-relative: the "ahead of base" pass branch is
# gated on `git::commits_ahead <base> > 0` instead of "any prior commit
# exists on this branch" (which always false-passed on task branches, since
# they inherit the base's history).
#
# Run: bash test/unit-assert-changes.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Mock the git provider — parameterized by MOCK_COMMITS_AHEAD.
git::commits_ahead() {
  echo "$MOCK_COMMITS_AHEAD"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/robustness/assert-changes.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "test@example.com"
git -C "$SCRATCH" config user.name "Test"
echo "seed" > "$SCRATCH/README.md"
git -C "$SCRATCH" add README.md
git -C "$SCRATCH" commit -q -m "seed"

cd "$SCRATCH"

# reset_repo → back to a clean checkout of the seed commit, index and
# working tree both clear, before each scenario below.
reset_repo() {
  git reset -q --hard
  git clean -qfd
}

echo "── assert_changes <base> ──"

# 1. Staged diff → pass, regardless of commits_ahead.
reset_repo
echo "change" >> README.md
MOCK_COMMITS_AHEAD=0
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "staged diff → returns 0" || fail "staged diff → rc=$rc: $out"

# 2. Empty diff, commits_ahead > 0 → pass with warning.
reset_repo
MOCK_COMMITS_AHEAD=3
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "empty diff + ahead of base → returns 0"; else fail "empty diff + ahead of base → rc=$rc: $out"; fi
[[ "$out" == *"::warning::"* ]] && pass "empty diff + ahead of base → emits a warning" || fail "no warning emitted: $out"

# 3. Empty diff, commits_ahead == 0 → fail with error.
reset_repo
MOCK_COMMITS_AHEAD=0
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass "empty diff + not ahead of base → returns 1" || fail "empty diff + not ahead of base → rc=$rc: $out"
[[ "$out" == *"::error::"*"Agent made no changes"* ]] && pass "empty diff + not ahead of base → emits the no-changes error" || fail "no error emitted: $out"

# ── metarepo mode: the parent tree is the wrong place to look ──────────────
# All real code lives in submodules, and this check runs before
# metarepo::commit_task moves the children's HEADs, so the parent is
# legitimately clean while the agent has in fact changed a child (#182).
echo "── assert_changes in metarepo mode ──"

metarepo::enabled() { [[ "$MOCK_METAREPO" == "true" ]]; }
git::submodule_list_changed() { printf '%s' "$MOCK_CHANGED_SUBMODULES"; }

# 4. Empty parent diff, a child changed → pass, and say which child.
reset_repo
MOCK_COMMITS_AHEAD=0 MOCK_METAREPO=true MOCK_CHANGED_SUBMODULES="autoducks"
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "metarepo + changed submodule → returns 0" || fail "metarepo + changed submodule → rc=$rc: $out"
[[ "$out" == *"autoducks"* ]] && pass "names the changed submodule" || fail "does not name the submodule: $out"
[[ "$out" != *"made no changes"* ]] && pass "no longer claims the agent made no changes" || fail "still reports no-changes: $out"

# 5. Empty parent diff, no child changed → still the real error.
reset_repo
MOCK_COMMITS_AHEAD=0 MOCK_METAREPO=true MOCK_CHANGED_SUBMODULES=""
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass "metarepo + nothing changed anywhere → returns 1" || fail "metarepo + nothing changed → rc=$rc: $out"

# 6. Single-repo mode is untouched by the metarepo branch.
reset_repo
MOCK_COMMITS_AHEAD=0 MOCK_METAREPO=false MOCK_CHANGED_SUBMODULES="autoducks"
out=$(assert_changes "main" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass "single-repo mode ignores submodule state" || fail "single-repo mode changed behaviour → rc=$rc: $out"

# ---------------------------------------------------------------------------
echo ""
echo "═══ assert-changes: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
