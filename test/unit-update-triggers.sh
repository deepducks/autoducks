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
mkdir -p "$SCRATCH/.autoducks/core" "$SCRATCH/.autoducks/runtimes" \
         "$SCRATCH/.github" "$SCRATCH/scripts"
cp "$REPO_ROOT/.autoducks/autoducks.json" "$SCRATCH/.autoducks/"
# Whole config dir: the generator sources siblings (agent-roster.sh), and a
# hand-maintained file list here breaks the fixture as the tree grows.
cp -R "$REPO_ROOT/.autoducks/core/config" "$SCRATCH/.autoducks/core/"
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
# Mirror invariant covers the installable autoducks-*.yml templates only; the
# repo may carry its own non-autoducks workflows (e.g. ci-*.yml) that have no
# runtime counterpart.
_mirror_ok=1
for _wf in "$SCRATCH/.autoducks/runtimes/github-actions/"autoducks-*.yml; do
  cmp -s "$_wf" "$SCRATCH/.github/workflows/$(basename "$_wf")" || _mirror_ok=0
done
if [[ "$_mirror_ok" -eq 1 ]]; then
  pass "workflows mirror runtime templates"
else
  fail "mirror out of sync"
fi

echo "── hook steps survive guard regeneration ──"
if grep -q "uses: ./.github/actions/autoducks/developer-pre" "$SCRATCH/.github/workflows/autoducks-developer.yml"; then
  pass "developer-pre hook uses: line survives regeneration"
else
  fail "developer-pre hook uses: line lost during regeneration"
fi
if grep -q "uses: ./.github/actions/autoducks/developer-post" "$SCRATCH/.github/workflows/autoducks-developer.yml"; then
  pass "developer-post hook uses: line survives regeneration"
else
  fail "developer-post hook uses: line lost during regeneration"
fi
if grep -q "uses: ./.github/actions/autoducks/maestro-post" "$SCRATCH/.github/workflows/autoducks-maestro.yml"; then
  pass "maestro-post hook uses: line survives regeneration"
else
  fail "maestro-post hook uses: line lost during regeneration"
