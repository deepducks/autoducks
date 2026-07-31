#!/usr/bin/env bash
# Static contract test for the child→parent gitlink sync (#170).
# Run: bash test/unit-metarepo-sync-steps.sh
#
# Two things drift silently and this pins both: an agent workflow added later
# that forgets the pre-agent sync step, and the sync step losing the token
# fallback chain that lets it push from a read-mostly agent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.autoducks/runtimes/github-actions"
# Deliberately NOT under runtimes/github-actions/: unit-install-copy.sh asserts
# that dir mirrors .github/workflows/ with `diff -r`, and a subdirectory the
# installer does not copy breaks that invariant.
ACTION="$REPO_ROOT/.autoducks/actions/metarepo-gitlink-sync/action.yml"
SYNC_WF="$RUNTIME_DIR/autoducks-metarepo-sync.yml"
SCRIPT="$REPO_ROOT/.autoducks/core/orchestration/sync-child-gitlinks.sh"

# The same roster unit-hook-steps.sh pins.
AGENTS=(architect close defer developer engineer fix maestro product resolver revert reviewer rework)

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "── the pieces exist ──"

for f in "$ACTION" "$SYNC_WF" "$SCRIPT"; do
  if [[ -f "$f" ]]; then
    pass "$(basename "$(dirname "$f")")/$(basename "$f") exists"
  else
    fail "missing $f"
  fi
done

if bash -n "$SCRIPT" 2>/dev/null; then
  pass "sync-child-gitlinks.sh parses"
else
  fail "sync-child-gitlinks.sh has a syntax error"
fi

# ---------------------------------------------------------------------------
echo "── every agent workflow carries the pre-agent sync ──"

for a in "${AGENTS[@]}"; do
  wf="$RUNTIME_DIR/autoducks-$a.yml"
  if [[ ! -f "$wf" ]]; then
    fail "$a: workflow missing"
    continue
  fi

  n=$(grep -c 'uses: ./.autoducks/actions/metarepo-gitlink-sync' "$wf" || true)
  if [[ "$n" -eq 1 ]]; then
    pass "$a: has exactly one sync step"
  else
    fail "$a: expected 1 sync step, found $n"
    continue
  fi

  # It must come after the checkout — a local composite action cannot be
  # resolved before the repo is on disk.
  co=$(grep -n 'uses: actions/checkout' "$wf" | head -1 | cut -d: -f1)
  sy=$(grep -n 'actions/metarepo-gitlink-sync' "$wf" | head -1 | cut -d: -f1)
  if [[ -n "$co" && -n "$sy" && "$sy" -gt "$co" ]]; then
    pass "$a: sync runs after checkout"
  else
    fail "$a: sync at line ${sy:-?} does not follow checkout at line ${co:-?}"
  fi

  # Four agents (architect, defer, product, reviewer) deliberately lack
  # `contents: write`. The push works there only because the app token and the
  # PAT are not bound by the workflow's permissions block — so the fallback
  # chain is load-bearing, not boilerplate.
  if grep -A4 'actions/metarepo-gitlink-sync' "$wf" \
       | grep -qF 'steps.apptoken.outputs.value || secrets.AUTODUCKS_PAT || secrets.GITHUB_TOKEN'; then
    pass "$a: sync uses the full token fallback chain"
  else
    fail "$a: sync is missing the app-token/PAT/GITHUB_TOKEN fallback"
  fi
done

# ---------------------------------------------------------------------------
echo "── the scheduled workflow ──"

if grep -q '^  workflow_dispatch:$' "$SYNC_WF"; then
  pass "sync workflow can be dispatched by hand"
else
  fail "sync workflow has no workflow_dispatch trigger"
fi

# autoducks is not itself a metarepo, so the shipped template carries no
# `schedule:` — the baker strips it, exactly as it does for a consumer who sets
# product.enabled=false. What has to hold is that a metarepo consumer gets one
# back. Assert the round trip rather than the committed shape.
if grep -q '^on:$' "$SYNC_WF"; then
  pass "sync workflow has the `on:` anchor the baker reinserts under"
else
  fail "sync workflow has no bare `on:` line for patch_metarepo_sync_cron to find"
fi

if grep -q '^  schedule:$' "$SYNC_WF"; then
  fail "shipped template carries a live schedule despite metarepo.enabled=false"
