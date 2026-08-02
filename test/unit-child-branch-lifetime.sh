#!/usr/bin/env bash
# Unit tests for the child feature branch's lifetime in metarepo mode (#182).
#
# The parent's pipeline creates the mirrored child branch, so the parent owns
# when it dies: the parent PR closing, not the child PR merging. Delivery used
# to delete it at child-merge time, which retires it while the parent PR is
# still open and its review loop can still dispatch rework rounds — those rounds
# then had nowhere to commit and fell through to the child's default branch.
#
# Four things have to hold:
#   1. no delivery path deletes the child branch as a side effect of merging;
#   2. the parent-PR-close hook deletes it, but only when it is already
#      contained in the child's default branch (= delivered, nothing to lose);
#   3. that hook refuses outright to delete a child's default branch;
#   4. the push guard refuses to commit task work onto a child's default branch,
#      whatever the branch resolution upstream produced.
# Run: bash test/unit-child-branch-lifetime.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── 1. No delivery path deletes the branch it just merged ─────────────────
echo "── delivery does not retire the child branch ──"

for f in .autoducks/providers/git/github/submodule-deliver.sh \
         .autoducks/agents/maestro/run.sh \
         .autoducks/core/config/metarepo.sh; do
  if grep -n -e "--delete-branch" "$REPO_ROOT/$f" | grep -qv '^\s*[0-9]*:\s*#'; then
    fail "$f still passes --delete-branch on a merge"
  else
    pass "$(basename "$f"): no live --delete-branch"
  fi
done

# repin_gitlinks used to DELETE the child refs right after a successful re-pin.
if grep -q 'refs/heads/\${feature_branch}" -X DELETE' "$REPO_ROOT/.autoducks/core/config/metarepo.sh"; then
  fail "repin_gitlinks still deletes child branches after re-pinning"
else
  pass "repin_gitlinks no longer deletes child branches"
fi

# ── 2/3. The cleanup hook's delete/keep decision ──────────────────────────
echo "── cleanup-child-branches: deletes only what is already delivered ──"

DELETED=$(mktemp)
LOG=$(mktemp)
trap 'rm -f "$DELETED" "$LOG"' EXIT

# Mocks. metarepo::pin_relation is the real contract: it answers where the
# branch tip sits relative to the child's default tip.
metarepo::submodule_paths() { printf '%s\n' "childrepo"; }
metarepo::slug_for_path() { printf '%s\n' "acme/childrepo"; }
metarepo::child_default_branch() { printf '%s\n' "$MOCK_DEFAULT"; }
metarepo::pin_relation() { printf '%s\n' "$MOCK_RELATION"; }
git::resolve_token() { printf '%s\n' "tok"; }
gh() {
  # Only the ref reads and the DELETE matter here.
  local args="$*"
  case "$args" in
    *"-X DELETE"*) echo "$args" >> "$DELETED"; return 0 ;;
    *"git/ref/heads/"*) printf '%s\n' "deadbeef"; return 0 ;;
  esac
  return 0
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/cleanup-child-branches.sh"

run_cleanup() { : > "$DELETED"; cleanup_child_branches "$1" 2>"$LOG"; }

# Delivered: branch tip is contained in the child's default branch.
MOCK_DEFAULT="main" MOCK_RELATION="behind"
run_cleanup "feature/82-custom-agents"
if [[ -s "$DELETED" ]]; then
  pass "delivered child branch (behind default) → deleted"
else
  fail "delivered child branch was not deleted: $(cat "$LOG")"
fi

MOCK_DEFAULT="main" MOCK_RELATION="identical"
run_cleanup "feature/82-custom-agents"
[[ -s "$DELETED" ]] && pass "identical to default → deleted" || fail "identical branch not deleted"

# NOT delivered: the branch holds commits the child's default does not have.
# This is the case that must never be deleted — it is where work is lost.
MOCK_DEFAULT="main" MOCK_RELATION="ahead"
run_cleanup "feature/82-custom-agents"
if [[ -s "$DELETED" ]]; then
  fail "undelivered child branch (ahead of default) was DELETED — that loses the work"
else
  pass "undelivered child branch (ahead) → kept"
fi
grep -q "never delivered" "$LOG" && pass "keeping an undelivered branch is reported" || fail "kept silently: $(cat "$LOG")"

MOCK_DEFAULT="main" MOCK_RELATION="diverged"
run_cleanup "feature/82-custom-agents"
[[ -s "$DELETED" ]] && fail "diverged child branch was deleted" || pass "diverged child branch → kept"

MOCK_DEFAULT="main" MOCK_RELATION="unknown"
run_cleanup "feature/82-custom-agents"
[[ -s "$DELETED" ]] && fail "unknown relation was treated as safe to delete" || pass "unknown relation → kept"

# The default branch is never a pipeline branch, so it is never deletable —
# even if a caller hands its name in.
MOCK_DEFAULT="main" MOCK_RELATION="behind"
run_cleanup "main"
if [[ -s "$DELETED" ]]; then
  fail "cleanup deleted the child's DEFAULT branch"
else
  pass "refuses to delete the child's default branch"
fi
grep -q "refusing to delete" "$LOG" && pass "refusal is reported" || fail "refused silently: $(cat "$LOG")"

# ── 4. The push guard ─────────────────────────────────────────────────────
echo "── commit_push_recursive refuses the child's default branch ──"

PUSHED=$(mktemp)
trap 'rm -f "$DELETED" "$LOG" "$PUSHED"' EXIT

git::submodule_list_changed() { printf '%s\n' "childrepo"; }
git::submodule_remote() { :; }
git::configure_identity() { :; }
git() {
  case "$*" in
    *push*) echo "$*" >> "$PUSHED"; return 0 ;;
    *"diff --cached --quiet"*) return 1 ;;   # there are changes to commit
    *) return 0 ;;
  esac
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/git/github/commit-push-recursive.sh"

: > "$PUSHED"
MOCK_DEFAULT="main"
out=$(cd /tmp && mkdir -p childrepo && git::commit_push_recursive "main" "msg" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "child_branch == child default → returns non-zero"
else
  fail "pushed to the child's default branch instead of refusing"
fi
[[ ! -s "$PUSHED" ]] && pass "no push was attempted" || fail "the guard returned non-zero but the push still happened: $(cat "$PUSHED")"
[[ "$out" == *"refusing to push"* ]] && pass "explains why it refused" || fail "no explanation: $out"

: > "$PUSHED"
out=$(cd /tmp && git::commit_push_recursive "feature/82-custom-agents" "msg" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "feature/82-custom-agents" "$PUSHED"; then
  pass "a real feature branch still pushes normally"
else
  fail "guard blocked a legitimate feature branch → rc=$rc: $out"
fi

echo ""
echo "═══ child-branch-lifetime: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
