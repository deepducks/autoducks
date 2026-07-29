#!/usr/bin/env bash
# Provider-contract test for .autoducks/providers/its/github/close-issue.sh
#
# its::close_issue is declared in .autoducks/providers/its/interface.sh:29 as
# its::close_issue(issue_id, comment?, reason?). REASON is validated and
# mapped to gh's spelling *before* any `gh` call is made — completed and
# duplicate pass through unchanged, not_planned (and the already-CLI-spelled
# "not planned") map to the single element "not planned", anything else is
# rejected with no gh call. On a failed close, the module probes
# `gh issue view` to distinguish "already closed" (quiet no-op) from "still
# open" (a single-line ::warning::).
#
# This stubs `gh` as a shell function that dispatches on `gh issue close` vs
# `gh issue view` and records argv one element per line (so a reason split
# across two argv elements is visible, not hidden behind string equality),
# then walks the full case matrix plus two repo-wide grep guards over every
# its::close_issue call site under .autoducks/ — guarding against the two
# regressions that motivated this test: a not_planned-class reason typo, and
# a `2>/dev/null` on a close call that would swallow the ::warning::/::error::.
#
# Run: bash test/unit-its-close-issue.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── gh stub ──────────────────────────────────────────────────────────────
# its::close_issue shells out to `gh issue close ID --repo R [--comment C]
# [--reason X]` and, only on a failed close, to `gh issue view ID --repo R
# --json state --jq '.state'`. Since its::close_issue's stderr is captured
# via command substitution in some cases (a subshell), the stub can't hand
# recorded args back through a plain variable — it writes them to a file,
# one per line, instead.
ARGV_FILE="$(mktemp)"
CLOSE_INVOKED_FILE="$(mktemp)"
rm -f "$CLOSE_INVOKED_FILE"
trap 'rm -f "$ARGV_FILE" "$CLOSE_INVOKED_FILE"' EXIT

gh() {
  case "$1 $2" in
    "issue close")
      touch "$CLOSE_INVOKED_FILE"
      : > "$ARGV_FILE"
      for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
      if [[ "${MOCK_CLOSE_RC:-0}" -ne 0 ]]; then
        # Multi-line gh stderr — close-issue.sh must join this into a
        # single-line ::warning:: (case 8).
        echo "HTTP 422: Validation Failed" >&2
        echo "could not close issue: state reason invalid" >&2
      fi
      return "${MOCK_CLOSE_RC:-0}"
      ;;
    "issue view")
      if [[ "${MOCK_VIEW_FAIL:-false}" == "true" ]]; then
        return 1
      fi
      echo "$MOCK_VIEW_STATE"
      return 0
      ;;
    *)
      echo "gh stub: unexpected invocation: $*" >&2
      return 1
      ;;
  esac
}

export REPO="acme/widgets"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/its/github/close-issue.sh"

# assert_element_after LABEL MARKER EXPECTED
# Finds the argv line that exactly equals MARKER and asserts the *next*
# recorded line exactly equals EXPECTED — i.e. EXPECTED arrived as one argv
# element, not split across several.
assert_element_after() {
  local label="$1" marker="$2" expected="$3"
  local line_no
  line_no="$(grep -n -F -x -- "$marker" "$ARGV_FILE" | head -1 | cut -d: -f1)"
  if [[ -z "$line_no" ]]; then
    fail "$label — no '$marker' element in recorded argv: $(tr '\n' '|' < "$ARGV_FILE")"
    return
  fi
  local actual
  actual="$(sed -n "$((line_no + 1))p" "$ARGV_FILE")"
  [[ "$actual" == "$expected" ]] \
    && pass "$label" \
    || fail "$label — expected '$expected' after '$marker', got '$actual' (argv: $(tr '\n' '|' < "$ARGV_FILE"))"
}

assert_no_element() {
  local label="$1" marker="$2"
  if grep -q -F -x -- "$marker" "$ARGV_FILE"; then
    fail "$label — unexpected '$marker' in recorded argv: $(tr '\n' '|' < "$ARGV_FILE")"
  else
    pass "$label"
  fi
}

