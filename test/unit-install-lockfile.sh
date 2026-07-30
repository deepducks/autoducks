#!/usr/bin/env bash
# Unit tests for scripts/install.sh's .installed.json lockfile, the
# security-guidelines.md stash-vs-refresh branch, and stale runtime-mirror
# pruning — via the AUTODUCKS_SOURCE_DIR offline seam. `gh` is stubbed to a
# fixed sha fixture so sha resolution is deterministic and this suite never
# touches the network.
#
# Run: bash test/unit-install-lockfile.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

if ! command -v jq &>/dev/null; then
  echo "jq required for this suite" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

SOURCE_DIR="$SCRATCH/source"
CONSUMER="$SCRATCH/consumer"
STUB_BIN="$SCRATCH/stub-bin"

FIXED_SHA="0123456789abcdef0123456789abcdef01234567"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "$FIXED_SHA"
EOF
chmod +x "$STUB_BIN/gh"

mkdir -p "$SOURCE_DIR/.github/ISSUE_TEMPLATE" "$SOURCE_DIR/scripts"
cp -R "$REPO_ROOT/.autoducks" "$SOURCE_DIR/.autoducks"
cp "$REPO_ROOT/.github/ISSUE_TEMPLATE/"* "$SOURCE_DIR/.github/ISSUE_TEMPLATE/"
for f in setup.sh install.sh update-triggers.sh; do
  cp "$REPO_ROOT/scripts/$f" "$SOURCE_DIR/scripts/$f"
done

mkdir -p "$CONSUMER"
LOCKFILE="$CONSUMER/.autoducks/.installed.json"

run_install() { # runs the real install.sh, offline seam pointed at SOURCE_DIR
  (cd "$CONSUMER" && AUTODUCKS_SOURCE_DIR="$SOURCE_DIR" PATH="$STUB_BIN:$PATH" \
    bash "$REPO_ROOT/scripts/install.sh" --no-setup "$@")
}

# ═══ Lockfile: fresh install ═══
echo "── lockfile: fresh install ──"

FRESH_OUT="$(run_install 2>&1)"

if [[ -f "$LOCKFILE" ]] && jq . "$LOCKFILE" >/dev/null 2>&1; then
  pass "lockfile: parses as valid JSON"
else
  fail "lockfile: missing or invalid JSON"
fi

echo "$FRESH_OUT" | grep -q "Lockfile written" \
  && pass "fresh install: lockfile-written line printed" \
  || fail "fresh install: lockfile-written line missing"

[[ "$(jq -r '.schemaVersion' "$LOCKFILE")" == "1" ]] \
  && pass "lockfile: schemaVersion is 1" || fail "lockfile: schemaVersion wrong"

[[ "$(jq -r '.ref' "$LOCKFILE")" == "main" ]] \
  && pass "lockfile: ref recorded (main — the stable-channel default)" || fail "lockfile: ref wrong"

[[ "$(jq -r '.channel' "$LOCKFILE")" == "stable" ]] \
  && pass "lockfile: channel defaults to stable" || fail "lockfile: channel wrong"

SHA_VAL="$(jq -r '.sha' "$LOCKFILE")"
[[ "$SHA_VAL" =~ ^[0-9a-f]{40}$ ]] \
  && pass "lockfile: sha is a resolved 40-char hex commit" || fail "lockfile: sha not 40-char hex ($SHA_VAL)"

VERSION_VAL="$(jq -r '.version' "$LOCKFILE")"
EXPECTED_VERSION="$(cat "$REPO_ROOT/.autoducks/VERSION" 2>/dev/null || echo "")"
[[ "$VERSION_VAL" == "$EXPECTED_VERSION" ]] \
  && pass "lockfile: version read from the installed tree's VERSION" || fail "lockfile: version mismatch ($VERSION_VAL != $EXPECTED_VERSION)"

