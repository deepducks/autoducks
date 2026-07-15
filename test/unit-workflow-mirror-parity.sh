#!/usr/bin/env bash
# Drift guard: every .autoducks/runtimes/github-actions/*.yml template must be
# byte-identical to its .github/workflows/*.yml mirror (the mirror invariant
# documented in .autoducks/design/AGENTS.md). Catches an edit — such as the
# allowed_tools: resolver-output migration — applied to only one side.
# Run: bash test/unit-workflow-mirror-parity.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.autoducks/runtimes/github-actions"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "── every runtime template has a matching .github/workflows/ mirror ──"
for tmpl in "$RUNTIME_DIR"/autoducks-*.yml; do
  base="$(basename "$tmpl")"
  mirror="$WORKFLOW_DIR/$base"
  if [[ -f "$mirror" ]]; then
    pass "$base: mirror exists"
  else
    fail "$base: no mirror at $mirror"
    continue
  fi
  if cmp -s "$tmpl" "$mirror"; then
    pass "$base: template and mirror are byte-identical"
  else
    fail "$base: template and mirror differ"
    diff -u "$tmpl" "$mirror" | head -10
  fi
done

echo "── the nine LLM-backed agents resolve allowed_tools via the resolver output, not a literal ──"
LLM_AGENTS=(architect engineer developer reviewer fix resolver rework defer product)
for a in "${LLM_AGENTS[@]}"; do
  for dir in "$RUNTIME_DIR" "$WORKFLOW_DIR"; do
    f="$dir/autoducks-$a.yml"
    if grep -qF 'allowed_tools: ${{ steps.agent.outputs.tools }}' "$f"; then
      pass "$(basename "$dir")/autoducks-$a.yml: allowed_tools wired to steps.agent.outputs.tools"
    else
      fail "$(basename "$dir")/autoducks-$a.yml: allowed_tools not wired to steps.agent.outputs.tools"
    fi
    if grep -qE '^\s+allowed_tools: "' "$f"; then
      fail "$(basename "$dir")/autoducks-$a.yml: residual inline allowed_tools literal"
    else
      pass "$(basename "$dir")/autoducks-$a.yml: no residual inline literal"
    fi
  done
done

echo ""
echo "═══ workflow-mirror-parity: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