fi
CLOSE_GUARD_COUNT="$(grep -c "hashFiles('.github/actions/autoducks/close-" "$SCRATCH/.github/workflows/autoducks-close.yml")"
if [[ "$CLOSE_GUARD_COUNT" -eq 2 ]]; then
  pass "close has exactly 2 hook guards (pre + post)"
else
  fail "close has $CLOSE_GUARD_COUNT hook guards, expected 2"
fi

echo "── shipped config reproduces committed guards ──"
if diff -r "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/workflows" >/dev/null; then
  pass "regenerated guards match the committed workflows"
else
  fail "regenerated guards differ from committed workflows"
  # sed + `|| true` rather than `| head`: see unit-workflow-mirror-parity.sh.
  diff -r "$REPO_ROOT/.github/workflows" "$SCRATCH/.github/workflows" | sed -n '1,10p' || true
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

echo "── rework/defer guards fire on both issue and PR comments ──"
if grep -q "startsWith(github.event.comment.body, '/rework')" "$SCRATCH/.github/workflows/autoducks-rework.yml"; then
  pass "rework guard matches /rework"
else
  fail "rework guard missing /rework match"
fi
if grep -q "github.event.issue.pull_request == null" "$SCRATCH/.github/workflows/autoducks-rework.yml"; then
  fail "rework guard incorrectly restricted to issues only (pull_request == null)"
else
  pass "rework guard omits pull_request == null (fires on issues and PRs)"
fi
if grep -q "startsWith(github.event.comment.body, '/defer')" "$SCRATCH/.github/workflows/autoducks-defer.yml"; then
  pass "defer guard matches /defer"
else
  fail "defer guard missing /defer match"
fi
if grep -q "github.event.issue.pull_request == null" "$SCRATCH/.github/workflows/autoducks-defer.yml"; then
  fail "defer guard incorrectly restricted to issues only (pull_request == null)"
else
  pass "defer guard omits pull_request == null (fires on issues and PRs)"
fi
if grep -q "^  contents: write$" "$SCRATCH/.github/workflows/autoducks-rework.yml"; then
  pass "rework has contents: write"
else
  fail "rework missing contents: write"
fi
if grep -q "^  contents: read$" "$SCRATCH/.github/workflows/autoducks-defer.yml"; then
  pass "defer has contents: read"
else
  fail "defer missing contents: read"
fi

echo "── reviewer auto-fires on ready-for-review of final PRs only ──"
if grep -q "github.event.action == 'ready_for_review'" "$SCRATCH/.github/workflows/autoducks-reviewer.yml"; then
  pass "reviewer guard includes the ready_for_review auto-trigger"
else
  fail "reviewer guard missing ready_for_review auto-trigger"
fi
if grep -q "startsWith(github.event.pull_request.head.ref, 'feature/')" "$SCRATCH/.github/workflows/autoducks-reviewer.yml"; then
  pass "reviewer guard targets feature/ head branches"
else
  fail "reviewer guard missing feature/ head match"
fi
if grep -q "!startsWith(github.event.pull_request.base.ref, 'feature/')" "$SCRATCH/.github/workflows/autoducks-reviewer.yml"; then
  pass "reviewer guard excludes task PRs (base not a feature/ branch)"
else
  fail "reviewer guard missing task-PR (base) exclusion"
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

echo "── product guard idempotence ──"
cp "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-product.yml" "$SCRATCH/product-before.yml"
run
if diff "$SCRATCH/product-before.yml" "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-product.yml" >/dev/null; then
  pass "second run of autoducks-product.yml is byte-identical"
else
  fail "autoducks-product.yml changed on a no-op second run"
fi
if diff "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-product.yml" \
        "$SCRATCH/.github/workflows/autoducks-product.yml" >/dev/null; then
  pass "autoducks-product.yml runtime and .github/workflows/ copies match"
else
  fail "autoducks-product.yml runtime/.github mirror out of sync"
fi

echo "── product custom aliases are baked into the product guard ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["triage"] = ["scan"]
cfg["triggers"]["merge"] = ["land"]
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "'/scan'" "$SCRATCH/.github/workflows/autoducks-product.yml" \
  && pass "triage custom alias in product guard" || fail "scan missing in product guard"
grep -q "'/land'" "$SCRATCH/.github/workflows/autoducks-product.yml" \
  && pass "merge custom alias in product guard" || fail "land missing in product guard"

echo "── product/merge alias collision with a built-in verb fails validation ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["triage"] = []
cfg["triggers"]["merge"] = []
cfg["triggers"]["fix"] = ["triage"]
json.dump(cfg, open(p, "w"), indent=2)
EOF
if run 2>/dev/null; then
  fail "alias colliding with built-in 'triage' accepted"
else
  pass "alias colliding with built-in 'triage' rejected (hard error)"
fi
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["fix"] = []
json.dump(cfg, open(p, "w"), indent=2)
EOF
run

echo "── product.schedule is baked into the workflow's schedule.cron ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["product"]["schedule"] = "30 3 * * 1"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "cron: '30 3 \* \* 1'" "$SCRATCH/.github/workflows/autoducks-product.yml" \
  && pass "baked cron reflects product.schedule" || fail "product.schedule not baked into cron"

echo "── product.enabled=false removes the schedule trigger ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["product"]["enabled"] = False
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
if grep -q "^  schedule:$" "$SCRATCH/.github/workflows/autoducks-product.yml"; then
  fail "schedule trigger still present after product.enabled=false"
else
  pass "schedule trigger removed when product.enabled=false"
fi

echo "── re-enabling restores the schedule trigger with the current cron ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["product"]["enabled"] = True
cfg["product"]["schedule"] = "15 4 * * *"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "cron: '15 4 \* \* \*'" "$SCRATCH/.github/workflows/autoducks-product.yml" \
  && pass "schedule trigger restored with the current cron on re-enable" \
  || fail "schedule trigger not restored on re-enable"

echo "── render_update: custom triggers.update aliases are baked into the update guard ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["update"] = ["refresh"]
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "'/update'" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "built-in /update alias retained alongside custom alias" || fail "/update missing after adding custom alias"
grep -q "'/refresh'" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "update custom alias baked into update guard" || fail "refresh missing in update guard"

echo "── render_update: idempotent with custom triggers.update aliases ──"
cp "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" "$SCRATCH/update-with-alias-before.yml"
run
if diff "$SCRATCH/update-with-alias-before.yml" "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" >/dev/null; then
  pass "second run with custom alias is byte-identical"
else
  fail "autoducks-update.yml changed on a no-op second run (with custom alias)"
fi

echo "── render_update: idempotent without custom triggers.update aliases ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["triggers"]["update"] = []
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
cp "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" "$SCRATCH/update-no-alias-before.yml"
run
if diff "$SCRATCH/update-no-alias-before.yml" "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" >/dev/null; then
  pass "second run without custom alias is byte-identical"
else
  fail "autoducks-update.yml changed on a no-op second run (without custom alias)"
fi
if diff "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" \
        "$SCRATCH/.github/workflows/autoducks-update.yml" >/dev/null; then
  pass "autoducks-update.yml runtime and .github/workflows/ copies match"
else
  fail "autoducks-update.yml runtime/.github mirror out of sync"
fi

echo "── patch_update_cron: update.schedule is baked into the workflow's schedule.cron ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["update"]["schedule"] = "7 4 * * 3"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "cron: '7 4 \* \* 3'" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "baked cron reflects update.schedule" || fail "update.schedule not baked into cron"
grep -q "cron: '7 4 \* \* 3'" "$SCRATCH/.autoducks/runtimes/github-actions/autoducks-update.yml" \
  && pass "baked cron reflects update.schedule in runtime template" || fail "update.schedule not baked into runtime cron"

echo "── patch_update_cron: update.enabled=false removes the schedule trigger ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["update"]["enabled"] = False
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
if grep -q "^  schedule:$" "$SCRATCH/.github/workflows/autoducks-update.yml"; then
  fail "schedule trigger still present after update.enabled=false"
else
  pass "schedule trigger removed when update.enabled=false"
fi
grep -q "workflow_dispatch:" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "workflow_dispatch trigger survives update.enabled=false" || fail "workflow_dispatch lost when update.enabled=false"
grep -q "issue_comment:" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "issue_comment trigger survives update.enabled=false" || fail "issue_comment lost when update.enabled=false"

echo "── patch_update_cron: re-enabling restores the schedule trigger with the current cron ──"
python3 - "$SCRATCH/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["update"]["enabled"] = True
cfg["update"]["schedule"] = "15 5 * * 2"
json.dump(cfg, open(p, "w"), indent=2)
EOF
run
grep -q "^  schedule:$" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "schedule trigger key reinserted under on: on re-enable" || fail "schedule trigger key not reinserted on re-enable"
grep -q "cron: '15 5 \* \* 2'" "$SCRATCH/.github/workflows/autoducks-update.yml" \
  && pass "schedule trigger restored with the current cron on re-enable" \
  || fail "schedule trigger not restored on re-enable"

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
