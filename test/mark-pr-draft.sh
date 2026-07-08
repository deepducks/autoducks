#!/usr/bin/env bash
# Unit tests for .autoducks/providers/git/github/mark-pr-draft.sh
# Run: bash test/mark-pr-draft.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK_PR_DRAFT_SH="$REPO_ROOT/.autoducks/providers/git/github/mark-pr-draft.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

new_test_dir() {
  local d="$SCRATCH/test-$1"
  mkdir -p "$d/bin"
  echo "$d"
}

# Run git::mark_pr_draft in a fresh subshell (so mark-pr-draft.sh's own
# `set -e` never leaks into this test script) with a stubbed `gh` on PATH.
# Records:
#   $LAST_STDOUT   — captured stdout
#   $LAST_STDERR   — captured stderr
#   $LAST_EXIT     — exit code
#   $LAST_GH_ARGS  — path to a file recording the args `gh` was invoked with
run_mark_pr_draft() {
  local dir="$1"; shift
  LAST_GH_ARGS="$dir/gh-args.txt"
  local out_file="$dir/stdout.txt"
  local err_file="$dir/stderr.txt"

  env -i PATH="$dir/bin:$PATH" \
      REPO="acme/repo" \
      bash -c 'source "$1"; git::mark_pr_draft "$2"' \
      _ "$MARK_PR_DRAFT_SH" "$@" \
      > "$out_file" 2> "$err_file"
  LAST_EXIT=$?
  LAST_STDOUT="$(cat "$out_file")"
  LAST_STDERR="$(cat "$err_file")"
}

# ---------------------------------------------------------------------------
# Test (a): happy path — invokes `gh pr ready N --repo "$REPO" --undo`.
# ---------------------------------------------------------------------------
echo "[a] invokes gh pr ready with --undo"
D=$(new_test_dir "a")
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$@" > "$(dirname "$0")/../gh-args.txt"
exit 0
GH
chmod +x "$D/bin/gh"
run_mark_pr_draft "$D" 99

if [[ "$LAST_EXIT" -eq 0 ]]; then pass "exit 0"; else fail "expected exit 0, got $LAST_EXIT (stderr: $LAST_STDERR)"; fi
if [[ -f "$LAST_GH_ARGS" ]]; then pass "gh was invoked"; else fail "gh was never invoked"; fi
GH_ARGS="$(cat "$LAST_GH_ARGS" 2>/dev/null || true)"
if [[ "$GH_ARGS" == "pr ready 99 --repo acme/repo --undo" ]]; then
  pass "invoked as: gh $GH_ARGS"
else
  fail "expected 'gh pr ready 99 --repo acme/repo --undo', got 'gh $GH_ARGS'"
fi

# ---------------------------------------------------------------------------
# Test (b): failure surfaces as non-zero exit.
# ---------------------------------------------------------------------------
echo "[b] gh failure propagates as non-zero exit"
D=$(new_test_dir "b")
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "error: pull request is already a draft" >&2
exit 1
GH
chmod +x "$D/bin/gh"
run_mark_pr_draft "$D" 7

if [[ "$LAST_EXIT" -ne 0 ]]; then pass "non-zero exit"; else fail "expected non-zero exit, got 0"; fi
if [[ "$LAST_STDERR" == *"already a draft"* ]]; then pass "original error surfaced on stderr"; else fail "expected error on stderr, got: $LAST_STDERR"; fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== mark-pr-draft.sh unit test summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
