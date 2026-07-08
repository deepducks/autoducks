#!/usr/bin/env bash
# Static hook-contract test for the 8 workflow templates + their 8
# .github/workflows/ mirrors (16 files total).
# Run: bash test/unit-hook-steps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/.autoducks/runtimes" "$SCRATCH/.github"
cp -R "$REPO_ROOT/.autoducks/runtimes/github-actions" "$SCRATCH/.autoducks/runtimes/"
cp -R "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/"

RUNTIME_DIR="$SCRATCH/.autoducks/runtimes/github-actions"
WORKFLOW_DIR="$SCRATCH/.github/workflows"

AGENTS=(architect close developer engineer fix maestro revert reviewer)
LLM_AGENTS=(architect developer engineer fix reviewer)
BASH_AGENTS=(close maestro revert)

# get_block FILE STEP_NAME — print the lines of the named step (from its
# "- name:" line up to, but not including, the next step's "- name:" line).
get_block() {
  local file="$1" name="$2"
  awk -v n="      - name: $name" '
    $0 == n { grab = 1; print; next }
    grab && /^      - name:/ { exit }
    grab { print }
  ' "$file"
}

# ── Atomic contract checks (reused for both the real files and the seeded
# violation below, so a broken checker would fail to catch the seed too) ──

check_pre_guard() { # $1 = file, $2 = agent
  get_block "$1" "User pre hook" | grep -qF "hashFiles('.github/actions/autoducks/$2-pre/action.yml') != ''"
}
check_pre_uses() {
  get_block "$1" "User pre hook" | grep -qF "uses: ./.github/actions/autoducks/$2-pre"
}
check_post_guard() {
  get_block "$1" "User post hook" | grep -qF "hashFiles('.github/actions/autoducks/$2-post/action.yml') != ''"
}
check_post_uses() {
  get_block "$1" "User post hook" | grep -qF "uses: ./.github/actions/autoducks/$2-post"
}
check_post_always() {
  get_block "$1" "User post hook" | grep -qF "always() &&"
}
check_post_agent_outcome() {
  get_block "$1" "User post hook" | grep -qF "AGENT_OUTCOME:"
}
check_pre_stage() {
  get_block "$1" "User pre hook" | grep -qF "AUTODUCKS_STAGE: pre"
}
check_post_stage() {
  get_block "$1" "User post hook" | grep -qF "AUTODUCKS_STAGE: post"
}

