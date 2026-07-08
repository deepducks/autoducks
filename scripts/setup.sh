#!/usr/bin/env bash
# =============================================================================
# Setup / Bootstrap Script for autoducks
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
#   2. Required labels (feature, smoke-test, priority:P0-P3, progress) — CREATES if missing
#   3. CLAUDE_CODE_OAUTH_TOKEN secret — reports if missing
#   4. Repository Actions workflow permissions — reports if wrong
#   5. Claude Code GitHub App installation — reports if missing
#   6. Sub-issues API availability — probes the sub_issues endpoint; reports if unavailable
#   7. Issue types (Feature, Task) at the org level — reports if missing
#   8. Public-repo security posture — advisory for public repos without a security block
#   9. Runtime workflow sync — verifies .autoducks/runtimes match .github/workflows
# =============================================================================

set -euo pipefail

REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0"
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
echo "[1/9] GitHub CLI authentication"
if gh auth status &>/dev/null; then
  pass "gh CLI is authenticated"
else
  fail "gh CLI is not authenticated (run: gh auth login)"
  exit 1
fi
echo ""

# --- Check 2: Labels ---
echo "[2/9] Required labels"
LABELS=("Feature|6F42C1|Orchestration feature issue"
        "Bug|D73A4A|Autoducks bug pipeline"
        "Task|1D76DB|Autoducks task issue"
        "Draft|CCCCCC|Draft issue, not yet designed"
        "smoke-test|FFA500|Smoke test marker")

# Progress labels: sourced from progress-labels.sh so the two lists can't drift apart.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/feedback/progress-labels.sh"
LABELS+=("${AUTODUCKS_PROGRESS_LABELS[@]}")

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$entry"
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
echo "[3/9] Required secrets"
if gh secret list $REPO_ARG --json name --jq '.[].name' 2>/dev/null | grep -qx "ANTHROPIC_API_KEY"; then
  pass "Secret ANTHROPIC_API_KEY is configured"
else
  manual "Secret ANTHROPIC_API_KEY is missing

      Get your API key from: https://console.anthropic.com/
      Then add it: gh secret set ANTHROPIC_API_KEY $REPO_ARG"
fi
echo ""

# --- Check 4: Actions permissions ---
echo "[4/9] Actions workflow permissions"
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
echo "[5/9] Claude Code GitHub App"
# There is no public API to list installations on a repo without proper auth.
# Best we can do is check if the workflows can authenticate — which only happens at runtime.
manual "Verify the Claude Code GitHub App is installed on this repository

      Install at: https://github.com/apps/claude
      Make sure 'All repositories' or this specific repo is selected."
echo ""

# --- Check 6: Sub-issues API availability ---
echo "[6/9] Sub-issues API availability"
# Probe against an arbitrary issue in the repo. If the repo has zero issues,
# the check is inconclusive — report a soft manual item.
FIRST_ISSUE=$(gh issue list $REPO_ARG --state all --limit 1 --json number \
              --jq '.[0].number // empty' 2>/dev/null || echo "")
if [[ -z "$FIRST_ISSUE" ]]; then
  manual "Sub-issues API check skipped — repository has no issues to probe.
      Re-run scripts/setup.sh after your first issue exists, or trust the
      Engineer agent's runtime probe to report the state on the first
      \`/engineer\` run."
else
  HTTP=$(gh api "repos/$REPO/issues/$FIRST_ISSUE/sub_issues" \
         --include -H "Accept: application/vnd.github+json" 2>/dev/null \
         | awk 'NR==1 { print $2 }' || echo "")
  case "${HTTP:-}" in
    2*) pass "Sub-issues API is available on $REPO" ;;
    401|403) manual "Sub-issues API responded 401/403 — token needs 'issues:write'." ;;
    404|410) manual "Sub-issues API responded 404 — the feature is not enabled for this repository.
      The Engineer agent will fall back to the markdown-based '## Progress' checklist.
      This is not fatal; native linking is a UX enhancement." ;;
    *) manual "Sub-issues API probe was inconclusive (HTTP ${HTTP:-none}).
      Autoducks will still function; native linking may or may not work." ;;
  esac
fi
echo ""

# --- Check 7: Issue types (Feature, Task) ---
# Issue types are an org-level feature. Workflows degrade gracefully if
# types aren't configured — the type parameter is silently ignored by the
# API. But without them, typed feature/task relationships don't render.
echo "[7/9] Issue types (Feature, Task)"
ORG=$(echo "$REPO" | cut -d/ -f1)
TYPES_JSON=$(gh api "orgs/$ORG/issue-types" 2>/dev/null || echo "")
if [[ -z "$TYPES_JSON" ]]; then
  manual "Could not list issue types for org '$ORG' (not an org, or no admin access).
      If '$ORG' is a user account, types are only available under organizations.
      If it's an org and you're not an admin, ask an admin to define them.
      Routing is label-first: the Engineer and Architect agents automatically apply the
      \`Feature\` label, so no manual labeling is needed. The native issue type is a
      visual enhancement for org repos and is not required for routing."
else
  TYPES=$(echo "$TYPES_JSON" | jq -r '.[].name')
  MISSING=()
  echo "$TYPES" | grep -qx "Feature" || MISSING+=("Feature")
  echo "$TYPES" | grep -qx "Task"    || MISSING+=("Task")
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    pass "Issue types 'Feature' and 'Task' exist in org '$ORG'"
  else
    manual "Missing issue types in org '$ORG': ${MISSING[*]}

      Create them at: https://github.com/organizations/$ORG/settings/issue-types
      Workflows keep running without this — they just won't set the native type."
  fi
fi
echo ""

# --- Check 8: Public-repo security ---
VISIBILITY=$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null || echo "")
if [[ "$VISIBILITY" == "PUBLIC" ]]; then
  echo "[8/9] Public-repo security posture"
  HAS_SEC=$(jq -r '.security != null' .autoducks/autoducks.json 2>/dev/null || echo "false")
  if [[ "$HAS_SEC" == "true" ]]; then
    pass "security block present in .autoducks/autoducks.json"
  else
    manual "Repository is PUBLIC but .autoducks/autoducks.json has no 'security' block.
         Defaults will allow only OWNER/MEMBER/COLLABORATOR to trigger agents.
         Review docs at https://autoducks.openvibes.tech/reference/security/ to tighten or loosen."
  fi
  echo ""
fi

# --- Check 9: Runtime sync ---
echo "[9/9] Runtime workflow sync"
SYNC_OK=true
for runtime in .autoducks/runtimes/github-actions/autoducks-*.yml; do
  bn=$(basename "$runtime")
  target=".github/workflows/$bn"
  if [[ ! -f "$target" ]]; then
    fail "Missing workflow: $target (run: cp $runtime $target)"
    SYNC_OK=false
  elif ! diff -q "$runtime" "$target" &>/dev/null; then
    fail "Out of sync: $target differs from $runtime"
    SYNC_OK=false
  fi
done
if [[ "$SYNC_OK" == "true" ]]; then
  pass "All runtimes synced to .github/workflows/"
fi
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
  echo "  scripts/smoke-test.sh --cleanup"
  exit 0
fi

echo "All automated checks passed!"
echo ""
echo "Next step: run a smoke test to validate the full flow:"
echo "  scripts/smoke-test.sh --cleanup"
