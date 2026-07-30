#!/usr/bin/env bash
# Integration tests for scripts/install.sh copy logic — drives the real
# script through the AUTODUCKS_SOURCE_DIR offline seam across fresh-install,
# update, and idempotence scenarios. Never touches the network: the seam
# replaces the tarball download/curl call with a local directory.
#
# Run: bash test/unit-install-copy.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

SOURCE_DIR="$SCRATCH/source"
CONSUMER="$SCRATCH/consumer"

# ── Stub `gh` so the sha-resolution step never touches the network: exiting
#    non-zero simulates "gh unavailable/unauthenticated", which install.sh
#    already handles by falling back gracefully. Keeps this suite's "never
#    touches the network" guarantee intact even though a real `gh` may be on
#    PATH in whatever environment runs it. ──
STUB_BIN="$SCRATCH/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"

# ── Build the offline "download" source: real .autoducks/, ISSUE_TEMPLATE,
#    and the 5 scripts install.sh copies into a consumer repo ──
mkdir -p "$SOURCE_DIR/.github/ISSUE_TEMPLATE" "$SOURCE_DIR/scripts"
cp -R "$REPO_ROOT/.autoducks" "$SOURCE_DIR/.autoducks"
cp "$REPO_ROOT/.github/ISSUE_TEMPLATE/"* "$SOURCE_DIR/.github/ISSUE_TEMPLATE/"
for f in setup.sh install.sh update-triggers.sh smoke-test.sh smoke-test-plan.sh; do
  cp "$REPO_ROOT/scripts/$f" "$SOURCE_DIR/scripts/$f"
done

# Seed dev-only artifacts that MUST NOT ship to consumers: the unit-test suite
# (top-level test/) and the repo's own CI workflow (a non-autoducks-*.yml file).
# install.sh must filter both out. Regression guard for #784.
mkdir -p "$SOURCE_DIR/test" "$SOURCE_DIR/.github/workflows"
printf '#!/usr/bin/env bash\necho canary\n' > "$SOURCE_DIR/test/unit-canary.sh"
printf 'name: CI — unit tests\n' > "$SOURCE_DIR/.github/workflows/ci-unit-tests.yml"

mkdir -p "$CONSUMER"

run_install() { # runs the real install.sh, offline seam pointed at SOURCE_DIR
  (cd "$CONSUMER" && AUTODUCKS_SOURCE_DIR="$SOURCE_DIR" PATH="$STUB_BIN:$PATH" \
    bash "$REPO_ROOT/scripts/install.sh" --no-setup)
}

# ═══ Fresh install ═══
echo "── fresh install ──"

SOURCE_SNAPSHOT="$SCRATCH/source-snapshot"
cp -R "$SOURCE_DIR" "$SOURCE_SNAPSHOT"

FRESH_OUT="$(run_install 2>&1)"

if [[ -f "$CONSUMER/.autoducks/autoducks.json" ]]; then
  pass "fresh install: config exists"
else
  fail "fresh install: config missing"
fi

if [[ ! -e "$CONSUMER/.autoducks/.autoducks" ]]; then
  pass "fresh install: no nested .autoducks/.autoducks"
else
  fail "fresh install: nested .autoducks/.autoducks found"
fi

if diff -r "$CONSUMER/.github/workflows" "$CONSUMER/.autoducks/runtimes/github-actions" >/dev/null; then
  pass "fresh install: workflows mirror runtime templates"
else
  fail "fresh install: workflows mirror out of sync with runtime templates"
fi

if cmp -s "$CONSUMER/.autoducks/core/orchestration/fold-duplicate.sh" "$REPO_ROOT/.autoducks/core/orchestration/fold-duplicate.sh"; then
  pass "fresh install: core/orchestration/fold-duplicate.sh vendored byte-identical"
else
  fail "fresh install: core/orchestration/fold-duplicate.sh missing or out of sync"
fi

if diff -r "$SOURCE_DIR" "$SOURCE_SNAPSHOT" >/dev/null; then
  pass "fresh install: source dir untouched (CLEANUP_TMP guard)"
else
  fail "fresh install: source dir was mutated"
fi

# Dev-only artifacts must never reach a consumer repo (#784): the unit-test
# suite and the repo's own CI workflow stay in the autoducks source repo only.
if [[ ! -e "$CONSUMER/test/unit-canary.sh" ]]; then
  pass "fresh install: unit-test suite (test/) NOT shipped to consumer"
