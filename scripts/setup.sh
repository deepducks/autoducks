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
#   ./scripts/setup.sh [--repo OWNER/REPO] [--no-rename]
#
#   --no-rename   Don't auto-rename labels that collide case-insensitively
#                 with a required name (see check 2); report them as a
#                 manual item instead.
#
# CHECKS
#   1. gh CLI authentication
#   2. Required labels (feature, smoke-test, priority:P0-P3, progress) — CREATES if missing, RENAMES case collisions
#   3. LLM credential — resolves ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_BASE_URL+AUTH_TOKEN at repo or org level; reports if missing, org-blocked, or unverifiable
#   4. Repository Actions workflow permissions — reports if wrong
#   5. Claude Code GitHub App installation — reports if missing
#   6. Sub-issues API availability — probes the sub_issues endpoint; reports if unavailable
#   7. Issue types (Feature, Task) at the org level — reports if missing
#   8. Public-repo security posture — advisory for public repos without a security block
#   9. Runtime workflow sync — verifies .autoducks/runtimes match .github/workflows
#  10. Reviewer required-check ruleset — when reviewer.required_check=true, requires
#      the reviewer Check on the integration/base branch (needs repo admin)
#  11. Delivery required-check ruleset — when metarepo.enabled=true and
#      protected_submodule_strategy=required_check, requires the delivery Check
#      on the metarepo default branch (needs repo admin)
#  12. Plugin compilation sync — recomputes apply-plugins.sh's output and diffs it
#      against the committed aggregators/compiled/* artifacts; validates each
#      enabled plugin's manifest, config, and version gate; surfaces requiresSecrets
#  13. Update policy — prints the effective `update` block; confirms
#      .autoducks/.installed.json exists/parses and its version agrees with
#      .autoducks/VERSION; when enabled && mode != off, requires an identity
#      capable of pushing workflow files (vars.AUTODUCKS_APP or AUTODUCKS_PAT)
#  14. Metarepo submodule config — when metarepo.enabled=true, every
#      metarepo.submodules key must name a path declared in .gitmodules. There is
#      no inverse check: the child set is read from .gitmodules, and this block is
#      an override map, not a registry
#  15. Custom agent discovery — runs discover-agents.sh list, prints the
#      discovered agents, and fails on a non-empty errors[]
#  16. Base branch resolution — the branch autoducks acts on must exist. Fails
#      when defaults.base_branch names a branch the repo does not have, and
#      reports when it disagrees with the repository's own default branch
# =============================================================================

set -euo pipefail

REPO=""
AUTORENAME=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --no-rename) AUTORENAME=false; shift ;;
    -h|--help)
      sed -n '2,41p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$AUTORENAME" == true ]]; then
  export AUTODUCKS_LABEL_AUTORENAME=1
else
  export AUTODUCKS_LABEL_AUTORENAME=0
fi

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

ORG="${REPO%%/*}"
# "PUBLIC" | "PRIVATE" | "INTERNAL"; empty when the probe is refused.
VISIBILITY=$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null || echo "")
# Hoisted from check 7. Check 3 needs it to tell "owner is a user account"
# (no org tier exists) apart from "the org lookup was refused". Check 7 keeps
# its existing body and simply reads this value.
TYPES_JSON=$(gh api "orgs/$ORG/issue-types" 2>/dev/null || echo "")

# The repository's own default branch, and the branch autoducks will act on.
# Resolution order matches load-config.sh (#1181): the explicit override wins,
# then the repository's answer. No literal fallback — a wrong branch name that
# looks plausible is worse than an empty value the checks below can report.
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
CONFIGURED_BRANCH=$(jq -r '.defaults.base_branch // empty' .autoducks/autoducks.json 2>/dev/null || echo "")
ACTIVE_BRANCH="${CONFIGURED_BRANCH:-$DEFAULT_BRANCH}"

echo "=== Setup check for $REPO ==="
echo ""

# --- Check 1: gh CLI auth ---
echo "[1/16] GitHub CLI authentication"
if gh auth status &>/dev/null; then
  pass "gh CLI is authenticated"
else
  fail "gh CLI is not authenticated (run: gh auth login)"
  exit 1
fi
echo ""

# --- Check 2: Labels ---
echo "[2/16] Required labels"
LABELS=("Feature|6F42C1|Orchestration feature issue"
        "Bug|D73A4A|Autoducks bug pipeline"
        "Task|1D76DB|Autoducks task issue"
        "Draft|CCCCCC|Draft issue, not yet designed"
        "smoke-test|FFA500|Smoke test marker"
        "Priority:Critical|B60205|Autoducks triage priority: Critical"
        "Priority:High|D93F0B|Autoducks triage priority: High"
        "Priority:Medium|FBCA04|Autoducks triage priority: Medium"
        "Priority:Low|0E8A16|Autoducks triage priority: Low"
        "Duplicate|CFD3D7|Closed as a duplicate of another issue"
        "Autoducks:update|0366D6|Pull request opened by the automatic update agent"
        "Autoducks:breaking|E11D21|Update includes a breaking change — requires manual review before merge")