echo "── its::close_issue: reason mapping ──"

MOCK_CLOSE_RC=0

RC=0
its::close_issue 42 "" not_planned || RC=$?
[[ "$RC" -eq 0 ]] && pass "case1: exits 0" || fail "case1: expected exit 0, got $RC"
assert_element_after "case1: not_planned maps to a single '--reason' 'not planned' element" "--reason" "not planned"

RC=0
its::close_issue 42 "" completed || RC=$?
[[ "$RC" -eq 0 ]] && pass "case2: exits 0" || fail "case2: expected exit 0, got $RC"
assert_element_after "case2: completed passes through" "--reason" "completed"

RC=0
its::close_issue 42 "" duplicate || RC=$?
[[ "$RC" -eq 0 ]] && pass "case3: exits 0" || fail "case3: expected exit 0, got $RC"
assert_element_after "case3: duplicate passes through" "--reason" "duplicate"

RC=0
its::close_issue 42 "" "not planned" || RC=$?
[[ "$RC" -eq 0 ]] && pass "case4: exits 0" || fail "case4: expected exit 0, got $RC"
assert_element_after "case4: already-CLI-spelled 'not planned' is idempotent" "--reason" "not planned"

echo ""
echo "── its::close_issue: omitted / propagated args ──"

RC=0
its::close_issue 42 || RC=$?
[[ "$RC" -eq 0 ]] && pass "case5: exits 0" || fail "case5: expected exit 0, got $RC"
assert_no_element "case5: no --reason element when reason omitted" "--reason"

RC=0
its::close_issue 42 "msg" not_planned || RC=$?
[[ "$RC" -eq 0 ]] && pass "case6: exits 0" || fail "case6: expected exit 0, got $RC"
assert_element_after "case6: --comment carries the comment" "--comment" "msg"
assert_element_after "case6: --repo carries \$REPO" "--repo" "$REPO"

echo ""
echo "── its::close_issue: invalid reason rejected before any gh call ──"

rm -f "$CLOSE_INVOKED_FILE"
OUT=""
RC=0
if OUT="$(its::close_issue 42 "" bogus 2>&1)"; then RC=0; else RC=$?; fi
[[ "$RC" -eq 2 ]] && pass "case7: exits 2 on an invalid reason" || fail "case7: expected exit 2, got $RC ($OUT)"
[[ ! -f "$CLOSE_INVOKED_FILE" ]] \
  && pass "case7: gh issue close was never invoked" \
  || fail "case7: gh issue close WAS invoked for an invalid reason"
echo "$OUT" | grep -Eq '::error::.*invalid reason' \
  && pass "case7: stderr carries an ::error:: mentioning invalid reason" \
  || fail "case7: stderr didn't match ::error::...invalid reason: $OUT"

echo ""
echo "── its::close_issue: close fails, probe distinguishes open vs closed vs unreachable ──"

MOCK_CLOSE_RC=1
MOCK_VIEW_FAIL=false
MOCK_VIEW_STATE="OPEN"
OUT=""
RC=0
if OUT="$(its::close_issue 42 2>&1)"; then RC=0; else RC=$?; fi
[[ "$RC" -eq 1 ]] && pass "case8: exits 1 when close fails and the issue is still open" || fail "case8: expected exit 1, got $RC ($OUT)"
echo "$OUT" | grep -Eq '::warning::.*could not close #42' \
  && pass "case8: stderr carries a ::warning:: naming #42" \
  || fail "case8: stderr didn't match ::warning::...could not close #42: $OUT"
WARNING_LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[[ "$WARNING_LINES" -eq 1 ]] \
  && pass "case8: the ::warning:: occupies exactly one line" \
  || fail "case8: expected exactly 1 line of stderr, got $WARNING_LINES: $OUT"

