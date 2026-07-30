#!/usr/bin/env bash
# Unit test for scripts/install.sh's self-exec guard. Running
# `bash scripts/install.sh` from inside the target repo must not truncate the
# running script — it's one of the files this exact run overwrites, copying
# scripts/install.sh out of the downloaded tree partway through — and the
# guard must not loop.
#
# Run: bash test/unit-install-self-exec.sh
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
STUB_BIN="$SCRATCH/stub-bin"

mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"

mkdir -p "$SOURCE_DIR/.github/ISSUE_TEMPLATE" "$SOURCE_DIR/scripts"
cp -R "$REPO_ROOT/.autoducks" "$SOURCE_DIR/.autoducks"
cp "$REPO_ROOT/.github/ISSUE_TEMPLATE/"* "$SOURCE_DIR/.github/ISSUE_TEMPLATE/"
for f in setup.sh install.sh update-triggers.sh; do
  cp "$REPO_ROOT/scripts/$f" "$SOURCE_DIR/scripts/$f"
done

# Stub the setup.sh that ships in the downloaded tree so the fresh-install
# path (which runs `scripts/setup.sh` as its very last action, no --no-setup)
# completes hermetically instead of probing real gh auth/labels/rulesets.
cat > "$SOURCE_DIR/scripts/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "STUB_SETUP_RAN"
EOF
chmod +x "$SOURCE_DIR/scripts/setup.sh"

# Put a copy of the real install.sh at scripts/install.sh inside the target
# repo itself — the exact scenario the guard exists for — with a true
# trailing marker appended after the whole script, run without --no-setup so
# execution runs all the way through (including the self-overwrite of this
# very file) to the literal end.
mkdir -p "$CONSUMER/scripts"
cp "$REPO_ROOT/scripts/install.sh" "$CONSUMER/scripts/install.sh"
printf '\necho "INSTALL_SCRIPT_MARKER_REACHED_END"\n' >> "$CONSUMER/scripts/install.sh"
chmod +x "$CONSUMER/scripts/install.sh"

OUT="$( (cd "$CONSUMER" && AUTODUCKS_SOURCE_DIR="$SOURCE_DIR" PATH="$STUB_BIN:$PATH" \
  bash scripts/install.sh) 2>&1 )" || true

echo "$OUT" | grep -q "INSTALL_SCRIPT_MARKER_REACHED_END" \
  && pass "self-exec guard: trailing marker reached (script not truncated)" \
  || fail "self-exec guard: trailing marker missing (script truncated or guard broken)"

MARKER_COUNT="$(echo "$OUT" | grep -c "INSTALL_SCRIPT_MARKER_REACHED_END" || true)"
[[ "$MARKER_COUNT" -eq 1 ]] \
  && pass "self-exec guard: marker printed exactly once (no re-exec loop)" \
  || fail "self-exec guard: marker printed $MARKER_COUNT times (expected 1)"

echo "$OUT" | grep -q "STUB_SETUP_RAN" \
  && pass "self-exec guard: install ran all the way through to setup.sh" \
  || fail "self-exec guard: setup.sh never ran"

echo ""
echo "═══ install-self-exec: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
