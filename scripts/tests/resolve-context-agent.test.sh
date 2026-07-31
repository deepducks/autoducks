#!/usr/bin/env bash
# Offline unit tests for the "agent" lane added to
# .autoducks/core/context/resolve-context.sh (issue #157).
#
# Fakes its::/git:: at the function level (no gh/git/network calls) and
# sources the real resolve-context.sh (which in turn sources the real
# context-parts.sh / design-sections.sh — pure text-processing modules with
# no external calls at source time). Run via scripts/tests/run.sh, or
# directly: bash scripts/tests/resolve-context-agent.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AUTODUCKS_ROOT="$REPO_ROOT/.autoducks"

PASS=0
FAIL=0
pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

TMP_DIRS=()
cleanup() {
  local d
  if [[ ${#TMP_DIRS[@]} -gt 0 ]]; then
    for d in "${TMP_DIRS[@]}"; do
      rm -rf "$d"
    done
  fi
}
trap cleanup EXIT

# Creates a fixture dir and registers it for cleanup. Must be called plain
# (not via `D="$(new_cfg_dir)"`) — a command-substitution call runs the
# function in a subshell, so its TMP_DIRS append is lost and nothing gets
# cleaned up. Call it plain, then read $NEW_CFG_DIR.
new_cfg_dir() {
  NEW_CFG_DIR="$(mktemp -d)"
  TMP_DIRS+=("$NEW_CFG_DIR")
}

# ── Fakes for the its::/git:: provider interface ────────────────────────
declare -A FAKE_ISSUE=()      # issue_num -> JSON {title, body, labels, type, author}
declare -A FAKE_COMMENTS=()   # issue_num -> JSON array
declare -A FAKE_PR=()         # pr_num -> JSON {title, baseRefName, headRefName, state}
declare -A FAKE_PR_DIFF=()    # pr_num -> diff text

its::get_issue() {
  local n="$1"
  printf '%s' "${FAKE_ISSUE[$n]:-{\}}"
}
its::list_comments() {
  local n="$1"
  printf '%s' "${FAKE_COMMENTS[$n]:-[]}"
}
git::get_pr() {
  local n="$1"
  printf '%s' "${FAKE_PR[$n]:-{\}}"
}
git::get_pr_diff() {
  local n="$1"
  printf '%s' "${FAKE_PR_DIFF[$n]:-}"
}

source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"

FAKE_ISSUE[1]='{"title":"Agent lane title","body":"Agent lane body.","labels":["bug"],"type":"Bug","author":"alice"}'
FAKE_COMMENTS[1]='[{"author":"bob","body":"a comment"}]'

reset_tmp_outputs() {
  rm -f /tmp/context-manifest.json /tmp/issue-request.md /tmp/issue-body-raw.md \
        /tmp/issue-comments.md /tmp/issue-meta.md /tmp/task-spec.md \
        /tmp/task-criteria.md /tmp/pr-diff.patch /tmp/pr-meta.md \
        /tmp/security-guidelines.md /tmp/tactical-zone-current.md /tmp/design-zone.md
}

# -----------------------------------------------------------------------
echo "1) 'agent' is accepted by the guard and _resolve_context::available_parts has the full catalog"
GOT_AVAIL="$(_resolve_context::available_parts agent | tr ' ' '\n' | sort | tr '\n' ' ')"
WANT_AVAIL="$(printf '%s\n' issue_title issue_description issue_comments issue_metadata task_title task_description task_criteria prior_feedback pr_diff pr_meta security_guidelines plan design.full | sort | tr '\n' ' ')"
if [[ "$GOT_AVAIL" == "$WANT_AVAIL" ]]; then
  pass "available_parts(agent) is exactly the full catalog"
else
  fail "available_parts(agent) mismatch: got [$GOT_AVAIL] want [$WANT_AVAIL]"
fi

GOT_DEFAULT="$(_resolve_context::default_parts agent | tr '\n' ' ')"
if [[ "$GOT_DEFAULT" == "issue_title issue_description issue_comments " ]]; then
  pass "default_parts(agent) is issue_title issue_description issue_comments"
else
  fail "default_parts(agent) mismatch: got [$GOT_DEFAULT]"
fi

# -----------------------------------------------------------------------
echo "2) resolve_context agent <n> (no caller list, no autoducks.json key) succeeds via defaults"
reset_tmp_outputs
new_cfg_dir; D="$NEW_CFG_DIR"; echo '{}' > "$D/autoducks.json"
RC=0
AUTODUCKS_ROOT="$D" resolve_context agent 1 >/tmp/_rc-agent-stdout.txt 2>/tmp/_rc-agent-stderr.txt || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "resolve_context agent 1 returns 0"
else
  fail "resolve_context agent 1 returned $RC: $(cat /tmp/_rc-agent-stderr.txt)"
fi
if [[ -f /tmp/context-manifest.json ]]; then
  MANIFEST_AGENT="$(jq -r '.agent' /tmp/context-manifest.json)"
  if [[ "$MANIFEST_AGENT" == "agent" ]]; then
    pass "/tmp/context-manifest.json's agent field is 'agent'"
  else
    fail "manifest agent field wrong: $MANIFEST_AGENT"
  fi
  PARTS_IDS="$(jq -r '[.parts[].id] | sort | join(",")' /tmp/context-manifest.json)"
  if [[ "$PARTS_IDS" == "issue_comments,issue_description,issue_title" ]]; then
    pass "default selection (issue_title, issue_description, issue_comments) materialized"
  else
    fail "unexpected parts recorded for default agent selection: $PARTS_IDS"
  fi
else
  fail "/tmp/context-manifest.json was not written"
fi
if [[ -f /tmp/issue-request.md ]] && grep -q "Agent lane title" /tmp/issue-request.md && grep -q "Agent lane body." /tmp/issue-request.md; then
  pass "issue_title/issue_description composed into /tmp/issue-request.md"
else
  fail "/tmp/issue-request.md missing or wrong content"
fi

# -----------------------------------------------------------------------
echo "3) a frontmatter-sourced (caller-supplied) unavailable part warns, is dropped, and still returns 0"
reset_tmp_outputs
new_cfg_dir; D="$NEW_CFG_DIR"; echo '{}' > "$D/autoducks.json"
RC=0
AUTODUCKS_ROOT="$D" resolve_context agent 1 1 "issue_title totally_bogus_part" \
  >/tmp/_rc-agent-stdout.txt 2>/tmp/_rc-agent-stderr.txt || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "caller-supplied unavailable part: resolve_context still returns 0"
else
  fail "caller-supplied unavailable part: expected rc=0, got $RC"
fi
if grep -q "::warning::" /tmp/_rc-agent-stderr.txt && grep -q "totally_bogus_part" /tmp/_rc-agent-stderr.txt; then
  pass "caller-supplied unavailable part emits a ::warning:: naming the part"
else
  fail "no ::warning:: for the unavailable part: $(cat /tmp/_rc-agent-stderr.txt)"
fi
PARTS_IDS="$(jq -r '[.parts[].id] | sort | join(",")' /tmp/context-manifest.json)"
if [[ "$PARTS_IDS" == "issue_title" ]]; then
  pass "only the valid part (issue_title) was materialized/recorded; the bogus one was dropped"
else
  fail "expected only issue_title recorded, got: $PARTS_IDS"
fi

# -----------------------------------------------------------------------
echo "4) an autoducks.json-sourced unavailable part still hard-fails with the existing message shape"
reset_tmp_outputs
new_cfg_dir; D="$NEW_CFG_DIR"
echo '{"context":{"agent":{"parts":["totally_bogus_part"]}}}' > "$D/autoducks.json"
RC=0
AUTODUCKS_ROOT="$D" resolve_context agent 1 >/tmp/_rc-agent-stdout.txt 2>/tmp/_rc-agent-stderr.txt || RC=$?
if [[ "$RC" -eq 1 ]]; then
  pass "autoducks.json-sourced unavailable part: resolve_context returns 1"
else
  fail "autoducks.json-sourced unavailable part: expected rc=1, got $RC"
fi
if grep -q "unknown or not available to agent 'agent'" /tmp/_rc-agent-stderr.txt \
   && grep -q '\.context\.agent\.parts' /tmp/_rc-agent-stderr.txt \
   && ! grep -q "::warning::" /tmp/_rc-agent-stderr.txt; then
  pass "hard-fail message keeps the existing shape (Fix: ... .context.agent.parts ...), no ::warning::"
else
  fail "hard-fail message shape wrong: $(cat /tmp/_rc-agent-stderr.txt)"
fi

# -----------------------------------------------------------------------
echo "5) an explicit empty caller-supplied part list materializes nothing and records an empty parts array"
reset_tmp_outputs
new_cfg_dir; D="$NEW_CFG_DIR"; echo '{}' > "$D/autoducks.json"
RC=0
AUTODUCKS_ROOT="$D" resolve_context agent 1 1 "" >/tmp/_rc-agent-stdout.txt 2>/tmp/_rc-agent-stderr.txt || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "explicit empty caller-supplied list: resolve_context returns 0"
else
  fail "explicit empty caller-supplied list: expected rc=0, got $RC"
fi
PARTS_JSON="$(jq -c '.parts' /tmp/context-manifest.json)"
if [[ "$PARTS_JSON" == "[]" ]]; then
  pass "manifest records an empty parts array"
else
  fail "expected empty parts array, got: $PARTS_JSON"
fi
if [[ ! -f /tmp/issue-request.md ]] && [[ ! -f /tmp/issue-comments.md ]]; then
  pass "nothing was materialized for an explicit empty selection"
else
  fail "something was materialized despite an explicit empty selection"
fi

# -----------------------------------------------------------------------
echo "6) route_agent materializes every full-catalog part to its canonical /tmp target"
reset_tmp_outputs
new_cfg_dir; D="$NEW_CFG_DIR"; echo '{}' > "$D/autoducks.json"
FAKE_ISSUE[2]='{"title":"Feature body","body":"Feature body text for #2","labels":[],"type":"Feature","author":"carol"}'
FAKE_PR[5]='{"title":"My PR","baseRefName":"main","headRefName":"feature/x","state":"OPEN"}'
FAKE_PR_DIFF[5]='diff --git a/x.txt b/x.txt
+hello
'
ALL_PARTS="issue_title issue_description issue_comments issue_metadata task_title task_description task_criteria prior_feedback pr_diff pr_meta security_guidelines plan design.full"
RC=0
AUTODUCKS_ROOT="$D" resolve_context agent 5 2 "$ALL_PARTS" \
  >/tmp/_rc-agent-stdout.txt 2>/tmp/_rc-agent-stderr.txt || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "full-catalog selection returns 0"
else
  fail "full-catalog selection returned $RC: $(cat /tmp/_rc-agent-stderr.txt)"
fi
[[ -f /tmp/pr-diff.patch ]] && grep -q "hello" /tmp/pr-diff.patch && pass "pr_diff -> /tmp/pr-diff.patch" || fail "pr_diff target missing/wrong"
[[ -f /tmp/pr-meta.md ]] && grep -q "My PR" /tmp/pr-meta.md && pass "pr_meta -> /tmp/pr-meta.md" || fail "pr_meta target missing/wrong"
[[ -f /tmp/security-guidelines.md ]] && pass "security_guidelines -> /tmp/security-guidelines.md (empty is fine, absent guideline file)" || fail "security_guidelines target missing"
[[ -f /tmp/task-criteria.md ]] && pass "task_criteria -> /tmp/task-criteria.md" || fail "task_criteria target missing"
MANIFEST_IDS="$(jq -r '[.parts[].id] | sort | join(",")' /tmp/context-manifest.json)"
if [[ "$MANIFEST_IDS" == *"pr_diff"* && "$MANIFEST_IDS" == *"pr_meta"* && "$MANIFEST_IDS" == *"security_guidelines"* ]]; then
  pass "manifest records the full-catalog selection"
else
  fail "manifest missing expected ids: $MANIFEST_IDS"
fi

# -----------------------------------------------------------------------
echo ""
echo "=== resolve-context agent lane (offline): $PASS passed, $FAIL failed ==="
rm -f /tmp/_rc-agent-stdout.txt /tmp/_rc-agent-stderr.txt
[[ "$FAIL" -eq 0 ]] || exit 1
