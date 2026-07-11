#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/snapshot-machinery.sh
# Run: bash test/unit-snapshot-machinery.sh
#
# Proves the bug #952 guarantee: the machinery snapshot is materialised from the
# pipeline's cut commit (merge-base with the base branch), so edits an agent
# makes to .autoducks on its own branch never reach the snapshot that runs the
# build — and that a repo without a resolvable pin falls back to the live tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/.autoducks/core/robustness/snapshot-machinery.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

git config --global user.email >/dev/null 2>&1 || git config --global user.email "test@autoducks"
git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "autoducks test"

# ── Fixture: base commit on main carries marker BASE; the feature branch then
#    "corrupts" the machinery (marker BRANCH + a rewritten post.sh). ──────────
git init -q --bare "$SCRATCH/origin.git"
git clone -q "$SCRATCH/origin.git" "$SCRATCH/work"
cd "$SCRATCH/work"
mkdir -p .autoducks/agents/developer
printf '{"defaults":{"base_branch":"main"},"marker":"BASE"}\n' > .autoducks/autoducks.json
printf 'echo clean\n' > .autoducks/agents/developer/post.sh
git add -A && git commit -qm "base machinery"
git branch -M main
git push -q origin main

git checkout -qb feature/1-selfmod
printf '{"defaults":{"base_branch":"main"},"marker":"BRANCH"}\n' > .autoducks/autoducks.json
printf 'exit 0  # corrupted mid-edit\n' > .autoducks/agents/developer/post.sh
git add -A && git commit -qm "agent corrupts machinery on its own branch"

echo "── pin resolves to the cut commit (base), not the branch tip ──"
RT="$SCRATCH/rt"; GENV="$SCRATCH/genv"; : > "$GENV"
( cd "$SCRATCH/work" && RUNNER_TEMP="$RT" GITHUB_ENV="$GENV" bash "$HELPER" >/dev/null 2>&1 )

SNAP_CFG="$RT/autoducks-snapshot/.autoducks/autoducks.json"
if [[ -f "$SNAP_CFG" ]] && grep -q '"marker":"BASE"' "$SNAP_CFG"; then
  pass "snapshot autoducks.json is the BASE version"
else
  fail "snapshot autoducks.json is not the pinned BASE version ($(cat "$SNAP_CFG" 2>/dev/null))"
fi

if grep -q 'echo clean' "$RT/autoducks-snapshot/.autoducks/agents/developer/post.sh" 2>/dev/null; then
  pass "snapshot post.sh is the clean BASE version (not the branch's corrupted one)"
else
  fail "snapshot post.sh reflects the branch's corrupted edit — pin failed"
fi

if grep -q '^AUTODUCKS_PINNED_ROOT=' "$GENV"; then
  pass "AUTODUCKS_PINNED_ROOT exported to GITHUB_ENV"
else
  fail "AUTODUCKS_PINNED_ROOT not exported to GITHUB_ENV"
fi

echo "── fallback: no resolvable pin → snapshot the current tree ──"
git clone -q "$SCRATCH/work" "$SCRATCH/noremote"   # clone, then drop origin so no base is fetchable
cd "$SCRATCH/noremote"
git remote remove origin 2>/dev/null || true
# leave the working tree's marker as the branch's (BRANCH) to prove fallback copies live
printf '{"defaults":{"base_branch":"main"},"marker":"LIVE"}\n' > .autoducks/autoducks.json
RT2="$SCRATCH/rt2"; : > "$SCRATCH/genv2"
( cd "$SCRATCH/noremote" && RUNNER_TEMP="$RT2" GITHUB_ENV="$SCRATCH/genv2" bash "$HELPER" >/dev/null 2>&1 )
if grep -q '"marker":"LIVE"' "$RT2/autoducks-snapshot/.autoducks/autoducks.json" 2>/dev/null; then
  pass "fallback snapshots the live working tree when no pin resolves"
else
  fail "fallback did not snapshot the live tree"
fi

echo ""
echo "═══ snapshot-machinery: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
