#!/usr/bin/env bash
# Provider-contract test for .autoducks/providers/its/github/get-parent.sh
#
# its::get_parent(issue_id) exists because `GET /repos/{o}/{r}/issues/{n}` has
# no `parent` field. The old inline lookup read `.parent.number` off that REST
# payload, got empty unconditionally, and every comment-triggered task run
# concluded the task was an orphan and refused — with the failure wearing the
# same message as a genuine orphan.
#
# The contract that fixes it is carried by the exit code, so this test pins all
# three states apart:
#   parent exists   → stdout = number, exit 0
#   no parent       → stdout empty,    exit 0
#   query failed    → stdout empty,    exit 1
#
# It also guards the regression directly: no call site under .autoducks/ may go
# back to reading `.parent.number` off the REST issue payload.
#
# Run: bash test/unit-its-get-parent.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

export REPO="acme/widgets"

# ── gh stub ──────────────────────────────────────────────────────────────
# its::get_parent shells out to `gh api graphql …`. GH_MODE selects which of
# the three real-world outcomes the stub reproduces. The stub also records the
# argv so the test can assert the query never goes to the REST issue endpoint.
ARGV_FILE="$(mktemp)"
trap 'rm -f "$ARGV_FILE"' EXIT

gh() {
  printf '%s\n' "$@" > "$ARGV_FILE"
  case "${GH_MODE:-parent}" in
    parent)   echo "118" ;;                 # --jq resolved parent.number
    orphan)   printf '' ;;                  # parent is null → `// empty`
    failure)  return 1 ;;                   # network / auth / API shape
  esac
}
export -f gh

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/its/github/get-parent.sh"

# ── 1. parent exists ─────────────────────────────────────────────────────
GH_MODE=parent
if out="$(its::get_parent 125)"; then rc=0; else rc=$?; fi
[[ "$out" == "118" && "$rc" -eq 0 ]] \
  && pass "parent exists → stdout '118', exit 0" \
  || fail "parent exists → got stdout '$out', exit $rc"

# ── 2. genuine orphan ────────────────────────────────────────────────────
GH_MODE=orphan
if out="$(its::get_parent 118)"; then rc=0; else rc=$?; fi
[[ -z "$out" && "$rc" -eq 0 ]] \
  && pass "no parent → empty stdout, exit 0 (not an error)" \
  || fail "no parent → got stdout '$out', exit $rc"

# ── 3. query failure is NOT an orphan ────────────────────────────────────
# The whole point: a failed query must be distinguishable, or the caller
# reports "this issue has no parent" when it simply could not ask.
GH_MODE=failure
if out="$(its::get_parent 125)"; then rc=0; else rc=$?; fi
[[ -z "$out" && "$rc" -ne 0 ]] \
  && pass "query failure → empty stdout, non-zero exit" \
  || fail "query failure → got stdout '$out', exit $rc (must be non-zero)"

# ── 4. it asks GraphQL, not the REST issue endpoint ──────────────────────
GH_MODE=parent
its::get_parent 125 >/dev/null || true
if grep -qx 'graphql' "$ARGV_FILE"; then
  pass "queries the graphql endpoint"
else
  fail "did not call 'gh api graphql' (argv: $(tr '\n' ' ' < "$ARGV_FILE"))"
fi
if grep -q 'repos/.*/issues/' "$ARGV_FILE"; then
  fail "still hits the REST issue endpoint, which carries no parent field"
else
  pass "does not read the parent off the REST issue payload"
fi

# ── 5. regression guard across the tree ──────────────────────────────────
# No call site may go back to `.parent.number` on the REST payload.
# `grep -rn` prefixes each hit with `path:line:`, so a comment line reads
# `…/pre.sh:54:  # …` — anchoring on ^# would never match. Strip the prefix
# before deciding whether the hit is code, otherwise the prose explaining this
# very bug trips its own guard.
live_hits() {
  grep -rn '\.parent\.number' "$REPO_ROOT/.autoducks" \
    --include='*.sh' --include='*.py' 2>/dev/null \
    | grep -v 'get-parent.sh' \
    | grep -vE ':[0-9]+:[[:space:]]*#'
}
if live_hits | grep -q .; then
  fail "a call site reads .parent.number outside get-parent.sh"
  live_hits | sed 's/^/      /'
else
  pass "no call site reads .parent.number off the REST payload"
fi

# ── 6. the interface declares it ─────────────────────────────────────────
if grep -q '"its::get_parent"' "$REPO_ROOT/.autoducks/providers/its/interface.sh"; then
  pass "its::get_parent is in the provider's REQUIRED_FUNCTIONS"
else
  fail "its::get_parent missing from REQUIRED_FUNCTIONS — a provider could omit it"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