# Progress labels: sourced from progress-labels.sh so the two lists can't drift apart.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/feedback/progress-labels.sh"
LABELS+=("${AUTODUCKS_PROGRESS_LABELS[@]}")
LABELS+=("${AUTODUCKS_MODE_LABELS[@]}")

source "$SCRIPT_DIR/../.autoducks/core/config/label-utils.sh"
label::load                      # exactly one `gh label list --limit 500`

# Checks 9 and 12 delegate to the shared module so setup.sh and any future
# updater can never disagree about what "a valid machinery tree" means.
source "$SCRIPT_DIR/../.autoducks/core/robustness/verify-machinery.sh"

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$entry"
  existing="$(label::resolve "$name")"
  if [[ "$existing" == "$name" ]]; then
    pass "Label '$name' exists"
  elif [[ -n "$existing" ]]; then
    if [[ "$AUTORENAME" == true ]]; then
      if err=$(gh label edit "$existing" --repo "$REPO" --name "$name" 2>&1); then
        pass "Label '$existing' renamed to '$name' (case collision with a GitHub default; issue associations preserved)"
      else
        fail "Could not rename label '$existing' → '$name': $err"
      fi
    else
      manual "Label '$existing' collides case-insensitively with the required '$name'.
      Routing compares label names, so autoducks will not see it. Fix with:
        gh label edit '$existing' --repo $REPO --name '$name'"
    fi
  else
    if err=$(gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" 2>&1); then
      pass "Label '$name' created"
    else
      fail "Failed to create label '$name': $err"
    fi
  fi
done
echo ""

# --- Check 3: Secret ---
echo "[3/16] Required secrets"
REPO_SECRETS_OK=true
SECRET_NAMES=$(gh secret list $REPO_ARG --json name --jq '.[].name' 2>/dev/null) \
  || { REPO_SECRETS_OK=false; SECRET_NAMES=""; }
REPO_VARS_OK=true
VAR_NAMES=$(gh variable list $REPO_ARG --json name --jq '.[].name' 2>/dev/null) \
  || { REPO_VARS_OK=false; VAR_NAMES=""; }

has_secret() { [[ -n "$SECRET_NAMES" ]] && grep -qx "$1" <<< "$SECRET_NAMES"; }
has_var()    { [[ -n "$VAR_NAMES" ]]    && grep -qx "$1" <<< "$VAR_NAMES"; }

# Org-level listings, fetched once and cached. Feeds credential_source below,
# which answers where a credential name would resolve from at run time —
# repo-level, org-level, blocked by org plan, absent, or unknowable. Wired
# into check 3's branching in a later task; this task only builds the layer.
ORG_SECRETS_OK=false
ORG_SECRETS_TSV=""      # name<TAB>visibility, one per line
ORG_VARS_OK=false
ORG_VARS_TSV=""

if ORG_SECRETS_TSV=$(gh api --paginate "orgs/$ORG/actions/secrets" \
      --jq '.secrets[] | [.name, .visibility] | @tsv' 2>/dev/null); then
  ORG_SECRETS_OK=true
else
  ORG_SECRETS_TSV=""
fi

if ORG_VARS_TSV=$(gh api --paginate "orgs/$ORG/actions/variables" \
      --jq '.variables[] | [.name, .visibility] | @tsv' 2>/dev/null); then
  ORG_VARS_OK=true
else
  ORG_VARS_TSV=""
fi

# A personal account has no org tier at all. Distinguish 404-because-user from
# 404-because-forbidden so single-user repos get the clean "No LLM credential
# is configured" message instead of a confusing "could not verify".
if [[ "$ORG_SECRETS_OK" != true && -z "$TYPES_JSON" ]]; then
  OWNER_TYPE=$(gh api "users/$ORG" --jq '.type' 2>/dev/null || echo "")
  if [[ "$OWNER_TYPE" == "User" ]]; then
    ORG_SECRETS_OK=true; ORG_SECRETS_TSV=""
    ORG_VARS_OK=true;    ORG_VARS_TSV=""
  fi
fi

# "free" | "team" | "enterprise" | … ; empty when not readable (requires org owner).
ORG_PLAN=$(gh api "orgs/$ORG" --jq '.plan.name // empty' 2>/dev/null || echo "")

# org_visibility_covers <visibility> <name> <kind>   kind ∈ secrets|variables
#   0 = covers this repository, 1 = does not
org_visibility_covers() {
  local vis="$1" name="$2" kind="$3"
  case "$vis" in
    all) return 0 ;;
    private)
      # GitHub's `private` visibility means "every non-public repository",
      # which includes INTERNAL repos on Enterprise plans.
      [[ "$VISIBILITY" != "PUBLIC" ]] && return 0 || return 1 ;;
    selected)
      # Capture first, then match. Under `set -o pipefail`, `grep -q` exiting on
      # its first match while `gh` is still writing later pages kills `gh` with
      # SIGPIPE (141); piped directly, that would report a successful match as
      # "does not cover". The herestring removes the pipeline entirely.
      local repos
      repos=$(gh api --paginate "orgs/$ORG/actions/$kind/$name/repositories" \
                --jq '.repositories[].full_name' 2>/dev/null) || return 1
      grep -qxF "$REPO" <<< "$repos"
      ;;
    *) return 1 ;;
  esac
}

