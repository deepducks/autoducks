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
#  10. Reviewer required-check ruleset — when reviewer.required_check=true, requires
#      the reviewer Check on the integration/base branch (needs repo admin)
#  11. Plugin compilation sync — recomputes apply-plugins.sh's output and diffs it
#      against the committed aggregators/compiled/* artifacts; validates each
#      enabled plugin's manifest, config, and version gate; surfaces requiresSecrets
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
echo "[1/11] GitHub CLI authentication"
if gh auth status &>/dev/null; then
  pass "gh CLI is authenticated"
else
  fail "gh CLI is not authenticated (run: gh auth login)"
  exit 1
fi
echo ""

# --- Check 2: Labels ---
echo "[2/11] Required labels"
LABELS=("Feature|6F42C1|Orchestration feature issue"
        "Bug|D73A4A|Autoducks bug pipeline"
        "Task|1D76DB|Autoducks task issue"
        "Draft|CCCCCC|Draft issue, not yet designed"
        "smoke-test|FFA500|Smoke test marker"
        "Priority:Critical|B60205|Autoducks triage priority: Critical"
        "Priority:High|D93F0B|Autoducks triage priority: High"
        "Priority:Medium|FBCA04|Autoducks triage priority: Medium"
        "Priority:Low|0E8A16|Autoducks triage priority: Low"
        "Duplicate|CFD3D7|Closed as a duplicate of another issue")

# Progress labels: sourced from progress-labels.sh so the two lists can't drift apart.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/feedback/progress-labels.sh"
LABELS+=("${AUTODUCKS_PROGRESS_LABELS[@]}")
LABELS+=("${AUTODUCKS_MODE_LABELS[@]}")

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
echo "[3/11] Required secrets"
if gh secret list $REPO_ARG --json name --jq '.[].name' 2>/dev/null | grep -qx "ANTHROPIC_API_KEY"; then
  pass "Secret ANTHROPIC_API_KEY is configured"
else
  manual "Secret ANTHROPIC_API_KEY is missing

      Get your API key from: https://console.anthropic.com/
      Then add it: gh secret set ANTHROPIC_API_KEY $REPO_ARG"
fi
echo ""

# --- Check 4: Actions permissions ---
echo "[4/11] Actions workflow permissions"
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
echo "[5/11] Claude Code GitHub App"
# There is no public API to list installations on a repo without proper auth.
# Best we can do is check if the workflows can authenticate — which only happens at runtime.
manual "Verify the Claude Code GitHub App is installed on this repository

      Install at: https://github.com/apps/claude
      Make sure 'All repositories' or this specific repo is selected."
echo ""

# --- Check 6: Sub-issues API availability ---
echo "[6/11] Sub-issues API availability"
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
echo "[7/11] Issue types (Feature, Task)"
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
  echo "[8/11] Public-repo security posture"
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
echo "[9/11] Runtime workflow sync"
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

# --- Check 10: Reviewer required-check ruleset ---
# Opt-in (reviewer.required_check=true). Requires the reviewer's Check-run on
# the integration/base branch so a request-changes verdict blocks the merge.
# Uses the operator's own gh admin credentials (no stored PAT) and is idempotent.
echo "[10/11] Reviewer required-check ruleset"
REQUIRED_CHECK=$(jq -r '.reviewer.required_check // false' .autoducks/autoducks.json 2>/dev/null || echo "false")
if [[ "$REQUIRED_CHECK" != "true" ]]; then
  pass "Reviewer required-check disabled (reviewer.required_check=false) — nothing to enforce"
else
  CHECK_NAME=$(jq -r '.reviewer.check_name // "Autoducks: Reviewer"' .autoducks/autoducks.json 2>/dev/null)
  GATE_BRANCH=$(jq -r '.defaults.integration_branch // .defaults.base_branch // "main"' .autoducks/autoducks.json 2>/dev/null)
  RULESET_NAME="autoducks-reviewer-required"
  PAYLOAD=$(jq -n \
    --arg name "$RULESET_NAME" \
    --arg ref "refs/heads/$GATE_BRANCH" \
    --arg ctx "$CHECK_NAME" \
    '{
      name: $name,
      target: "branch",
      enforcement: "active",
      conditions: { ref_name: { include: [$ref], exclude: [] } },
      rules: [ {
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: false,
          required_status_checks: [ { context: $ctx } ]
        }
      } ]
    }')
  EXISTING_ID=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null | head -1 || echo "")
  if [[ -n "$EXISTING_ID" ]]; then
    if printf '%s' "$PAYLOAD" | gh api "repos/$REPO/rulesets/$EXISTING_ID" --method PUT --input - >/dev/null 2>&1; then
      pass "Ruleset '$RULESET_NAME' updated — '$CHECK_NAME' required on '$GATE_BRANCH'"
    else
      manual "Could not update ruleset '$RULESET_NAME' (needs repo admin).
