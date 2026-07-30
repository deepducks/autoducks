#!/usr/bin/env bash
# Unit tests for the "already reported" sentinel that keeps the YAML Failure
# watchdog from contradicting a report post.sh just posted (#117).
# Run: bash test/unit-failure-reported.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export REPO="acme/widgets"
export AUTODUCKS_AGENT="developer"
export AUTODUCKS_COMMAND="${AUTODUCKS_COMMAND:-}"

# Stubs for everything the reporting helpers reach out to.
its::comment_issue() { :; }
autoducks_command_for() { echo "/$1"; }
status_comment::_edit() { :; }
status_comment::_label() { echo "Developer"; }
status_comment::_run_link() { echo "run 1"; }

# ---------------------------------------------------------------------------
# reported_output FUNC ARGS... — run FUNC in a subshell with a fresh
# $GITHUB_OUTPUT and echo whatever landed in it.
# ---------------------------------------------------------------------------
reported_output() {
  local out="$SCRATCH/gh_output.$RANDOM"
  : > "$out"
  (
    set +e
    export GITHUB_OUTPUT="$out"
    unset _AUTODUCKS_REPORTED _AUTODUCKS_NOTIFIED
    source "$REPO_ROOT/.autoducks/core/feedback/failure-reported.sh"
    source "$REPO_ROOT/.autoducks/core/feedback/notify-failure.sh"
    # Re-stub after sourcing, in case a source pulled in a real definition.
    its::comment_issue() { :; }
    autoducks_command_for() { echo "/$1"; }
    "$@" >/dev/null 2>&1
  )
  cat "$out"
}

echo "── feedback::mark_reported ──"

got="$(reported_output feedback::mark_reported)"
if [[ "$got" == "reported=true" ]]; then
  pass "writes reported=true to \$GITHUB_OUTPUT"
else
  fail "writes reported=true to \$GITHUB_OUTPUT — got '$got'"
fi

# Idempotent: a post.sh path that reports twice must not emit two lines.
out="$SCRATCH/twice"; : > "$out"
(
  export GITHUB_OUTPUT="$out"
  unset _AUTODUCKS_REPORTED
  source "$REPO_ROOT/.autoducks/core/feedback/failure-reported.sh"
  feedback::mark_reported
  feedback::mark_reported
) >/dev/null 2>&1
if [[ "$(wc -l < "$out" | tr -d ' ')" == "1" ]]; then
  pass "idempotent — two calls emit one line"
else
  fail "idempotent — expected 1 line, got $(wc -l < "$out" | tr -d ' ')"
fi

# Outside GitHub Actions there is no $GITHUB_OUTPUT; must be a silent no-op and
# must not trip `set -e` in the caller.
if (
  set -euo pipefail
  unset GITHUB_OUTPUT _AUTODUCKS_REPORTED
  source "$REPO_ROOT/.autoducks/core/feedback/failure-reported.sh"
  feedback::mark_reported
  echo survived
) >/dev/null 2>&1; then
  pass "no-op without \$GITHUB_OUTPUT, returns success under set -e"
else
  fail "no-op without \$GITHUB_OUTPUT, returns success under set -e"
fi

echo "── every deliberate-failure reporter sets the mark ──"

got="$(reported_output notify_failure 42 999)"
if [[ "$got" == *"reported=true"* ]]; then
  pass "notify_failure marks the run as reported"
else
  fail "notify_failure marks the run as reported — got '$got'"
fi

got="$(reported_output notify_conflict 42 999 feature/42-x 7)"
if [[ "$got" == *"reported=true"* ]]; then
  pass "notify_conflict marks the run as reported"
else
  fail "notify_conflict marks the run as reported — got '$got'"
fi

out="$SCRATCH/status_fail"; : > "$out"
(
  set +e
  export GITHUB_OUTPUT="$out"
  unset _AUTODUCKS_REPORTED
  source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"
  its::comment_issue() { :; }
  status_comment::_edit() { :; }
  status_comment::fail 42
) >/dev/null 2>&1
if [[ "$(cat "$out")" == *"reported=true"* ]]; then
  pass "status_comment::fail marks the run as reported"
else
  fail "status_comment::fail marks the run as reported — got '$(cat "$out")'"
fi

# The clean terminal states must NOT set it — a successful run that never
# reported a failure has nothing to suppress.
for fn in finish cancel delegate; do
  out="$SCRATCH/status_$fn"; : > "$out"
  (
    set +e
    export GITHUB_OUTPUT="$out"
    unset _AUTODUCKS_REPORTED
    source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"
    its::comment_issue() { :; }
    status_comment::_edit() { :; }
    "status_comment::$fn" 42
  ) >/dev/null 2>&1
  if [[ -z "$(cat "$out")" ]]; then
    pass "status_comment::$fn does not set the mark"
  else
    fail "status_comment::$fn must not set the mark — got '$(cat "$out")'"
  fi
done

echo "── the watchdog is gated on the mark in every workflow ──"

WATCHDOG_AGENTS=(architect defer developer engineer fix product resolver reviewer rework)
for a in "${WATCHDOG_AGENTS[@]}"; do
  for dir in ".autoducks/runtimes/github-actions" ".github/workflows"; do
    f="$REPO_ROOT/$dir/autoducks-$a.yml"
    if [[ ! -f "$f" ]]; then
      fail "$dir/autoducks-$a.yml: missing"
      continue
    fi
    # The gate must live inside the watchdog step's own `if:`, not merely
    # somewhere in the file.
    block="$(awk '/^      - name: Failure watchdog$/{f=1} f{print} f&&/^        run: \|$/{exit}' "$f")"
    if [[ -z "$block" ]]; then
      fail "$dir/autoducks-$a.yml: no Failure watchdog step found"
      continue
    fi
    if grep -qF "steps.post.outputs.reported != 'true'" <<<"$block"; then
      pass "$dir/autoducks-$a.yml: watchdog gated on steps.post.outputs.reported"
    else
      fail "$dir/autoducks-$a.yml: watchdog NOT gated on steps.post.outputs.reported"
    fi
    # The old, broken sole condition must not survive ungated.
    if grep -qE "steps\.post\.outcome != 'success'\)\s*$" <<<"$block"; then
      fail "$dir/autoducks-$a.yml: post.outcome check still terminates the condition"
    else
      pass "$dir/autoducks-$a.yml: post.outcome check no longer terminates the condition"
    fi
  done
done

echo ""
echo "═══ failure-reported: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