echo "── per-agent hook contract (templates + mirrors) ──"
for agent in "${AGENTS[@]}"; do
  bn="autoducks-$agent.yml"
  for dir in "$RUNTIME_DIR" "$WORKFLOW_DIR"; do
    file="$dir/$bn"
    label="$(basename "$dir")/$bn"

    check_pre_guard "$file" "$agent" && pass "$label: pre hashFiles guard" || fail "$label: pre hashFiles guard missing"
    check_pre_uses "$file" "$agent" && pass "$label: pre uses path" || fail "$label: pre uses path missing"
    check_post_guard "$file" "$agent" && pass "$label: post hashFiles guard" || fail "$label: post hashFiles guard missing"
    check_post_uses "$file" "$agent" && pass "$label: post uses path" || fail "$label: post uses path missing"
    check_post_always "$file" && pass "$label: post hook gated by always()" || fail "$label: post hook missing always()"
    check_pre_stage "$file" && pass "$label: pre hook sets AUTODUCKS_STAGE: pre" || fail "$label: pre hook missing AUTODUCKS_STAGE: pre"
    check_post_stage "$file" && pass "$label: post hook sets AUTODUCKS_STAGE: post" || fail "$label: post hook missing AUTODUCKS_STAGE: post"
    check_post_agent_outcome "$file" && pass "$label: post hook has AGENT_OUTCOME:" || fail "$label: post hook missing AGENT_OUTCOME:"

    hooks_region="$(get_block "$file" "User pre hook")"$'\n'"$(get_block "$file" "User post hook")"
    if [[ "$agent" == "developer" ]]; then
      echo "$hooks_region" | grep -q "duplicate_skip" && pass "$label: developer hooks gate on duplicate_skip" || fail "$label: developer hooks missing duplicate_skip"
      echo "$hooks_region" | grep -q "dor_skip" && pass "$label: developer hooks gate on dor_skip" || fail "$label: developer hooks missing dor_skip"
      grep -q "BASE_BRANCH:" "$file" && pass "$label: developer has BASE_BRANCH:" || fail "$label: developer missing BASE_BRANCH:"
    fi
    if [[ "$agent" == "engineer" ]]; then
      echo "$hooks_region" | grep -q "dor_skip" && pass "$label: engineer hooks gate on dor_skip" || fail "$label: engineer hooks missing dor_skip"
    fi
    if [[ "$agent" == "reviewer" ]]; then
      grep -q "IS_PR:" "$file" && pass "$label: reviewer has IS_PR:" || fail "$label: reviewer missing IS_PR:"
    fi

    if [[ " ${LLM_AGENTS[*]} " == *" $agent "* ]]; then
      grep -qE '^ +id: llm$' "$file" && pass "$label: LLM workflow has id: llm" || fail "$label: LLM workflow missing id: llm"
    fi
    if [[ " ${BASH_AGENTS[*]} " == *" $agent "* ]]; then
      grep -qE '^ +id: run$' "$file" && pass "$label: bash workflow has id: run" || fail "$label: bash workflow missing id: run"
    fi

    if [[ "$agent" == "maestro" ]]; then
      orch_line="$(grep -n '^  orchestrate:$' "$file" | head -1 | cut -d: -f1)"
      pre_line="$(grep -n '^      - name: User pre hook$' "$file" | head -1 | cut -d: -f1)"
      post_line="$(grep -n '^      - name: User post hook$' "$file" | head -1 | cut -d: -f1)"
      if [[ -n "$orch_line" && -n "$pre_line" && -n "$post_line" && "$orch_line" -lt "$pre_line" && "$orch_line" -lt "$post_line" ]]; then
        pass "$label: maestro hooks appear after orchestrate:"
      else
        fail "$label: maestro hooks do not appear after orchestrate:"
      fi
    fi
  done
done

echo "── template == mirror ──"
for agent in "${AGENTS[@]}"; do
  bn="autoducks-$agent.yml"
  if diff -q "$RUNTIME_DIR/$bn" "$WORKFLOW_DIR/$bn" >/dev/null; then
    pass "$bn: template matches mirror"
  else
    fail "$bn: template and mirror diverge"
  fi
done

echo "── YAML validity ──"
if python3 -c 'import yaml' 2>/dev/null; then
  for file in "$RUNTIME_DIR"/*.yml "$WORKFLOW_DIR"/*.yml; do
    if python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$file" 2>/dev/null; then
      pass "$(basename "$(dirname "$file")")/$(basename "$file"): valid YAML"
    else
      fail "$(basename "$(dirname "$file")")/$(basename "$file"): invalid YAML"
    fi
  done
else
  echo "  ⚠️  python3/pyyaml not available — skipping YAML-parse checks"
fi

echo "── seeded contract violation is caught ──"
SEED_FILE="$SCRATCH/seeded-developer.yml"
cp "$RUNTIME_DIR/autoducks-developer.yml" "$SEED_FILE"
sed -i.bak "/hashFiles('.github\/actions\/autoducks\/developer-post\/action.yml') != ''/d" "$SEED_FILE"
rm -f "$SEED_FILE.bak"
if check_post_guard "$SEED_FILE" "developer"; then
  fail "seeded missing -post guard was NOT detected by the checker"
else
  pass "seeded missing -post guard correctly caught"
fi

echo ""
echo "═══ hook-steps: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
