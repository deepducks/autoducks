#!/usr/bin/env bash
# Unit tests for two HIGH-severity resolver-agent paths:
#
#  1. Cancellation (`cancellation::handle`,
#     .autoducks/core/feedback/handle-cancellation.sh) — a workflow-level
#     cancellation is a neutral 🚫 terminal state, not a failure: no
#     notify_failure/notify_skip, the in-progress label is cleared, and the
#     run `exit 0`s. JOB_STATUS unset/"success" must no-op instead.
#  2. The resolver's opt-out gate (.autoducks/agents/resolver/pre.sh:78-97) —
#     `resolver.auto=false` and the `Resolve:off` label only gate the
#     automatic (`pull_request`/`synchronize`) trigger; the human-triggered
#     `/resolve` (`issue_comment`) path ignores both.
#
# Mirrors the mocked its::*/gh style of test/unit-rework-labels.sh and
# test/unit-reviewer-mirror.sh, driven against the real handle-cancellation.sh
# / progress-labels.sh / status-comment.sh helpers.
# Run: bash test/unit-resolver-paths.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

LOG=$(mktemp)
reset() { : > "$LOG"; rm -f /tmp/autoducks-status-comment-id.10; }

# Mocks — gh (status_comment::start's initial post), its::update_comment /
# its::comment_issue (status-comment.sh), its::add_label / its::remove_label
# (progress-labels.sh), and notify_failure / notify_skip stand-ins so a call
# from the cancellation path would be observable. All calls are appended to
# one log for assertion.
gh() {
  echo "GH:$*" >> "$LOG"
  local issue_num="$3"
  echo "https://github.com/x/y/issues/${issue_num}#issuecomment-1${issue_num}"
}
its::update_comment() { echo "UPDATE:$1|$2" >> "$LOG"; }
its::comment_issue()  { echo "COMMENT:$1|$2" >> "$LOG"; }
its::add_label()      { echo "ADD:$1|$2" >> "$LOG"; }
its::remove_label()   { echo "REMOVE:$1|$2" >> "$LOG"; }
notify_failure()       { echo "NOTIFY_FAILURE:$*" >> "$LOG"; }
notify_skip()          { echo "NOTIFY_SKIP:$*" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="resolver"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/progress-labels.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/handle-cancellation.sh"

echo "── cancellation::handle: JOB_STATUS=cancelled is a neutral terminal state ──"
reset
EXIT_CODE=0
( export JOB_STATUS=cancelled; cancellation::handle "10" "Resolve:resolving" ) || EXIT_CODE=$?
if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "cancellation::handle exit 0s on the cancelled path"
else
  fail "expected exit 0, got $EXIT_CODE"
fi
if grep -qE '^(GH:issue comment 10|UPDATE:|COMMENT:10\|)' "$LOG"; then
  pass "status_comment::cancel posted/edited a comment for #10"
else
  fail "no status comment activity: $(cat "$LOG")"
fi
if grep -q '🚫' "$LOG"; then
  pass "status comment carries the neutral 🚫 marker"
else
  fail "no 🚫 marker found: $(cat "$LOG")"
fi
if grep -qE '⚠️|😕' "$LOG"; then
  fail "a failure marker (⚠️/😕) leaked into the cancellation path: $(cat "$LOG")"
else
  pass "no ⚠️/😕 failure markers"
fi
if grep -q '^REMOVE:10|Resolve:resolving$' "$LOG"; then
  pass "Resolve:resolving label cleared"
else
  fail "Resolve:resolving was not removed: $(cat "$LOG")"
fi
if grep -q '^NOTIFY_FAILURE' "$LOG"; then
  fail "notify_failure was called on a cancellation: $(cat "$LOG")"
else
  pass "notify_failure was not called"
fi
if grep -q '^NOTIFY_SKIP' "$LOG"; then
  fail "notify_skip was called on a cancellation: $(cat "$LOG")"
else
  pass "notify_skip was not called"
fi

echo "── cancellation::handle: JOB_STATUS unset/success is a no-op ──"
reset
EXIT_CODE=0
( unset JOB_STATUS; cancellation::handle "10" "Resolve:resolving" ) || EXIT_CODE=$?
if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "JOB_STATUS unset: returns 0"
else
  fail "JOB_STATUS unset: expected return 0, got $EXIT_CODE"
fi
if [[ -s "$LOG" ]]; then
  fail "JOB_STATUS unset: unexpected side effects: $(cat "$LOG")"
else
  pass "JOB_STATUS unset: no side effects"
fi

reset
EXIT_CODE=0
( export JOB_STATUS=success; cancellation::handle "10" "Resolve:resolving" ) || EXIT_CODE=$?
if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "JOB_STATUS=success: returns 0"
else
  fail "JOB_STATUS=success: expected return 0, got $EXIT_CODE"
fi
if [[ -s "$LOG" ]]; then
  fail "JOB_STATUS=success: unexpected side effects: $(cat "$LOG")"
else
  pass "JOB_STATUS=success: no side effects"
fi

echo "── resolver opt-out gate (resolver/pre.sh:78-97) ──"

skip_resolve() { echo "SKIP:$1" >> "$LOG"; }

# resolver_opt_out_gate EVENT_NAME ACTION PR_NUM AUTODUCKS_JSON — mirrors the
# IS_AUTOMATIC / resolver.auto / Resolve:off block in resolver/pre.sh.
resolver_opt_out_gate() {
  local event_name="$1" action="$2" pr_num="$3" autoducks_json="$4"
  local is_automatic=false
  if [[ "$event_name" == "pull_request" && "$action" == "synchronize" ]]; then
    is_automatic=true
  fi
  [[ "$is_automatic" == "true" ]] || return 0

  local resolver_auto
  resolver_auto=$(jq -r 'if .resolver.auto == null then true else .resolver.auto end' "$autoducks_json")
  if [[ "$resolver_auto" == "false" ]]; then
    skip_resolve "Automatic conflict resolution is disabled (\`resolver.auto\` is \`false\`)."
    return 0
  fi

  local opt_out_label
  opt_out_label=$(jq -r '.resolver.opt_out_label // "Resolve:off"' "$autoducks_json")
  if gh pr view "$pr_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null | grep -qxF "$opt_out_label"; then
    skip_resolve "PR #$pr_num carries the \`$opt_out_label\` opt-out label."
  fi
}

CONFIG_AUTO_FALSE=$(mktemp)
echo '{"resolver": {"auto": false}}' > "$CONFIG_AUTO_FALSE"
CONFIG_AUTO_TRUE=$(mktemp)
echo '{"resolver": {"auto": true}}' > "$CONFIG_AUTO_TRUE"

CASE_LABELS=()
gh() {
  if [[ "$1 $2" == "pr view" ]]; then
    printf '%s\n' "${CASE_LABELS[@]}"
    return 0
  fi
  echo "GH:$*" >> "$LOG"
}

echo "── automatic (pull_request/synchronize) + resolver.auto=false → skip ──"
reset
CASE_LABELS=()
resolver_opt_out_gate "pull_request" "synchronize" "77" "$CONFIG_AUTO_FALSE"
if grep -q '^SKIP:.*disabled' "$LOG"; then
  pass "skip_resolve fires for resolver.auto=false"
else
  fail "expected skip_resolve for resolver.auto=false: $(cat "$LOG")"
fi

echo "── automatic (pull_request/synchronize) + Resolve:off label → skip ──"
reset
CASE_LABELS=("Resolve:off")
resolver_opt_out_gate "pull_request" "synchronize" "77" "$CONFIG_AUTO_TRUE"
if grep -q '^SKIP:.*opt-out label' "$LOG"; then
  pass "skip_resolve fires for the Resolve:off label"
else
  fail "expected skip_resolve for Resolve:off label: $(cat "$LOG")"
fi

echo "── /resolve (issue_comment) path ignores both gates ──"
reset
CASE_LABELS=("Resolve:off")
resolver_opt_out_gate "issue_comment" "created" "77" "$CONFIG_AUTO_FALSE"
if [[ -s "$LOG" ]]; then
  fail "/resolve path should not be gated by resolver.auto or Resolve:off: $(cat "$LOG")"
else
  pass "skip_resolve did not fire on the /resolve (issue_comment) path"
fi

rm -f "$LOG" "$CONFIG_AUTO_FALSE" "$CONFIG_AUTO_TRUE" /tmp/autoducks-status-comment-id.10

echo ""
echo "═══ resolver-paths: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