else
  pass "shipped template carries no schedule (autoducks is not a metarepo)"
fi

BAKE="$(mktemp -d)"
trap 'rm -rf "$BAKE"' EXIT
mkdir -p "$BAKE/.autoducks/core" "$BAKE/.autoducks/runtimes" "$BAKE/.github" "$BAKE/scripts"
cp "$REPO_ROOT/.autoducks/autoducks.json" "$BAKE/.autoducks/"
cp -R "$REPO_ROOT/.autoducks/core/config" "$BAKE/.autoducks/core/"
cp -R "$REPO_ROOT/.autoducks/runtimes/github-actions" "$BAKE/.autoducks/runtimes/"
cp -R "$REPO_ROOT/.github/workflows" "$BAKE/.github/"
cp "$REPO_ROOT/scripts/update-triggers.sh" "$BAKE/scripts/"

jq '.metarepo.enabled = true | .metarepo.sync_schedule = "42 * * * *"' \
  "$BAKE/.autoducks/autoducks.json" > "$BAKE/t" && mv "$BAKE/t" "$BAKE/.autoducks/autoducks.json"
( cd "$BAKE" && bash scripts/update-triggers.sh >/dev/null 2>&1 ) || true

baked_wf="$BAKE/.autoducks/runtimes/github-actions/autoducks-metarepo-sync.yml"
baked_mirror="$BAKE/.github/workflows/autoducks-metarepo-sync.yml"
if grep -q "cron: '42 \* \* \* \*'" "$baked_wf"; then
  pass "metarepo.enabled=true bakes sync_schedule back into the template"
else
  fail "the cron was not reinserted for a metarepo consumer"
fi
if [[ -f "$baked_mirror" ]] && diff -q "$baked_wf" "$baked_mirror" >/dev/null; then
  pass "the baked template and its mirror stay identical"
else
  fail "template and mirror diverged after baking"
fi

# Second run must not move it again, or verify-machinery's idempotence check
# fails on every consumer.
cp "$baked_wf" "$BAKE/before.yml"
( cd "$BAKE" && bash scripts/update-triggers.sh >/dev/null 2>&1 ) || true
if diff -q "$BAKE/before.yml" "$baked_wf" >/dev/null; then
  pass "baking is idempotent"
else
  fail "a second bake changed the workflow"
fi

if grep -q 'patch_metarepo_sync_cron' "$REPO_ROOT/scripts/update-triggers.sh"; then
  pass "update-triggers.sh defines and calls the baker"
else
  fail "update-triggers.sh does not bake metarepo.sync_schedule"
fi

if [[ "$(jq -r '.metarepo.sync_schedule // empty' "$REPO_ROOT/.autoducks/autoducks.json")" != "" ]]; then
  pass "autoducks.json scaffolds metarepo.sync_schedule"
else
  fail "autoducks.json has no metarepo.sync_schedule default"
fi

# ---------------------------------------------------------------------------
echo "── the composite action cannot clobber the agent's workspace ──"

# The whole reason the action clones: reconcile_gitlinks does `git checkout -B`.
if grep -q 'git clone' "$ACTION"; then
  pass "action reconciles in a clone"
else
  fail "action does not clone — it would checkout over the agent's tree"
fi

if grep -q 'mktemp -d' "$ACTION" && grep -q "trap 'rm -rf" "$ACTION"; then
  pass "the clone is a temp dir and is cleaned up"
else
  fail "the clone is not a cleaned-up temp dir"
fi

# The reset must be fenced behind an equality test against the default branch,
# or the resolver's PR-head checkout gets silently retargeted.
if grep -q 'git reset --quiet --hard' "$ACTION"; then
  if grep -B6 'git reset --quiet --hard' "$ACTION" | grep -q 'current" != "\$default_branch'; then
    pass "the workspace reset is gated on already being on the default branch"
  else
    fail "the workspace reset is not gated — it could retarget the resolver"
  fi
else
  fail "action never refreshes the workspace"
fi

for guard in 'if \[\[ ! -f .gitmodules \]\]' 'metarepo.enabled == true'; do
  if grep -qE "$guard" "$ACTION"; then
    pass "action is inert outside metarepo mode ($guard)"
  else
    fail "action is missing its inert-outside-metarepo guard ($guard)"
  fi
done

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
