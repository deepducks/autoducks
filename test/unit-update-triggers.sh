#!/usr/bin/env bash
# Integration tests for scripts/update-triggers.sh (guard regeneration)
# Run: bash test/unit-update-triggers.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Isolated repo copy: only what update-triggers touches/needs
mkdir -p "$SCRATCH/.autoducks/core/config" "$SCRATCH/.autoducks/runtimes" \
         "$SCRATCH/.github" "$SCRATCH/scripts"
cp "$REPO_ROOT/.autoducks/autoducks.json" "$SCRATCH/.autoducks/"
cp "$REPO_ROOT/.autoducks/core/config/generate-trigger-conditions.sh" "$SCRATCH/.autoducks/core/config/"
cp -R "$REPO_ROOT/.autoducks/runtimes/github-actions" "$SCRATCH/.autoducks/runtimes/"
cp -R "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/"
cp "$REPO_ROOT/scripts/update-triggers.sh" "$SCRATCH/scripts/"

run() { (cd "$SCRATCH" && bash scripts/update-triggers.sh >/dev/null); }

echo "── idempotence with shipped config ──"
run
cp -R "$SCRATCH/.github/workflows" "$SCRATCH/wf-before"
run
if diff -r "$SCRATCH/wf-before" "$SCRATCH/.github/workflows" >/dev/null; then
  pass "second run is byte-identical"
else
  fail "second run changed files"
fi
if diff -r "$SCRATCH/.github/workflows" "$SCRATCH/.autoducks/runtimes/github-actions" >/dev/null; then
  pass "workflows mirror runtime templates"
else
  fail "mirror out of sync"
fi

echo "── shipped config reproduces committed guards ──"
if diff -r "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/workflows" >/dev/null; then
  pass "regenerated guards match the committed workflows"
else
  fail "regenerated guards differ from committed workflows"
  diff -r "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/workflows" | head -10
fi

echo "── reviewer guard fires on both issue and PR comments ──"
if grep -q "startsWith(github.event.comment.body, '/review')" "$SCRATCH/.github/workflows/autoducks-reviewer.yml"; then
  pass "reviewer guard matches /review"
else
  fail "reviewer guard missing /review match"
fi
if grep -q "github.event.issue.pull_request == null" "$SCRATCH/.github/workflows/autoducks-reviewer.yml"; then
  fail "reviewer guard incorrectly restricted to issues only (pull_request == null)"
else
  pass "reviewer guard omits pull_request == null (fires on issues and PRs)"
fi
if grep -q "github.event.issue.pull_request == null" "$SCRATCH/.github/workflows/autoducks-architect.yml"; then
  pass "architect guard retains pull_request == null (issue-only contrast)"
else
  fail "architect guard unexpectedly missing pull_request == null"
fi

echo "── custom aliases are baked into guards ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["engineer"] = ["blueprint"]
cfg["triggers"]["execute"] = ["ship"]
cfg["triggers"]["fix"] = ["mend"]
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "'/blueprint'" "$SCRATCH/.github/workflows/autoducks-engineer.yml" \
  && pass "engineer custom alias in engineer guard" || fail "blueprint missing"
grep -q "'/ship'" "$SCRATCH/.github/workflows/autoducks-engineer.yml" \
  && pass "execute custom alias in engineer routing branch" || fail "ship missing in engineer"
grep -q "'/ship'" "$SCRATCH/.github/workflows/autoducks-maestro.yml" \
  && pass "execute custom alias in maestro guard" || fail "ship missing in maestro"
grep -q "'/ship'" "$SCRATCH/.github/workflows/autoducks-developer.yml" \
  && pass "execute custom alias in developer guard" || fail "ship missing in developer"
grep -q "'/mend'" "$SCRATCH/.github/workflows/autoducks-fix.yml" \
  && pass "fix custom alias in fix guard" || fail "mend missing"

echo "── custom prefix is baked into guards ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["command"] = "/duck"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "'/duck execute'" "$SCRATCH/.github/workflows/autoducks-developer.yml" \
  && pass "custom prefix in developer guard" || fail "custom prefix missing"
if grep -q "'/quack " "$SCRATCH/.github/workflows/autoducks-developer.yml"; then
  fail "old prefix left behind in developer guard"
else
  pass "old prefix fully replaced"
fi

echo "── bare-word namespace bakes two-token guards ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["command"] = "quack"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "'/quack execute'" "$SCRATCH/.github/workflows/autoducks-developer.yml" \
  && pass "bare-word namespace baked as two-token /quack form" || fail "bare-word namespace not baked"

echo "── invalid alias is rejected before baking ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["fix"] = ["Bad Alias!"]
json.dump(cfg, open(p, "w"), indent=2)
EOF
if run 2>/dev/null; then
  fail "invalid alias accepted"
else
  pass "invalid alias rejected (hard error)"
fi

echo ""
echo "═══ update-triggers: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