MOCK_CLOSE_RC=1
MOCK_VIEW_FAIL=false
MOCK_VIEW_STATE="CLOSED"
OUT=""
RC=0
if OUT="$(its::close_issue 42 2>&1)"; then RC=0; else RC=$?; fi
[[ "$RC" -eq 0 ]] && pass "case9: exits 0 when close fails but the issue is already CLOSED" || fail "case9: expected exit 0, got $RC ($OUT)"
echo "$OUT" | grep -q '::warning::' \
  && fail "case9: unexpected ::warning:: for an already-closed issue: $OUT" \
  || pass "case9: no ::warning:: for an already-closed issue"

MOCK_CLOSE_RC=1
MOCK_VIEW_FAIL=true
MOCK_VIEW_STATE=""
OUT=""
RC=0
if OUT="$(its::close_issue 42 2>&1)"; then RC=0; else RC=$?; fi
[[ "$RC" -eq 1 ]] \
  && pass "case10: exits 1 when the state probe itself fails — unreachable is not success" \
  || fail "case10: expected exit 1, got $RC ($OUT)"

# ── guards: every its::close_issue call site under .autoducks/ ─────────────
#
# join_close_issue_calls prints one logical call statement per line, joining
# backslash-continued physical lines (the style architect/post.sh and
# developer/post.sh use to wrap long calls) into a single string. It only
# starts accumulating on a real invocation — "its::close_issue" followed by
# whitespace then a quote or a `$` sigil — so it skips the function
# definition, its --help usage text, and the ::debug::/::warning::/::error::
# message strings inside close-issue.sh itself, all of which contain the
# literal substring "its::close_issue" but aren't calls.
join_close_issue_calls() {
  awk '
    function is_comment(l) { return (l ~ /^[[:space:]]*#/) }
    {
      line = $0
      if (in_call) {
        buf = buf " " line
      } else if (!is_comment(line) && line ~ /its::close_issue[[:space:]]+["$]/) {
        buf = line
        in_call = 1
      } else {
        next
      }
      if (buf ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", buf)
        next
      }
      print buf
      in_call = 0
      buf = ""
    }
  ' "$1"
}

echo ""
echo "── guard: its::close_issue call-site contract across .autoducks/ ──"

CALL_COUNT=0
BAD_REASON=""
BAD_SUPPRESS=""

while IFS= read -r -d '' f; do
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    CALL_COUNT=$((CALL_COUNT + 1))

    if [[ "$call" == *"2>/dev/null"* ]]; then
      BAD_SUPPRESS="${BAD_SUPPRESS}${f#"$REPO_ROOT"/}: ${call}"$'\n'
    fi

    # Drop everything through "its::close_issue" and its following
    # whitespace, then drop the trailing `|| ...` fallback clause — what's
    # left is just the argument list.
    args="${call#*its::close_issue}"
    args="${args%%||*}"

    toks=()
    rest="$args"
    while [[ "$rest" =~ \"([^\"]*)\" ]]; do
      toks+=("${BASH_REMATCH[1]}")
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done

    if [[ "${#toks[@]}" -ge 3 ]]; then
      reason="${toks[2]}"
      case "$reason" in
        completed | not_planned | duplicate) : ;;
        *) BAD_REASON="${BAD_REASON}${f#"$REPO_ROOT"/}: reason='${reason}'"$'\n' ;;
      esac
    fi
  done < <(join_close_issue_calls "$f")
done < <(find "$REPO_ROOT/.autoducks" -name '*.sh' -print0)

if [[ "$CALL_COUNT" -gt 0 ]]; then
  pass "guard setup: found $CALL_COUNT its::close_issue call site(s) under .autoducks/"
else
  fail "guard setup: found no its::close_issue call sites under .autoducks/ — guard would be vacuous"
fi

if [[ -z "$BAD_REASON" ]]; then
  pass "guard 11: every explicit third-argument reason is completed|not_planned|duplicate"
else
  fail "guard 11: invalid reason literal(s) found:"$'\n'"$BAD_REASON"
fi

if [[ -z "$BAD_SUPPRESS" ]]; then
  pass "guard 12: no its::close_issue call redirects stderr with 2>/dev/null"
else
  fail "guard 12: 2>/dev/null found on an its::close_issue call:"$'\n'"$BAD_SUPPRESS"
fi

echo ""
echo "═══ its-close-issue: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
