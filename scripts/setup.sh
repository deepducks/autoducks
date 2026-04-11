#!/usr/bin/env bash
# =============================================================================
# Setup / Bootstrap Script for claude-in-github
# =============================================================================
#
# PURPOSE
# -------
# Validates that the current repository is ready to run the agentic workflows,
# and creates what can be automated (labels). Things that require GitHub App
# install or org-level permissions are reported as manual checklist items.
#
# USAGE
#   ./scripts/setup.sh [--repo OWNER/REPO]
#
# CHECKS
#   1. gh CLI authentication
#   2. Required labels (meta, smoke-test, priority:P0-P3) — CREATES if missing
#   3. CLAUDE_CODE_OAUTH_TOKEN secret — reports if missing
#   4. Repository Actions workflow permissions — reports if wrong
#   5. Claude Code GitHub App installation — reports if missing
# =============================================================================

set -euo pipefail

REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
else
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
fi

if [[ -z "$REPO" ]]; then
  echo "❌ Not in a git repo and --repo not provided"
  exit 1
fi

PASS=0
FAIL=0
MANUAL=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
manual() { echo "  ⚠️  $1"; MANUAL=$((MANUAL+1)); }

echo "=== Setup check for $REPO ==="
echo ""

# --- Check 1: gh CLI auth ---
echo "[1/5] GitHub CLI authentication"
if gh auth status &>/dev/null; then
  pass "gh CLI is authenticated"
else
  fail "gh CLI is not authenticated (run: gh auth login)"
  exit 1
fi
echo ""

# --- Check 2: Labels ---
echo "[2/5] Required labels"
LABELS=("meta:6F42C1:Orchestration meta issue for implementation plans"
        "smoke-test:FFA500:Smoke test marker"
        "priority:P0:B60205:Critical path"
        "priority:P1:D93F0B:High priority"
        "priority:P2:FBCA04:Medium priority"
        "priority:P3:0E8A16:Low priority")

for entry in "${LABELS[@]}"; do
  IFS=':' read -r name color desc <<< "$entry"
  if gh label list $REPO_ARG --json name --jq '.[].name' 2>/dev/null | grep -qx "$name"; then
    pass "Label '$name' exists"
  else
    if gh label create "$name" --color "$color" --description "$desc" $REPO_ARG &>/dev/null; then
      pass "Label '$name' created"
    else
      fail "Failed to create label '$name'"
    fi
  fi
done
echo ""

# --- Check 3: Secret ---
echo "[3/5] Required secrets"
if gh secret list $REPO_ARG --json name --jq '.[].name' 2>/dev/null | grep -qx "CLAUDE_CODE_OAUTH_TOKEN"; then
  pass "Secret CLAUDE_CODE_OAUTH_TOKEN is configured"
else
  manual "Secret CLAUDE_CODE_OAUTH_TOKEN is missing

      Get your token from: https://claude.com/oauth/code
      Then add it: gh secret set CLAUDE_CODE_OAUTH_TOKEN $REPO_ARG"
fi
echo ""

# --- Check 4: Actions permissions ---
echo "[4/5] Actions workflow permissions"
PERMS=$(gh api "repos/$REPO/actions/permissions/workflow" --jq '.default_workflow_permissions + "|" + (.can_approve_pull_request_reviews | tostring)' 2>/dev/null || echo "")

if [[ -z "$PERMS" ]]; then
  manual "Could not check workflow permissions (may need org admin)"
elif [[ "$PERMS" == "write|true" ]]; then
  pass "Workflow permissions: write + can create PRs"
else
  manual "Workflow permissions need to be 'Read and write' + 'Allow GitHub Actions to create and approve pull requests'

      Try: gh api repos/$REPO/actions/permissions/workflow -X PUT -f default_workflow_permissions=write -F can_approve_pull_request_reviews=true
      If blocked by org policy, enable at: https://github.com/organizations/<ORG>/settings/actions"
fi
echo ""

# --- Check 5: Claude Code GitHub App ---
echo "[5/5] Claude Code GitHub App"
# There is no public API to list installations on a repo without proper auth.
# Best we can do is check if the workflows can authenticate — which only happens at runtime.
manual "Verify the Claude Code GitHub App is installed on this repository

      Install at: https://github.com/apps/claude
      Make sure 'All repositories' or this specific repo is selected."
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Manual:  $MANUAL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "❌ Some checks failed. Fix them and run again."
  exit 1
fi

if [[ $MANUAL -gt 0 ]]; then
  echo "⚠️  Some checks require manual action. Review the items marked ⚠️ above."
  echo ""
  echo "Once done, validate the setup by running:"
  echo "  ./scripts/smoke-test.sh --cleanup"
  exit 0
fi

echo "✅ All automated checks passed!"
echo ""
echo "Next step: run a smoke test to validate the full flow:"
echo "  ./scripts/smoke-test.sh --cleanup"
