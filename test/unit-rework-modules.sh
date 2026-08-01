#!/usr/bin/env bash
# Unit tests for the metarepo `**Modules:**` contract on rework tasks (#181).
#
# In metarepo mode all real code lives in submodules, so a rework task with no
# declared modules is unexecutable: the developer's drift guard rejects its
# first commit. Three things have to hold, and each one is a separate failure
# mode this file pins:
#   1. the Rework prompt asks for `**Modules:**` and is handed the metarepo
#      runtime signal (the gap that caused the bug — the parser always
#      supported the field, nothing ever asked the agent for it);
#   2. rework/pre.sh actually writes /tmp/metarepo-context.md, gated on
#      metarepo::enabled, and clears a stale one otherwise;
#   3. rework/post.sh rejects an untagged task at creation time, and the drift
#      guard's remediation never names `/engineer` on a rework task.
# Run: bash test/unit-rework-modules.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REWORK="$REPO_ROOT/.autoducks/agents/rework"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── 1. Prompt contract ────────────────────────────────────────────────────
echo "── rework/prompt.md declares the Modules contract ──"

if grep -q '^\*\*Modules:\*\*' "$REWORK/prompt.md"; then
  pass "output template carries a **Modules:** line"
else
  fail "output template has no **Modules:** line — tasks will be filed untagged"
fi

if grep -q '/tmp/metarepo-context.md' "$REWORK/prompt.md"; then
  pass "prompt documents the /tmp/metarepo-context.md input"
else
  fail "prompt never mentions /tmp/metarepo-context.md — agent can't detect metarepo mode"
fi

if grep -q 'Omit this line entirely outside metarepo mode' "$REWORK/prompt.md"; then
  pass "**Modules:** is gated on metarepo mode"
else
  fail "**Modules:** is not gated — single-repo tasks would emit a bogus line"
fi

# ── 2. pre.sh emits the runtime signal ────────────────────────────────────
echo "── rework/pre.sh writes the metarepo runtime signal ──"

# Extract the guarded block and run it against stub helpers, so the assertion
# is on real script text rather than a re-implementation of it.
BLOCK=$(awk '/^rm -f \/tmp\/metarepo-context.md$/,/^fi$/' "$REWORK/pre.sh")
if [[ -z "$BLOCK" ]]; then
  fail "pre.sh has no metarepo-context block"
else
  pass "pre.sh contains a metarepo-context block"

  TMPD=$(mktemp -d)
  trap 'rm -rf "$TMPD"' EXIT
  run_block() { # run_block <enabled true|false> → prints the resulting file, if any
    local enabled="$1"
    ( set -euo pipefail
      metarepo::enabled() { [[ "$enabled" == "true" ]]; }
      metarepo::agent_context_block() { echo "SIGNAL"; }
      eval "$BLOCK" ) >/dev/null
    cat /tmp/metarepo-context.md 2>/dev/null || true
  }

  printf 'STALE\n' > /tmp/metarepo-context.md
  if [[ "$(run_block true)" == "SIGNAL" ]]; then
    pass "metarepo mode → /tmp/metarepo-context.md holds the context block"
  else
    fail "metarepo mode → no context block written"
  fi

  printf 'STALE\n' > /tmp/metarepo-context.md
  if [[ -z "$(run_block false)" ]]; then
    pass "single-repo mode → a stale context file is removed, not left to lie"
  else
    fail "single-repo mode → stale /tmp/metarepo-context.md survived"
  fi
  rm -f /tmp/metarepo-context.md
fi

# ── 3a. post.sh rejects an untagged task before it is filed ───────────────
echo "── rework/post.sh guards task creation ──"

if grep -q 'metarepo::modules_from_body "\$TASK_BODY"' "$REWORK/post.sh"; then
  pass "post.sh validates the parsed task's modules"
else
  fail "post.sh never checks the task's modules — failure moves to the developer's post phase"
fi

# The guard must run before the task is filed; otherwise a broken task is
# already an issue on the board by the time anyone notices.
GUARD_LINE=$(grep -n 'metarepo::modules_from_body "\$TASK_BODY"' "$REWORK/post.sh" | head -1 | cut -d: -f1)
RECONCILE_LINE=$(grep -n '^RECONCILE_OUTPUT=' "$REWORK/post.sh" | head -1 | cut -d: -f1)
if [[ -n "$GUARD_LINE" && -n "$RECONCILE_LINE" && "$GUARD_LINE" -lt "$RECONCILE_LINE" ]]; then
  pass "guard runs before reconcile_tasks files the issue"
else
  fail "guard does not precede reconcile_tasks (guard=$GUARD_LINE reconcile=$RECONCILE_LINE)"
fi

# ── 3b. drift-guard remediation is context-aware ──────────────────────────
echo "── drift guard: remediation points at the task, not at a blind re-plan ──"

# shellcheck source=/dev/null
autoducks_command_for() { echo "/$1"; }
its::get_issue() { printf '{"body":%s}' "$(printf '%s' "$GUARD_BODY" | jq -Rs .)"; }
its::comment_issue() { printf '%s\n' "$2" > "$GUARD_COMMENT"; }
git::submodule_list_changed() { echo "autoducks"; }
git::commit_submodule() { return 0; }
notify_failure() { :; }
status_comment::fail() { :; }
react_to_comment() { :; }

export REPO="x/y" RUN_ID="1" AUTODUCKS_AGENT="developer" AUTODUCKS_METAREPO="true"
source "$REPO_ROOT/.autoducks/core/config/metarepo.sh"

GUARD_COMMENT=$(mktemp)

# Case A — a rework task (carries the rework marker) with no declared modules.
GUARD_BODY='## Summary

fix it

<!-- autoducks:rework: feature=179 pr=200 since=2026-07-30T00:00:00Z -->'
: > "$GUARD_COMMENT"
metarepo::commit_task "82" "branch" "msg" >/dev/null 2>&1 || true

if grep -q '/engineer' "$GUARD_COMMENT"; then
  fail "rework task remediation still names /engineer (re-plans the whole feature)"
else
  pass "rework task remediation does not name /engineer"
fi
if grep -q 'Modules' "$GUARD_COMMENT"; then
  pass "remediation points at the task's own Modules field"
else
  fail "remediation never mentions the task's Modules field: $(cat "$GUARD_COMMENT")"
fi
if grep -q 'declares \*\*no\*\* ' "$GUARD_COMMENT"; then
  pass "empty declaration is diagnosed as empty, not as a mismatch"
else
  fail "empty declaration diagnosed as a mismatch: $(cat "$GUARD_COMMENT")"
fi

# Case B — a plan-derived task that declared a *different* module. Re-planning
# is a legitimate option here, because the plan is where modules were decided.
GUARD_BODY='## Summary

do it

## Modules

`autoducks-docs`

<!-- autoducks:modules: autoducks-docs -->'
: > "$GUARD_COMMENT"
metarepo::commit_task "83" "branch" "msg" >/dev/null 2>&1 || true

if grep -q '/engineer' "$GUARD_COMMENT"; then
  pass "plan-derived task still offers the re-plan route"
else
  fail "plan-derived task lost the re-plan route: $(cat "$GUARD_COMMENT")"
fi
if grep -q 'autoducks-docs' "$GUARD_COMMENT"; then
  pass "mismatch names the declared module set"
else
  fail "mismatch does not name the declared set: $(cat "$GUARD_COMMENT")"
fi

rm -f "$GUARD_COMMENT"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
