#!/usr/bin/env bash
# Integration test for the nine LLM-backed workflows' migration from an
# inline `allowed_tools:` literal to `${{ steps.agent.outputs.tools }}`
# (the `Load agent defaults` step / load-agent-defaults.sh resolver).
#
# Verifies, against the real shipped .autoducks/agents/*/defaults.json and
# .autoducks/autoducks.json config, that every one of the nine agents:
#   - resolves to a non-empty tools set,
#   - includes the universal WebFetch + WebSearch grant, and
#   - retains its pre-migration base tokens verbatim (spot-checked below).
# Run: bash test/unit-workflow-tools-resolution.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/load-agent-defaults.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

AGENTS=(architect engineer developer reviewer fix resolver rework defer product)

resolve_tools() {
  AUTODUCKS_AGENT="$1" AUTODUCKS_ROOT="$REPO_ROOT/.autoducks" bash "$SCRIPT" | sed -n 's/^tools=//p'
}

has_token() {
  # has_token CSV TOKEN — exact-match membership test on a comma-separated set.
  local csv="$1" token="$2"
  IFS=',' read -ra _fields <<< "$csv"
  local _f
  for _f in "${_fields[@]}"; do
    [[ "$_f" == "$token" ]] && return 0
  done
  return 1
}

echo "── every LLM agent resolves to a non-empty tools set ──"
for a in "${AGENTS[@]}"; do
  GOT="$(resolve_tools "$a")"
  [[ -n "$GOT" ]] && pass "$a: non-empty tools" || fail "$a: tools resolved empty"
done

echo "── every LLM agent's effective set includes WebFetch + WebSearch ──"
for a in "${AGENTS[@]}"; do
  GOT="$(resolve_tools "$a")"
  if has_token "$GOT" "WebFetch" && has_token "$GOT" "WebSearch"; then
    pass "$a: includes WebFetch + WebSearch"
  else
    fail "$a: missing WebFetch/WebSearch in [$GOT]"
  fi
done

echo "── migrated base tokens survive verbatim ──"
ARCHITECT_TOOLS="$(resolve_tools architect)"
if has_token "$ARCHITECT_TOOLS" "Bash(git log:*)"; then
  pass "architect: retains Bash(git log:*)"
else
  fail "architect: lost Bash(git log:*) — [$ARCHITECT_TOOLS]"
fi

DEVELOPER_TOOLS="$(resolve_tools developer)"
if has_token "$DEVELOPER_TOOLS" "Bash"; then
  pass "developer: retains unrestricted Bash"
else
  fail "developer: lost unrestricted Bash — [$DEVELOPER_TOOLS]"
fi

echo "── each agent's full pre-migration base is a subset of its resolved set ──"
declare -A BASE_TOOLS=(
  [architect]="Read,Write,Edit,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [engineer]="Read,Write,Glob,Grep,Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [developer]="Read,Write,Edit,Bash"
  [reviewer]="Read,Grep,Glob,Write,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [fix]="Read,Write,Edit,Bash,Glob,Grep"
  [resolver]="Read,Grep,Glob,Edit,Write,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [rework]="Read,Grep,Glob,Write,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [defer]="Read,Grep,Glob,Write,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
  [product]="Read,Grep,Glob,Write,Bash(read-only),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git diff:*),Bash(git status:*),Bash(git branch --list:*),Bash(git rev-parse:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*)"
)
for a in "${AGENTS[@]}"; do
  GOT="$(resolve_tools "$a")"
  MISSING=()
  IFS=',' read -ra _base <<< "${BASE_TOOLS[$a]}"
  for _t in "${_base[@]}"; do
    has_token "$GOT" "$_t" || MISSING+=("$_t")
  done
  if [[ "${#MISSING[@]}" -eq 0 ]]; then
    pass "$a: full pre-migration base preserved"
  else
    fail "$a: missing base tokens: ${MISSING[*]}"
  fi
done

echo ""
echo "═══ workflow-tools-resolution: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