# credential_source <NAME> <kind>   kind ∈ secrets|variables
# echoes exactly one of: repo | org | org-blocked | none | unknown
credential_source() {
  local name="$1" kind="${2:-secrets}"
  local repo_ok org_ok org_tsv vis

  if [[ "$kind" == "variables" ]]; then
    repo_ok="$REPO_VARS_OK"; org_ok="$ORG_VARS_OK"; org_tsv="$ORG_VARS_TSV"
    has_var "$name" && { echo repo; return; }
  else
    repo_ok="$REPO_SECRETS_OK"; org_ok="$ORG_SECRETS_OK"; org_tsv="$ORG_SECRETS_TSV"
    has_secret "$name" && { echo repo; return; }
  fi

  # No repo-level hit. If the repo-level call itself failed, a repo secret may
  # exist and simply be invisible — the answer is not knowable.
  [[ "$repo_ok" != true ]] && { echo unknown; return; }
  [[ "$org_ok"  != true ]] && { echo unknown; return; }

  vis=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<< "$org_tsv")
  [[ -z "$vis" ]] && { echo none; return; }

  org_visibility_covers "$vis" "$name" "$kind" || { echo none; return; }

  # Covered on paper. Now the plan gate.
  if [[ "$VISIBILITY" == "PUBLIC" ]]; then
    echo org; return                     # plan is irrelevant for public repos
  fi
  if [[ -z "$VISIBILITY" ]]; then
    echo unknown; return                 # could not read repo visibility
  fi
  case "$ORG_PLAN" in
    free) echo org-blocked ;;            # verified: resolves EMPTY in private repos
    "")   echo unknown ;;                # plan not readable → cannot assert
    *)    echo org ;;                    # team/enterprise: org secrets reach private repos
  esac
}

# org_has <NAME> [kind]  — is there an org-level entry with this name at all?
# Deliberately ignores visibility: shadowing is about the name colliding.
org_has() {
  local name="$1" kind="${2:-secrets}" tsv
  if [[ "$kind" == "variables" ]]; then tsv="$ORG_VARS_TSV"; else tsv="$ORG_SECRETS_TSV"; fi
  awk -F'\t' -v n="$name" '$1 == n { found = 1; exit } END { exit !found }' <<< "$tsv"
}

# Any one of these authenticates the agents: the Anthropic API key, a Claude
# Code subscription token, or a custom Anthropic-compatible endpoint with its
# own credential (ANTHROPIC_BASE_URL may be a secret or a repo variable). Each
# resolves independently through credential_source, which knows about repo
# vs. org tiers, the org-plan gate on private repos, and unknowable lookups.
SRC_API_KEY=$(credential_source ANTHROPIC_API_KEY)
SRC_OAUTH=$(credential_source CLAUDE_CODE_OAUTH_TOKEN)
SRC_BASE_URL_SECRET=$(credential_source ANTHROPIC_BASE_URL)
SRC_BASE_URL_VAR=$(credential_source ANTHROPIC_BASE_URL variables)
SRC_AUTH_TOKEN=$(credential_source ANTHROPIC_AUTH_TOKEN)

# Human-readable provenance for the pass message.
where() {
  case "$1" in
    repo) echo "repository secret" ;;
    org)  echo "organization secret" ;;
    *)    echo "$1" ;;
  esac
}

# shadow_advisory <NAME> <SRC> [kind]  — informational only, never counted:
# a repo-level credential that also has an org-level entry of the same name
# will always win (env > repo > org), so the org copy silently does nothing.
shadow_advisory() {
  local name="$1" src="$2" kind="${3:-secrets}"
  if [[ "$src" == repo ]] && org_has "$name" "$kind"; then
    echo "     ℹ️  A repository-level $name shadows the organization secret of the"
    echo "         same name (precedence: environment > repository > organization)."
    echo "         An org-level rotation will not reach this repo until the repo copy is removed."
  fi
}