INSTALLED_AT_VAL="$(jq -r '.installed_at' "$LOCKFILE")"
[[ "$INSTALLED_AT_VAL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && pass "lockfile: installed_at is RFC3339" || fail "lockfile: installed_at not RFC3339 ($INSTALLED_AT_VAL)"

[[ "$(jq -r '.previous' "$LOCKFILE")" == "null" ]] \
  && pass "lockfile: previous is null on first install" || fail "lockfile: previous not null on first install"

# ═══ Lockfile: --lock-note / --source-repo overrides ═══
echo "── lockfile: flag overrides ──"

run_install --lock-note "manual-test-run" --source-repo "acme/fork" >/dev/null 2>&1

[[ "$(jq -r '.installed_by' "$LOCKFILE")" == "manual-test-run" ]] \
  && pass "lockfile: --lock-note overrides installed_by" || fail "lockfile: --lock-note not honored"

[[ "$(jq -r '.source_repo' "$LOCKFILE")" == "acme/fork" ]] \
  && pass "lockfile: --source-repo recorded" || fail "lockfile: --source-repo not honored"

# ═══ Lockfile: previous carry-forward across a second run at the same ref ═══
echo "── lockfile: previous carry-forward ──"

rm -rf "$CONSUMER"
mkdir -p "$CONSUMER"

run_install >/dev/null 2>&1
FIRST_TRIPLE="$(jq -c '{ref, sha, version}' "$LOCKFILE")"

WORKFLOWS_SNAPSHOT="$SCRATCH/workflows-before-second-run"
cp -R "$CONSUMER/.github/workflows" "$WORKFLOWS_SNAPSHOT"

run_install >/dev/null 2>&1
SECOND_PREVIOUS="$(jq -c '.previous' "$LOCKFILE")"

if [[ "$SECOND_PREVIOUS" == "$FIRST_TRIPLE" ]]; then
  pass "lockfile: previous carries forward the prior run's ref/sha/version"
else
  fail "lockfile: previous ($SECOND_PREVIOUS) does not match prior run ($FIRST_TRIPLE)"
fi

if diff -r "$CONSUMER/.github/workflows" "$WORKFLOWS_SNAPSHOT" >/dev/null; then
  pass "lockfile: tree otherwise byte-identical across same-ref reruns"
else
  fail "lockfile: tree changed across same-ref reruns"
fi

# ═══ security-guidelines.md: stash-vs-refresh ═══
echo "── security-guidelines.md stash-vs-refresh ──"

rm -rf "$CONSUMER"
mkdir -p "$CONSUMER"
run_install >/dev/null 2>&1 # fresh install seeds security-guidelines.md, unedited

UNMOD_OUT="$(run_install 2>&1)"
echo "$UNMOD_OUT" | grep -q "replaced with incoming template" \
  && pass "security-guidelines.md: unmodified copy replaced by incoming template" \
  || fail "security-guidelines.md: unmodified-copy branch not reported"

echo "local sentinel edit" >> "$CONSUMER/.autoducks/security-guidelines.md"
EDIT_OUT="$(run_install 2>&1)"
echo "$EDIT_OUT" | grep -q "kept local edits" \
  && pass "security-guidelines.md: locally edited branch reported" \
  || fail "security-guidelines.md: locally-edited branch not reported"

grep -q "local sentinel edit" "$CONSUMER/.autoducks/security-guidelines.md" \
  && pass "security-guidelines.md: locally edited copy survives an update" \
  || fail "security-guidelines.md: local edit did not survive the update"

# ═══ Stale mirror pruning ═══
echo "── stale mirror pruning ──"

rm -rf "$CONSUMER"
mkdir -p "$CONSUMER"
run_install >/dev/null 2>&1

echo "name: ghost" > "$CONSUMER/.github/workflows/autoducks-ghost.yml"
PRUNE_OUT="$(run_install 2>&1)"

echo "$PRUNE_OUT" | grep -q "Removed stale mirror: .github/workflows/autoducks-ghost.yml" \
  && pass "stale mirror: removal reported" || fail "stale mirror: removal not reported"

[[ ! -f "$CONSUMER/.github/workflows/autoducks-ghost.yml" ]] \
  && pass "stale mirror: autoducks-ghost.yml deleted" || fail "stale mirror: autoducks-ghost.yml survived"

[[ -f "$CONSUMER/.github/workflows/autoducks-architect.yml" ]] \
  && pass "stale mirror: real runtime mirrors untouched" || fail "stale mirror: a real runtime mirror was removed"

echo ""
echo "═══ install-lockfile: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