Re-run setup.sh with an admin token, or set the '$CHECK_NAME' required check on '$GATE_BRANCH' via Settings → Rules."
    fi
  else
    if printf '%s' "$PAYLOAD" | gh api "repos/$REPO/rulesets" --method POST --input - >/dev/null 2>&1; then
      pass "Ruleset '$RULESET_NAME' created — '$CHECK_NAME' required on '$GATE_BRANCH'"
    else
      manual "Could not create the reviewer ruleset (needs repo admin).
Require the '$CHECK_NAME' status check on '$GATE_BRANCH' via Settings → Rules, or re-run setup.sh with an admin token."
    fi
  fi
fi
echo ""

# --- Check 11: Plugin compilation sync ---
# Mirrors check 9's diff-based drift detection, but for the plugin compiler:
# recompute every artifact into a scratch dir via apply-plugins.sh's dry-run
# interface (AUTODUCKS_APPLY_PLUGINS_OUTPUT_ROOT) and diff it against the
# committed aggregators/compiled/* files. The compiler itself performs manifest,
# configSchema, version-gate, and merge-conflict/collision validation and dies
# with an actionable message on any of those — we just surface that failure.
echo "[11/11] Plugin compilation sync"
COMPILER=".autoducks/core/config/apply-plugins.sh"
if [[ ! -f "$COMPILER" ]]; then
  manual "Plugin compiler not found at $COMPILER — skipping plugin compilation sync"
else
  DRYRUN_ROOT="$(mktemp -d)"
  COMPILE_LOG="$(mktemp)"
  if AUTODUCKS_APPLY_PLUGINS_OUTPUT_ROOT="$DRYRUN_ROOT" bash "$COMPILER" >"$COMPILE_LOG" 2>&1; then
    SYNC_OK=true

    # Every recomputed artifact must match its committed counterpart byte-for-byte.
    while IFS= read -r -d '' f; do
      rel="${f#"$DRYRUN_ROOT"/}"
      if [[ ! -f "$rel" ]]; then
        fail "Plugin artifact missing from repo: $rel is produced by plugins[] but not committed (run: bash $COMPILER)"
        SYNC_OK=false
      elif ! diff -q "$f" "$rel" &>/dev/null; then
        fail "Stale plugin artifact: $rel is out of sync with plugins[] (run: bash $COMPILER)"
        SYNC_OK=false
      fi
    done < <(find "$DRYRUN_ROOT" -type f -print0)

    # A committed generated artifact with no recomputed counterpart is orphaned
    # (e.g. a plugin/hook was removed from plugins[] but never recompiled).
    for agg in .github/actions/autoducks/*/action.yml; do
      [[ -f "$agg" ]] || continue
      head -n1 "$agg" | grep -qF "GENERATED BY autoducks apply-plugins.sh" || continue
      if [[ ! -f "$DRYRUN_ROOT/$agg" ]]; then
        fail "Stale plugin artifact: $agg is committed but no longer produced by plugins[] (run: bash $COMPILER)"
        SYNC_OK=false
      fi
    done
    for f in .autoducks/providers/llm/claude/compiled/*.settings.json .autoducks/providers/llm/claude/compiled/*.allowed-tools; do
      [[ -f "$f" ]] || continue
      if [[ ! -f "$DRYRUN_ROOT/$f" ]]; then
        fail "Stale plugin artifact: $f is committed but no longer produced by plugins[] (run: bash $COMPILER)"
        SYNC_OK=false
      fi
    done

    if [[ "$SYNC_OK" == "true" ]]; then
      pass "Plugin compiler output matches committed artifacts"
    fi

    # Surface each enabled plugin's requiresSecrets as a manual checklist item.
    while IFS= read -r entry; do
      pname="$(jq -r '.name' <<< "$entry")"
      psource="$(jq -r '.source' <<< "$entry")"
      case "$psource" in
        ./*) pdir="${psource#./}" ;;
        .autoducks/plugins/*) pdir="$psource" ;;
        github:*) pdir=".autoducks/plugins/$pname" ;;
        *) pdir="" ;;
      esac
      if [[ -n "$pdir" && -f "$pdir/plugin.json" ]]; then
        secrets="$(jq -r '.requiresSecrets // [] | join(", ")' "$pdir/plugin.json")"
        [[ -n "$secrets" ]] && manual "Plugin '$pname' requires secrets: $secrets — verify they are configured (gh secret set <NAME> $REPO_ARG)"
      fi
    done < <(jq -c '.plugins // [] | .[]' .autoducks/autoducks.json 2>/dev/null || true)
  else
    fail "Plugin compiler failed — a plugin manifest, config, or merge is invalid: $(tail -n 3 "$COMPILE_LOG" | tr '\n' ' ')"
  fi
  rm -rf "$DRYRUN_ROOT"
  rm -f "$COMPILE_LOG"
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