if [[ "$SRC_API_KEY" == repo || "$SRC_API_KEY" == org ]]; then
  pass "Secret ANTHROPIC_API_KEY is configured ($(where "$SRC_API_KEY"))"
  shadow_advisory ANTHROPIC_API_KEY "$SRC_API_KEY"
elif [[ "$SRC_OAUTH" == repo || "$SRC_OAUTH" == org ]]; then
  pass "Secret CLAUDE_CODE_OAUTH_TOKEN is configured (subscription auth) ($(where "$SRC_OAUTH"))"
  shadow_advisory CLAUDE_CODE_OAUTH_TOKEN "$SRC_OAUTH"
elif [[ "$SRC_BASE_URL_SECRET" == repo || "$SRC_BASE_URL_SECRET" == org || "$SRC_BASE_URL_VAR" == repo || "$SRC_BASE_URL_VAR" == org ]]; then
  if [[ "$SRC_AUTH_TOKEN" == repo || "$SRC_AUTH_TOKEN" == org ]]; then
    pass "Custom endpoint configured (ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN)"
    shadow_advisory ANTHROPIC_BASE_URL "$SRC_BASE_URL_SECRET"
    shadow_advisory ANTHROPIC_BASE_URL "$SRC_BASE_URL_VAR" variables
    shadow_advisory ANTHROPIC_AUTH_TOKEN "$SRC_AUTH_TOKEN"
  else
    manual "ANTHROPIC_BASE_URL is set but no credential for it

      Add the gateway's key: gh secret set ANTHROPIC_AUTH_TOKEN $REPO_ARG
      (or gh secret set ANTHROPIC_API_KEY $REPO_ARG if it authenticates via x-api-key)"
  fi
elif [[ "$SRC_API_KEY" == org-blocked || "$SRC_OAUTH" == org-blocked || "$SRC_BASE_URL_SECRET" == org-blocked || "$SRC_BASE_URL_VAR" == org-blocked || "$SRC_AUTH_TOKEN" == org-blocked ]]; then
  if [[ "$SRC_API_KEY" == org-blocked ]]; then
    BLOCKED_NAME="ANTHROPIC_API_KEY"
  elif [[ "$SRC_OAUTH" == org-blocked ]]; then
    BLOCKED_NAME="CLAUDE_CODE_OAUTH_TOKEN"
  elif [[ "$SRC_BASE_URL_SECRET" == org-blocked || "$SRC_BASE_URL_VAR" == org-blocked ]]; then
    BLOCKED_NAME="ANTHROPIC_BASE_URL"
  else
    BLOCKED_NAME="ANTHROPIC_AUTH_TOKEN"
  fi
  manual "Organization secret $BLOCKED_NAME lists this repository, but it will arrive EMPTY

      $REPO is PRIVATE and the '$ORG' organization is on the Free plan.
      Organization secrets reach public repositories only on Free; GitHub's API
      accepts adding a private repository to the selected list without any
      error, and the value then resolves empty at run time.

      Fix: add a repository-level secret, which behaves identically on public
      and private repos:
        gh secret set $BLOCKED_NAME --repo $REPO
      Or upgrade the organization to Team/Enterprise."
elif [[ "$SRC_API_KEY" == unknown || "$SRC_OAUTH" == unknown || "$SRC_BASE_URL_SECRET" == unknown || "$SRC_BASE_URL_VAR" == unknown || "$SRC_AUTH_TOKEN" == unknown ]]; then
  UNKNOWN_MSG="Could not verify the LLM credential — it may come from an organization secret

      Listing organization secrets for '$ORG' was refused. That needs org-owner
      access (classic token scope 'admin:org', or the fine-grained
      'Organization secrets: read' permission)."
  if [[ "$REPO_SECRETS_OK" == false ]]; then
    UNKNOWN_MSG="$UNKNOWN_MSG
      Listing repository secrets was also refused — that needs repo admin."
  fi
  UNKNOWN_MSG="$UNKNOWN_MSG

      If ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, or
      ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN are configured at the
      organization level, this repository is fine. Verify at:
        https://github.com/organizations/$ORG/settings/secrets/actions"
  manual "$UNKNOWN_MSG"
else
  manual "No LLM credential is configured

      Get your API key from: https://console.anthropic.com/
      Then add it: gh secret set ANTHROPIC_API_KEY $REPO_ARG

      Alternatives: CLAUDE_CODE_OAUTH_TOKEN for subscription auth, or
      ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN for a custom endpoint."
fi
echo ""

