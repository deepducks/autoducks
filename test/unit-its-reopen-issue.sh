#!/usr/bin/env bash
# Provider-contract test for .autoducks/providers/its/github/reopen-issue.sh
#
# its::reopen_issue is declared in .autoducks/providers/its/interface.sh as
# its::reopen_issue(issue_id, comment?). This test stubs `gh` and asserts:
# the issue is reopened via `gh issue reopen ID --repo $REPO`; a comment arg
# adds `--comment <comment>`; and omitting it does not — so an arity
# regression fails CI instead of only surfacing at runtime.
#
# Run: bash test/unit-its-reopen-issue.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── gh stub ──────────────────────────────────────────────────────────────
# its::reopen_issue shells out to `gh issue reopen ID --repo $REPO
# [--comment COMMENT]`. Since its::reopen_issue's stdout is captured via
# command substitution (a subshell), the stub can't hand its args back
# through a plain variable — it writes them to a file instead.
gh() {
  case "$1 $2" in
    "issue reopen")
      shift 2
      echo "$*" > "$LAST_ARGS_FILE"
      ;;
    *)
      echo "gh stub: unexpected invocation: $*" >&2
      return 1
      ;;
  esac
}

export REPO="acme/widgets"

LAST_ARGS_FILE="$(mktemp)"
trap 'rm -f "$LAST_ARGS_FILE"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/its/github/reopen-issue.sh"

echo "── its::reopen_issue: no comment ──"

: > "$LAST_ARGS_FILE"
its::reopen_issue 42
LAST_ARGS="$(cat "$LAST_ARGS_FILE")"

[[ "$LAST_ARGS" == "42 --repo acme/widgets" ]] \
  && pass "invokes gh issue reopen with --repo and no --comment" \
  || fail "unexpected args: $LAST_ARGS"

echo ""
echo "── its::reopen_issue: with comment ──"

: > "$LAST_ARGS_FILE"
its::reopen_issue 42 "Reopening, still repros"
LAST_ARGS="$(cat "$LAST_ARGS_FILE")"

[[ "$LAST_ARGS" == "42 --repo acme/widgets --comment Reopening, still repros" ]] \
  && pass "adds --comment when a comment is passed" \
  || fail "unexpected args: $LAST_ARGS"

echo ""
echo "── its::reopen_issue --help ──"

HELP_OUT="$(bash "$REPO_ROOT/.autoducks/providers/its/github/reopen-issue.sh" --help)"
RC=0
bash "$REPO_ROOT/.autoducks/providers/its/github/reopen-issue.sh" --help >/dev/null || RC=$?

[[ "$RC" -eq 0 ]] && pass "--help exits 0" || fail "expected exit 0, got rc=$RC"
echo "$HELP_OUT" | grep -q "Usage: its::reopen_issue" \
  && pass "--help prints usage" \
  || fail "--help output missing usage: $HELP_OUT"

echo ""
echo "═══ its-reopen-issue: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
