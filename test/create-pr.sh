#!/usr/bin/env bash
# Unit tests for .autoducks/providers/git/github/create-pr.sh
# Run: bash test/create-pr.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE_PR_SH="$REPO_ROOT/.autoducks/providers/git/github/create-pr.sh"

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

# Run git::create_pr in a fresh subshell (so create-pr.sh's own `set -e`
# never leaks into this test script) with a stubbed `gh` on PATH.
# Records:
#   $LAST_STDOUT  — captured stdout (the PR number on success)
#   $LAST_STDERR  — captured stderr
#   $LAST_EXIT    — exit code
#   $LAST_SUMMARY — path to the fake $GITHUB_STEP_SUMMARY
run_create_pr() {
  local dir="$1"; shift
  LAST_SUMMARY="$dir/summary.md"
  : > "$LAST_SUMMARY"
  local out_file="$dir/stdout.txt"
  local err_file="$dir/stderr.txt"

  env -i PATH="$dir/bin:$PATH" \
      REPO="acme/repo" \
      GITHUB_STEP_SUMMARY="$LAST_SUMMARY" \
      bash -c 'source "$1"; git::create_pr "$2" "$3" "$4" "$5" "$6"' \
      _ "$CREATE_PR_SH" "$@" \
      > "$out_file" 2> "$err_file"
  LAST_EXIT=$?
  LAST_STDOUT="$(cat "$out_file")"
  LAST_STDERR="$(cat "$err_file")"
}

# ---------------------------------------------------------------------------
# Test (a): scope-error recovery — gh pr create prints a /pull/357 URL then
# exits non-zero with the read:org GraphQL error text.
# ---------------------------------------------------------------------------
echo "[a] read:org scope error recovers the PR number"
D=$(new_test_dir "a")
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create")
    echo "https://github.com/acme/repo/pull/357"
    echo "GraphQL: Resource not accessible by integration (missing the read:org scope)" >&2
    exit 1
    ;;
  "pr list")
    # Recovery must come from the URL in the create output, not this call.
    exit 0
    ;;
esac
GH
chmod +x "$D/bin/gh"
run_create_pr "$D" feature-branch main "My PR" "body" false

if [[ "$LAST_EXIT" -eq 0 ]]; then pass "exit 0"; else fail "expected exit 0, got $LAST_EXIT (stderr: $LAST_STDERR)"; fi
if [[ "$LAST_STDOUT" == "357" ]]; then pass "prints recovered PR number 357"; else fail "expected stdout '357', got '$LAST_STDOUT'"; fi
if grep -q '::warning::' "$D/stderr.txt"; then pass "warning trace on stderr"; else fail "missing ::warning:: trace on stderr"; fi
if [[ -s "$LAST_SUMMARY" ]]; then pass "GITHUB_STEP_SUMMARY entry written"; else fail "GITHUB_STEP_SUMMARY was not appended to"; fi

# ---------------------------------------------------------------------------
# Test (b): happy path — URL on stdout, exit 0.
# ---------------------------------------------------------------------------
echo "[b] happy path returns PR number, no warning"
D=$(new_test_dir "b")
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create")
    echo "https://github.com/acme/repo/pull/42"
    exit 0
    ;;
esac
GH
chmod +x "$D/bin/gh"
run_create_pr "$D" feature-branch main "My PR" "body" false

if [[ "$LAST_EXIT" -eq 0 ]]; then pass "exit 0"; else fail "expected exit 0, got $LAST_EXIT (stderr: $LAST_STDERR)"; fi
if [[ "$LAST_STDOUT" == "42" ]]; then pass "prints PR number 42"; else fail "expected stdout '42', got '$LAST_STDOUT'"; fi
if [[ -z "$LAST_STDERR" ]]; then pass "no warning on stderr"; else fail "unexpected stderr: $LAST_STDERR"; fi
if [[ ! -s "$LAST_SUMMARY" ]]; then pass "GITHUB_STEP_SUMMARY untouched"; else fail "GITHUB_STEP_SUMMARY unexpectedly written: $(cat "$LAST_SUMMARY")"; fi

# ---------------------------------------------------------------------------
# Test (c): genuine failure — unrelated error, no recoverable PR.
# ---------------------------------------------------------------------------
echo "[c] unrelated failure with no recoverable PR exits non-zero"
D=$(new_test_dir "c")
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create")
    echo "error: unexpected server error" >&2
    exit 1
    ;;
  "pr list")
    # No open PR to recover.
    exit 0
    ;;
esac
GH
chmod +x "$D/bin/gh"
run_create_pr "$D" feature-branch main "My PR" "body" false

if [[ "$LAST_EXIT" -ne 0 ]]; then pass "non-zero exit"; else fail "expected non-zero exit, got 0 (stdout: $LAST_STDOUT)"; fi
if [[ "$LAST_STDERR" == *"unexpected server error"* ]]; then pass "original error surfaced on stderr"; else fail "expected error on stderr, got: $LAST_STDERR"; fi
if [[ -z "$LAST_STDOUT" ]]; then pass "no PR number printed"; else fail "unexpected stdout: $LAST_STDOUT"; fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== create-pr.sh unit test summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
