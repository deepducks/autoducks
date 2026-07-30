#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/changelog.sh
# Run: bash test/unit-changelog.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG_SH="$REPO_ROOT/.autoducks/core/config/changelog.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "── static checks ──"
bash -n "$CHANGELOG_SH" && pass "bash -n" || fail "bash -n failed"
if command -v shellcheck &>/dev/null; then
  shellcheck "$CHANGELOG_SH" && pass "shellcheck" || fail "shellcheck failed"
else
  echo "  (shellcheck not installed, skipping)"
fi

echo "── sourceable twice ──"
(
  # shellcheck source=/dev/null
  source "$CHANGELOG_SH"
  # shellcheck source=/dev/null
  source "$CHANGELOG_SH"
) && pass "double source is a no-op" || fail "double source errored"

# shellcheck source=/dev/null
source "$CHANGELOG_SH"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# new_root NAME — fresh synthetic $AUTODUCKS_ROOT with a multi-release
# CHANGELOG.md; returns via global AUTODUCKS_ROOT.
new_root() {
  AUTODUCKS_ROOT="$SCRATCH/$1"
  mkdir -p "$AUTODUCKS_ROOT"
  cat > "$AUTODUCKS_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [0.3.0] - 2026-08-10

### Breaking
- Something changed in a breaking way.

### Added
- Feature C.

## [0.2.0] - 2026-08-04

### Added
- Feature B.

### Fixed
- Bug B.

## [0.1.0] - 2026-07-01

### Added
- Feature A.
EOF
  export AUTODUCKS_ROOT
}

new_root main

echo "── changelog::section ──"
BODY="$(changelog::section "0.2.0")"
if grep -qF "### Added" <<<"$BODY" && grep -qF "Feature B." <<<"$BODY" && grep -qF "### Fixed" <<<"$BODY" && grep -qF "Bug B." <<<"$BODY"; then
  pass "changelog::section returns the release's full body"
else
  fail "changelog::section body missing expected content: [$BODY]"
fi
[[ "$(head -n1 <<<"$BODY")" != "" ]] && pass "changelog::section trims leading blank lines" || fail "changelog::section did not trim leading blank lines"
if ! grep -qF "0.3.0" <<<"$BODY" && ! grep -qF "0.1.0" <<<"$BODY"; then
  pass "changelog::section does not bleed into neighboring releases"
else
  fail "changelog::section bled into a neighboring release: [$BODY]"
fi

if changelog::section "9.9.9" >/tmp/changelog-missing.out 2>&1; then
  fail "changelog::section succeeded for a version with no heading"
else
  pass "changelog::section exits nonzero for a version with no heading"
fi

echo "── changelog::range ──"
RANGE="$(changelog::range "0.1.0" "0.3.0")"
POS_030=$(grep -n "Feature C." <<<"$RANGE" | head -n1 | cut -d: -f1)
POS_020=$(grep -n "Feature B." <<<"$RANGE" | head -n1 | cut -d: -f1)
if [[ -n "$POS_030" && -n "$POS_020" && "$POS_030" -lt "$POS_020" ]]; then
  pass "changelog::range 0.1.0..0.3.0 orders 0.3.0's body before 0.2.0's"
else
  fail "changelog::range did not order newest-first: [$RANGE]"
fi
if ! grep -qF "Feature A." <<<"$RANGE"; then
  pass "changelog::range excludes the FROM version itself"
else
  fail "changelog::range leaked the FROM version's body: [$RANGE]"
fi

EMPTY_RANGE="$(changelog::range "0.2.0" "0.2.0")"
[[ -z "$EMPTY_RANGE" ]] && pass "changelog::range returns empty when FROM == TO" || fail "changelog::range FROM==TO not empty: [$EMPTY_RANGE]"

SINGLE_RANGE="$(changelog::range "0.1.0" "0.2.0")"
if grep -qF "Feature B." <<<"$SINGLE_RANGE" && ! grep -qF "Feature A." <<<"$SINGLE_RANGE" && ! grep -qF "Feature C." <<<"$SINGLE_RANGE"; then
  pass "changelog::range single-release window returns exactly that release's body"
else
  fail "changelog::range single-release window wrong: [$SINGLE_RANGE]"
fi

NO_MATCH_RANGE="$(changelog::range "0.3.0" "0.3.0")"
[[ -z "$NO_MATCH_RANGE" ]] && pass "changelog::range empty for a same-version window at the newest release" || fail "changelog::range non-empty for same-version newest window"

echo "── changelog::range ordering is by semver, not file order ──"
new_root unordered
cat > "$AUTODUCKS_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [0.1.0] - 2026-07-01

### Added
- Feature A.

## [0.3.0] - 2026-08-10

### Added
- Feature C.

## [0.2.0] - 2026-08-04

### Added
- Feature B.
EOF
RANGE2="$(changelog::range "0.1.0" "0.3.0")"
POS2_030=$(grep -n "Feature C." <<<"$RANGE2" | head -n1 | cut -d: -f1)
POS2_020=$(grep -n "Feature B." <<<"$RANGE2" | head -n1 | cut -d: -f1)
if [[ -n "$POS2_030" && -n "$POS2_020" && "$POS2_030" -lt "$POS2_020" ]]; then
  pass "changelog::range orders by semver::compare even when the file is out of order"
else
  fail "changelog::range relied on file order: [$RANGE2]"
fi
new_root main

echo "── changelog::has_breaking ──"
changelog::has_breaking "0.2.0" "0.3.0" && pass "has_breaking true when a Breaking heading is in range" || fail "has_breaking should be true for 0.2.0..0.3.0"
if changelog::has_breaking "0.1.0" "0.2.0"; then
  fail "has_breaking should be false for 0.1.0..0.2.0 (no Breaking heading)"
else
  pass "has_breaking false when no Breaking heading is in range"
fi
if changelog::has_breaking "0.2.0" "0.2.0"; then
  fail "has_breaking should be false for an empty range"
else
  pass "has_breaking false for an empty range (FROM == TO)"
fi

echo ""
echo "═══ changelog: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