else
  fail "fresh install: test/ leaked into the consumer repo"
fi
if [[ ! -e "$CONSUMER/.github/workflows/ci-unit-tests.yml" ]]; then
  pass "fresh install: CI workflow (ci-unit-tests.yml) NOT shipped to consumer"
else
  fail "fresh install: ci-unit-tests.yml leaked into the consumer repo"
fi

echo "$FRESH_OUT" | grep -q "Installing autoducks" \
  && pass "fresh install: install mode detected" \
  || fail "fresh install: install mode not detected"

echo "$FRESH_OUT" | grep -q "Applying plugins" \
  && pass "fresh install: plugin compiler invoked" \
  || fail "fresh install: plugin compiler not invoked"

if [[ ! -d "$CONSUMER/.autoducks/providers/llm/claude/compiled" ]]; then
  pass "fresh install: plugins: [] produces no compiled/ files"
else
  fail "fresh install: unexpected compiled/ files with empty plugins[]"
fi

# ═══ Update ═══
echo "── update ──"

# Mutate consumer-owned state that must survive an update.
python3 - "$CONSUMER/.autoducks/autoducks.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["command"] = "sentinel-cmd"
json.dump(cfg, open(p, "w"), indent=2)
EOF

mkdir -p "$CONSUMER/.autoducks/providers/llm/claude"
echo '{"sentinel": "settings"}' > "$CONSUMER/.autoducks/providers/llm/claude/settings.json"

mkdir -p "$CONSUMER/.autoducks/custom/agents/developer"
echo "sentinel custom instructions" > "$CONSUMER/.autoducks/custom/instructions.md"
echo "sentinel custom developer prompt" > "$CONSUMER/.autoducks/custom/agents/developer/prompt.md"

echo "stale file that should not survive an update" > "$CONSUMER/.autoducks/OBSOLETE.txt"

# Seed vendored plugins that MUST survive an update (#1061): plugin.schema.json
# resolves `.autoducks/plugins/<name>` and `.autoducks/plugins/@local` sources,
# so both must persist across the rm -rf/copy of .autoducks/.
mkdir -p "$CONSUMER/.autoducks/plugins/foo" "$CONSUMER/.autoducks/plugins/@local"
echo '{"schemaVersion":1,"name":"foo","version":"1.0.0"}' > "$CONSUMER/.autoducks/plugins/foo/plugin.json"
echo "sentinel local contribution" > "$CONSUMER/.autoducks/plugins/@local/README.md"

mkdir -p "$CONSUMER/.github/actions/autoducks/developer-pre"
cat > "$CONSUMER/.github/actions/autoducks/developer-pre/action.yml" <<'EOF'
name: sentinel developer-pre hook
runs:
  using: composite
  steps:
    - run: echo sentinel
      shell: bash
EOF

# Snapshot consumer-owned state before the update run, to diff byte-for-byte after.
CONFIG_SNAPSHOT="$SCRATCH/config-before-update.json"
cp "$CONSUMER/.autoducks/autoducks.json" "$CONFIG_SNAPSHOT"
SETTINGS_SNAPSHOT="$SCRATCH/settings-before-update.json"
cp "$CONSUMER/.autoducks/providers/llm/claude/settings.json" "$SETTINGS_SNAPSHOT"
CUSTOM_SNAPSHOT="$SCRATCH/custom-before-update"
cp -R "$CONSUMER/.autoducks/custom" "$CUSTOM_SNAPSHOT"
ACTION_SNAPSHOT="$SCRATCH/action-before-update.yml"
cp "$CONSUMER/.github/actions/autoducks/developer-pre/action.yml" "$ACTION_SNAPSHOT"
PLUGINS_SNAPSHOT="$SCRATCH/plugins-before-update"
cp -R "$CONSUMER/.autoducks/plugins" "$PLUGINS_SNAPSHOT"

UPDATE_OUT="$(run_install 2>&1)"

echo "$UPDATE_OUT" | grep -q "Updating autoducks" \
  && pass "update: update mode detected" \
  || fail "update: update mode not detected"

echo "$UPDATE_OUT" | grep -q "Applying plugins" \
  && pass "update: plugin compiler invoked" \
  || fail "update: plugin compiler not invoked"

