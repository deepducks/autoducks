#!/usr/bin/env bash
# Provider-contract test for .autoducks/providers/its/github/create-issue.sh
#
# its::create_issue is declared in .autoducks/providers/its/interface.sh:28
# as its::create_issue(title, body, labels, type, parent_id?). This test
# stubs `gh` and `its::link_sub_issue` and asserts: a non-empty `type` arg
# lands in the POST payload as {type: ...}; an empty `type` omits the key;
# and the 5th positional arg is honored as parent_id (triggers
# its::link_sub_issue) — so an arity regression (e.g. the type arg getting
# dropped or the positions shifting) fails CI instead of only surfacing at
# runtime.
#
# Run: bash test/unit-its-create-issue.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── gh stub ──────────────────────────────────────────────────────────────
# its::create_issue shells out to `echo "$payload" | gh api repos/$REPO/issues
# --method POST --input -`. Because its::create_issue's stdout is captured
# via command substitution (a subshell), the stub can't hand its payload
# back through a plain variable — it writes it to a file instead.
#
# its::link_sub_issue is similarly stubbed via a file marker rather than a
# variable for the same reason.
gh() {
  case "$1 $2" in
    "api "*)
      cat > "$LAST_PAYLOAD_FILE"
      echo '{"number": 99, "id": 12345}'
      ;;
    *)
      echo "gh stub: unexpected invocation: $*" >&2
      return 1
      ;;
  esac
}

its::link_sub_issue() {
  echo "$1 $2" > "$LINK_SUB_ISSUE_ARGS_FILE"
  echo "linked"
}

export REPO="acme/widgets"

BODY_FILE="$(mktemp)"
LAST_PAYLOAD_FILE="$(mktemp)"
LINK_SUB_ISSUE_ARGS_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$LAST_PAYLOAD_FILE" "$LINK_SUB_ISSUE_ARGS_FILE"' EXIT
echo "Issue body text" > "$BODY_FILE"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/its/github/create-issue.sh"

echo "── its::create_issue: non-empty type lands in payload ──"

: > "$LAST_PAYLOAD_FILE"
: > "$LINK_SUB_ISSUE_ARGS_FILE"
OUT="$(its::create_issue "Some title" "$BODY_FILE" "" "Bug" "")"
LAST_PAYLOAD="$(cat "$LAST_PAYLOAD_FILE")"

[[ "$OUT" == "99" ]] && pass "returns the created issue number" || fail "unexpected return value: $OUT"
[[ "$(echo "$LAST_PAYLOAD" | jq -r '.type')" == "Bug" ]] \
  && pass "type is included in the create payload" \
  || fail "type missing/mismatched in payload: $LAST_PAYLOAD"
[[ ! -s "$LINK_SUB_ISSUE_ARGS_FILE" ]] \
  && pass "link_sub_issue not called when parent_id is empty" \
  || fail "link_sub_issue was unexpectedly called"

echo ""
echo "── its::create_issue: empty type omits the key ──"

: > "$LAST_PAYLOAD_FILE"
OUT="$(its::create_issue "Some title" "$BODY_FILE" "" "" "")"
LAST_PAYLOAD="$(cat "$LAST_PAYLOAD_FILE")"

if echo "$LAST_PAYLOAD" | jq -e 'has("type")' >/dev/null 2>&1; then
  fail "type key present in payload when type arg was empty: $LAST_PAYLOAD"
else
  pass "type key omitted from payload when type arg is empty"
fi

echo ""
echo "── its::create_issue: 5th arg honored as parent_id ──"

: > "$LAST_PAYLOAD_FILE"
: > "$LINK_SUB_ISSUE_ARGS_FILE"
OUT="$(its::create_issue "Some title" "$BODY_FILE" "" "" "555")"
LINK_SUB_ISSUE_ARGS="$(cat "$LINK_SUB_ISSUE_ARGS_FILE")"

[[ -s "$LINK_SUB_ISSUE_ARGS_FILE" ]] \
  && pass "link_sub_issue called when 5th arg (parent_id) is set" \
  || fail "link_sub_issue was NOT called — positional arity regressed"
[[ "$LINK_SUB_ISSUE_ARGS" == "555 12345" ]] \
  && pass "link_sub_issue receives parent_id and the created issue db id" \
  || fail "link_sub_issue args mismatch: $LINK_SUB_ISSUE_ARGS"

echo ""
echo "═══ its-create-issue: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