# --- Check 4: Actions permissions ---
echo "[4/16] Actions workflow permissions"
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
echo "[5/16] Claude Code GitHub App"
# There is no public API to list installations on a repo without proper auth.
# Best we can do is check if the workflows can authenticate — which only happens at runtime.
manual "Verify the Claude Code GitHub App is installed on this repository

      Install at: https://github.com/apps/claude
      Make sure 'All repositories' or this specific repo is selected."
echo ""

# --- Check 6: Sub-issues API availability ---
echo "[6/16] Sub-issues API availability"
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
echo "[7/16] Issue types (Feature, Task)"
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
  CASING_MISMATCHES=()
  for want in Feature Task; do
    if echo "$TYPES" | grep -qix "$want"; then
      echo "$TYPES" | grep -qx "$want" && continue
      actual="$(echo "$TYPES" | grep -ix "$want" | head -1)"
      CASING_MISMATCHES+=("$want (found as '$actual')")
    else
      MISSING+=("$want")
    fi
  done
  if [[ ${#MISSING[@]} -eq 0 && ${#CASING_MISMATCHES[@]} -eq 0 ]]; then
    pass "Issue types 'Feature' and 'Task' exist in org '$ORG'"
  else
    if [[ ${#CASING_MISMATCHES[@]} -gt 0 ]]; then
      manual "Issue type casing mismatch in org '$ORG': ${CASING_MISMATCHES[*]}
      Routing is label-first and unaffected, but the native issue type won't
      match by exact name. Rename at: https://github.com/organizations/$ORG/settings/issue-types"
    fi
    if [[ ${#MISSING[@]} -gt 0 ]]; then
      manual "Missing issue types in org '$ORG': ${MISSING[*]}

      Create them at: https://github.com/organizations/$ORG/settings/issue-types
      Workflows keep running without this — they just won't set the native type."
    fi
  fi
fi
echo ""

# --- Check 8: Public-repo security ---
if [[ "$VISIBILITY" == "PUBLIC" ]]; then
  echo "[8/16] Public-repo security posture"
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
echo "[9/16] Runtime workflow sync"
SYNC_OK=true
while IFS=' ' read -r kind target runtime; do
  case "$kind" in
    MISSING) fail "Missing workflow: $target (run: cp $runtime $target)"; SYNC_OK=false ;;
    DIFF)    fail "Out of sync: $target differs from $runtime"; SYNC_OK=false ;;
    ORPHAN)  fail "Orphan workflow: $target has no matching runtime template at $runtime (remove it, or add the runtime)"; SYNC_OK=false ;;
  esac
done < <(verify_machinery::check_runtime_sync)
if [[ "$SYNC_OK" == "true" ]]; then
  pass "All runtimes synced to .github/workflows/"
fi
echo ""

# --- Check 10: Reviewer required-check ruleset ---
# Opt-in (reviewer.required_check=true). Requires the reviewer's Check-run on
# the integration/base branch so a request-changes verdict blocks the merge.
# Uses the operator's own gh admin credentials (no stored PAT) and is idempotent.
echo "[10/16] Reviewer required-check ruleset"
REQUIRED_CHECK=$(jq -r '.reviewer.required_check // false' .autoducks/autoducks.json 2>/dev/null || echo "false")
if [[ "$REQUIRED_CHECK" != "true" ]]; then
  pass "Reviewer required-check disabled (reviewer.required_check=false) — nothing to enforce"
else
  CHECK_NAME=$(jq -r '.reviewer.check_name // "Autoducks: Reviewer"' .autoducks/autoducks.json 2>/dev/null)
  GATE_BRANCH=$(jq -r '.defaults.integration_branch // .defaults.base_branch // empty' .autoducks/autoducks.json 2>/dev/null)
  GATE_BRANCH="${GATE_BRANCH:-$DEFAULT_BRANCH}"
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

# --- Check 11: Delivery required-check ruleset ---
# Opt-in (metarepo.enabled=true && protected_submodule_strategy=required_check).
# Requires the delivery poller's Check-run (AUTODUCKS_DELIVERY_CHECK_NAME) on the
# metarepo default branch so a parent PR can't merge until every protected child
# has delivered. Uses the operator's own gh admin credentials (no stored PAT) and
# is idempotent — mirrors Check 10's ruleset upsert exactly.
echo "[11/16] Delivery required-check ruleset"
METAREPO_ENABLED=$(jq -r 'if .metarepo.enabled == true then "true" else "false" end' .autoducks/autoducks.json 2>/dev/null || echo "false")
METAREPO_STRATEGY=$(jq -r '.metarepo.protected_submodule_strategy // "auto_merge"' .autoducks/autoducks.json 2>/dev/null || echo "auto_merge")
if [[ "$METAREPO_ENABLED" != "true" || "$METAREPO_STRATEGY" != "required_check" ]]; then
  pass "Delivery required-check not applicable (metarepo.enabled=$METAREPO_ENABLED, protected_submodule_strategy=$METAREPO_STRATEGY) — nothing to enforce"
else
  CHECK_NAME=$(jq -r '.metarepo.delivery_check.check_name // "Autoducks: Children delivered"' .autoducks/autoducks.json 2>/dev/null)
  GATE_BRANCH=$(jq -r '.defaults.integration_branch // .defaults.base_branch // empty' .autoducks/autoducks.json 2>/dev/null)
  GATE_BRANCH="${GATE_BRANCH:-$DEFAULT_BRANCH}"
  RULESET_NAME="autoducks-delivery-required"
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
      manual "Could not create the delivery ruleset (needs repo admin).
Require the '$CHECK_NAME' status check on '$GATE_BRANCH' via Settings → Rules, or re-run setup.sh with an admin token."
    fi
  fi
fi
echo ""

# --- Check 12: Plugin compilation sync ---
# Delegates the diff-based drift detection to verify-machinery.sh's
# check_plugin_sync, which recomputes every artifact into a scratch dir via
# apply-plugins.sh's dry-run interface (AUTODUCKS_APPLY_PLUGINS_OUTPUT_ROOT)
# and diffs it against the committed aggregators/compiled/* files. The
# compiler itself performs manifest, configSchema, version-gate, and
# merge-conflict/collision validation and dies with an actionable message on
# any of those — we just surface that failure. requiresSecrets checklist
# surfacing stays here since it's a setup-only concern.
echo "[12/16] Plugin compilation sync"
COMPILER=".autoducks/core/config/apply-plugins.sh"
if [[ ! -f "$COMPILER" ]]; then
  manual "Plugin compiler not found at $COMPILER — skipping plugin compilation sync"
else
  SYNC_OK=true
  COMPILE_FAILED=false
  while IFS=' ' read -r kind rest; do
    case "$kind" in
      MISSING) fail "Plugin artifact missing from repo: $rest is produced by plugins[] but not committed (run: bash $COMPILER)"; SYNC_OK=false ;;
      STALE)   fail "Stale plugin artifact: $rest is out of sync with plugins[] (run: bash $COMPILER)"; SYNC_OK=false ;;
      ORPHAN)  fail "Stale plugin artifact: $rest is committed but no longer produced by plugins[] (run: bash $COMPILER)"; SYNC_OK=false ;;
      COMPILER_FAILED) fail "Plugin compiler failed — a plugin manifest, config, or merge is invalid: $rest"; SYNC_OK=false; COMPILE_FAILED=true ;;
      COMPILER_MISSING) fail "Plugin compiler not found at $COMPILER"; SYNC_OK=false; COMPILE_FAILED=true ;;
    esac
  done < <(verify_machinery::check_plugin_sync)

  if [[ "$SYNC_OK" == "true" ]]; then
    pass "Plugin compiler output matches committed artifacts"
  fi

  if [[ "$COMPILE_FAILED" == "false" ]]; then
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
  fi
fi
echo ""

# --- Check 13: Update policy ---
# GITHUB_TOKEN cannot write .github/workflows/ files (D#952-style guard), so
# when the update agent is enabled and not manual-only, some other identity
# must be able to push the machinery PR/branch: either the autoducks GitHub
# App (vars.AUTODUCKS_APP) or a repository AUTODUCKS_PAT secret.
echo "[13/16] Update policy"
UPDATE_JSON=$(jq -c '.update // {}' .autoducks/autoducks.json 2>/dev/null || echo "{}")
echo "  Effective update block: $UPDATE_JSON"

if [[ -f ".autoducks/.installed.json" ]] && jq -e . ".autoducks/.installed.json" >/dev/null 2>&1; then
  pass ".autoducks/.installed.json exists and parses"
else
  manual ".autoducks/.installed.json is missing or does not parse as JSON

      This lockfile is written by scripts/install.sh; without it the update
      agent cannot detect drift. Re-run the installer:
        curl -fsSL https://raw.githubusercontent.com/deepducks/autoducks/main/scripts/install.sh | bash"
fi

VERSION_FILE_VALUE=$(cat .autoducks/VERSION 2>/dev/null || echo "")
LOCKFILE_VERSION=$(jq -r '.version // empty' .autoducks/.installed.json 2>/dev/null || echo "")
if [[ -z "$VERSION_FILE_VALUE" || -z "$LOCKFILE_VERSION" ]]; then
  manual "Could not compare .autoducks/VERSION ('$VERSION_FILE_VALUE') to the lockfile version ('$LOCKFILE_VERSION') — one or both are missing"
elif [[ "$VERSION_FILE_VALUE" == "$LOCKFILE_VERSION" ]]; then
  pass ".autoducks/VERSION ($VERSION_FILE_VALUE) matches the lockfile version"
else
  manual ".autoducks/VERSION ($VERSION_FILE_VALUE) does not match the lockfile version ($LOCKFILE_VERSION)

      This usually means machinery files were copied in manually without
      running the installer. Re-run scripts/install.sh to reconcile."
fi

UPDATE_ENABLED=$(jq -r 'if .update.enabled == false then "false" else "true" end' .autoducks/autoducks.json 2>/dev/null || echo "true")
UPDATE_MODE=$(jq -r '.update.mode // "pr"' .autoducks/autoducks.json 2>/dev/null || echo "pr")
if [[ "$UPDATE_ENABLED" == "true" && "$UPDATE_MODE" != "off" ]]; then
  if has_var "AUTODUCKS_APP" || has_secret "AUTODUCKS_PAT"; then
    pass "An identity capable of pushing workflow files is configured (vars.AUTODUCKS_APP or AUTODUCKS_PAT)"
  else
    manual "update.enabled=true and update.mode=$UPDATE_MODE, but no identity can push workflow files

      GITHUB_TOKEN cannot write .github/workflows/ — the update agent needs either:
        the autoducks GitHub App installed (sets vars.AUTODUCKS_APP), or
        gh secret set AUTODUCKS_PAT $REPO_ARG   (a PAT with 'workflow' scope)"
  fi
else
  pass "Update policy disabled or manual (enabled=$UPDATE_ENABLED, mode=$UPDATE_MODE) — no push identity required"
fi
echo ""

# --- Check 14: Metarepo submodule config ---
# `metarepo.submodules` is keyed by submodule path, and nothing used to notice
# when a key stopped matching `.gitmodules` — a child could be retired and its
# key linger indefinitely, reading like live config. `.gitmodules` is the same
# source of truth parse-plan.py validates `**Modules:**` against.
echo "[14/16] Metarepo submodule config"
METAREPO_ON=$(jq -r 'if .metarepo.enabled == true then "true" else "false" end' \
                .autoducks/autoducks.json 2>/dev/null || echo "false")
if [[ "$METAREPO_ON" != "true" ]]; then
  pass "Not a metarepo (metarepo.enabled != true) — nothing to validate"
elif [[ ! -f ".gitmodules" ]]; then
  fail "metarepo.enabled=true but no .gitmodules in the repo root
    Metarepo mode expects the children to be git submodules. Either add them
    with 'git submodule add', or set metarepo.enabled=false."
else
  # shellcheck source=/dev/null
  AUTODUCKS_ROOT=".autoducks" source .autoducks/core/config/metarepo.sh

  if STALE=$(AUTODUCKS_ROOT=".autoducks" metarepo::stale_submodule_keys); then
    pass "Every metarepo.submodules key names a declared submodule"
  else
    fail "metarepo.submodules key(s) with no submodule behind them: $(printf '%s' "$STALE" | tr '\n' ' ')
    Every key under metarepo.submodules must name a path declared in
    .gitmodules. Remove the stale key(s), or add the submodule back."
  fi

  # No inverse check on purpose. The child set comes from .gitmodules, not from
  # here; metarepo.submodules is an override map whose only key, `protected`,
  # defaults to "detect at runtime". Asking for an entry per submodule would ask
  # for config that states nothing.
fi
echo ""

# --- Check 15: Custom agent discovery ---
# Runs the discover-agents.sh registry scan (precedence across
# .autoducks/custom/agents, .claude/agents, .agents, .github/agents, and any
# custom_agents.roots[]) and surfaces what it finds. A non-empty errors[]
# means at least one definition was refused (bad name, reserved name,
# oversized, empty body, unreadable, or a symlinked definition) — fail so the
# operator fixes it before the definition is silently unusable at runtime.
#
# This runs with no AUTODUCKS_BASE_REF, so discovery reads the working tree
# while the runtime reads the default branch. Without the mergeability warning
# below the two disagree in the most confusing possible way: setup says
# "discovered", and the agent then answers "no custom agent named <name> was
# found" for a file the operator is looking at on disk.
echo "[15/16] Custom agent discovery"
DISCOVER_AGENTS="$SCRIPT_DIR/../.autoducks/core/config/discover-agents.sh"
if [[ ! -f "$DISCOVER_AGENTS" ]]; then
  manual "Custom agent discovery script not found at $DISCOVER_AGENTS — skipping"
else
  REGISTRY_JSON="$(bash "$DISCOVER_AGENTS" list 2>&1)" || true
  if ! jq -e . >/dev/null 2>&1 <<<"$REGISTRY_JSON"; then
    fail "discover-agents.sh list did not produce valid JSON: $REGISTRY_JSON"
  else
    AGENT_COUNT=$(jq '.agents | length' <<<"$REGISTRY_JSON")
    ERROR_COUNT=$(jq '.errors | length' <<<"$REGISTRY_JSON")
    if [[ "$AGENT_COUNT" -eq 0 ]]; then
      pass "No custom agent definitions found"
    else
      pass "Discovered $AGENT_COUNT custom agent definition(s):"
      # Resolve the default branch once. With no origin/HEAD — no remote, or a
      # clone that never fetched — there is nothing to compare against, so the
      # mergeability annotation is simply omitted.
      DEFAULT_REF=""
      if _dh="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
        DEFAULT_REF="${_dh#refs/remotes/}"
      fi
      UNMERGED=0
      while IFS=$'\t' read -r _name _source _shadowed; do
        [[ -n "$_name" ]] || continue
        _note=""
        [[ "$_shadowed" == "true" ]] && _note=" [shadowed]"
        if [[ -n "$DEFAULT_REF" ]]; then
          if ! git cat-file -e "$DEFAULT_REF:$_source" 2>/dev/null; then
            _note="$_note  ← not on $DEFAULT_REF, will NOT run"
            UNMERGED=$((UNMERGED + 1))
          elif ! git diff --quiet "$DEFAULT_REF" -- "$_source" 2>/dev/null; then
            _note="$_note  ← differs from $DEFAULT_REF, the merged body runs"
            UNMERGED=$((UNMERGED + 1))
          fi
        fi
        printf '      - %s (%s)%s\n' "$_name" "$_source" "$_note"
      done < <(jq -r '.agents[] | [.name, .source, (.shadowed // false)] | @tsv' <<<"$REGISTRY_JSON")
      if [[ "$UNMERGED" -gt 0 ]]; then
        # Deliberately `manual`, not `fail`: authoring a definition on a branch
        # is a legitimate intermediate state. What the operator needs is to know
        # that this check reads the working tree while the runtime reads the
        # default branch, so "discovered" here does not mean "runnable" there.
        manual "$UNMERGED custom agent definition(s) are not merged on $DEFAULT_REF — the runtime reads definitions from the default branch, so they will not run (or will run an older body) until merged"
      fi
    fi
    if [[ "$ERROR_COUNT" -gt 0 ]]; then
      fail "$ERROR_COUNT custom agent definition(s) failed validation:"
      jq -r '.errors[] | "      - \(.source): \(.reason)"' <<<"$REGISTRY_JSON"
    fi
  fi
fi
echo ""

# --- Check 16: Base branch resolution ---
# The check that would have caught deepducks/swanapse (#1181): a fork of an
# upstream using `master`, whose config declared `main` — a branch it has never
# had — while GitHub's default was a third name again. Nothing reported it,
# because every consumer of the value silently accepted whatever it got.
echo "[16/16] Base branch resolution"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  manual "Could not read the repository's default branch (gh refused or offline) — skipping the branch checks"
else
  if [[ -n "$CONFIGURED_BRANCH" ]]; then
    if gh api "repos/$REPO/branches/$CONFIGURED_BRANCH" --jq '.name' >/dev/null 2>&1; then
      if [[ "$CONFIGURED_BRANCH" == "$DEFAULT_BRANCH" ]]; then
        pass "defaults.base_branch '$CONFIGURED_BRANCH' matches the repository default branch"
      else
        # Legitimate — a repo can deliberately run its pipeline off a branch
        # that is not the GitHub default. Worth saying out loud, because the
        # two are read by different parts of the machinery.
        manual "defaults.base_branch is '$CONFIGURED_BRANCH' but the repository default branch is '$DEFAULT_BRANCH'.
      Both are used: agent lanes follow the configured value, while the custom-agent
      lane reads definitions from the repository default. Align them unless the split
      is deliberate."
      fi
    else
      fail "defaults.base_branch names '$CONFIGURED_BRANCH', which is not a branch of $REPO.
      Every lane that creates or targets a branch will act on a ref that does not exist.
      Set it to '$DEFAULT_BRANCH', or drop the key to follow the repository default."
    fi
  else
    pass "No defaults.base_branch override; following the repository default branch '$DEFAULT_BRANCH'"
  fi
  # Nothing should still be resolving to a hardcoded literal.
  if [[ -n "$ACTIVE_BRANCH" ]]; then
    pass "Effective base branch: '$ACTIVE_BRANCH'"
  else
    fail "Could not resolve a base branch from either the config or the repository"
  fi
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