TRIGGERS_LINE=$(echo "$UPDATE_OUT" | grep -n "Applying custom trigger aliases" | head -1 | cut -d: -f1)
PLUGINS_LINE=$(echo "$UPDATE_OUT" | grep -n "Applying plugins" | head -1 | cut -d: -f1)
if [[ -n "$TRIGGERS_LINE" && -n "$PLUGINS_LINE" && "$TRIGGERS_LINE" -lt "$PLUGINS_LINE" ]]; then
  pass "update: plugin compiler invoked after update-triggers.sh"
else
  fail "update: plugin compiler not invoked after update-triggers.sh"
fi

if diff -r "$CONSUMER/.autoducks/plugins" "$PLUGINS_SNAPSHOT" >/dev/null; then
  pass "update: .autoducks/plugins/ (foo/ and @local/) preserved byte-identical"
else
  fail "update: .autoducks/plugins/ was not preserved"
fi

if [[ ! -d "$CONSUMER/.autoducks/providers/llm/claude/compiled" ]]; then
  pass "update: plugins: [] produces no compiled/ files"
else
  fail "update: unexpected compiled/ files with empty plugins[]"
fi

if cmp -s "$CONSUMER/.autoducks/autoducks.json" "$CONFIG_SNAPSHOT"; then
  pass "update: config (sentinel command) preserved byte-identical"
else
  fail "update: config was not preserved"
fi

if cmp -s "$CONSUMER/.autoducks/providers/llm/claude/settings.json" "$SETTINGS_SNAPSHOT"; then
  pass "update: settings.json preserved byte-identical"
else
  fail "update: settings.json was not preserved"
fi

if diff -r "$CONSUMER/.autoducks/custom" "$CUSTOM_SNAPSHOT" >/dev/null; then
  pass "update: full custom/ tree preserved byte-identical"
else
  fail "update: custom/ tree was not preserved"
fi

if [[ ! -e "$CONSUMER/.autoducks/OBSOLETE.txt" ]]; then
  pass "update: stale OBSOLETE.txt removed"
else
  fail "update: stale OBSOLETE.txt survived"
fi

if [[ ! -e "$CONSUMER/.autoducks/.autoducks" ]]; then
  pass "update: no nested .autoducks/.autoducks"
else
  fail "update: nested .autoducks/.autoducks found"
fi

if cmp -s "$CONSUMER/.github/actions/autoducks/developer-pre/action.yml" "$ACTION_SNAPSHOT"; then
  pass "update: user hook action untouched"
else
  fail "update: user hook action was modified"
fi

if diff -r "$CONSUMER/.github/workflows" "$CONSUMER/.autoducks/runtimes/github-actions" >/dev/null; then
  pass "update: workflows mirror runtime templates"
else
  fail "update: workflows mirror out of sync with runtime templates"
fi

HOOK_USES_COUNT=$(grep -rc "uses: \./\.github/actions/autoducks/" "$CONSUMER/.github/workflows/"*.yml | awk -F: '{sum += $2} END {print sum}')
if [[ "$HOOK_USES_COUNT" -eq 24 ]]; then
  pass "update: hook 'uses:' lines survived across all 12 workflow templates"
else
  fail "update: expected 24 hook 'uses:' lines, found $HOOK_USES_COUNT"
fi

# ═══ Idempotence ═══
echo "── idempotence ──"

WORKFLOWS_SNAPSHOT="$SCRATCH/workflows-before-idempotent"
cp -R "$CONSUMER/.github/workflows" "$WORKFLOWS_SNAPSHOT"
RUNTIMES_SNAPSHOT="$SCRATCH/runtimes-before-idempotent"
cp -R "$CONSUMER/.autoducks/runtimes" "$RUNTIMES_SNAPSHOT"

run_install >/dev/null 2>&1

if diff -r "$CONSUMER/.github/workflows" "$WORKFLOWS_SNAPSHOT" >/dev/null; then
  pass "idempotence: .github/workflows byte-identical across a second update"
else
  fail "idempotence: .github/workflows changed on a second update"
fi

if diff -r "$CONSUMER/.autoducks/runtimes" "$RUNTIMES_SNAPSHOT" >/dev/null; then
  pass "idempotence: .autoducks/runtimes byte-identical across a second update"
else
  fail "idempotence: .autoducks/runtimes changed on a second update"
fi

echo ""
echo "═══ install-copy: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
