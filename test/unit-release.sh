#!/usr/bin/env bash
# Unit tests for scripts/release.sh's pure computation: next-version bump
# arithmetic across all three flags, and no-flag bump-kind inference across
# feat:, fix:, chore!: and BREAKING CHANGE: commit subjects.
# Run: bash test/unit-release.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SH="$REPO_ROOT/scripts/release.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "── static checks ──"
bash -n "$RELEASE_SH" && pass "bash -n" || fail "bash -n failed"
if command -v shellcheck &>/dev/null; then
  shellcheck "$RELEASE_SH" && pass "shellcheck" || fail "shellcheck failed"
else
  echo "  (shellcheck not installed, skipping)"
fi

echo "── sourceable twice ──"
(
  # shellcheck source=/dev/null
  source "$RELEASE_SH"
  # shellcheck source=/dev/null
  source "$RELEASE_SH"
) && pass "double source is a no-op" || fail "double source errored"

# shellcheck source=/dev/null
source "$RELEASE_SH"

echo "── release::bump_version across all three flags ──"
[[ "$(release::bump_version "1.2.3" "major")" == "2.0.0" ]] \
  && pass "major resets minor and patch" || fail "major bump mismatch: $(release::bump_version "1.2.3" "major")"
[[ "$(release::bump_version "1.2.3" "minor")" == "1.3.0" ]] \
  && pass "minor resets patch" || fail "minor bump mismatch: $(release::bump_version "1.2.3" "minor")"
[[ "$(release::bump_version "1.2.3" "patch")" == "1.2.4" ]] \
  && pass "patch increments patch only" || fail "patch bump mismatch: $(release::bump_version "1.2.3" "patch")"
[[ "$(release::bump_version "0.1.0" "minor")" == "0.2.0" ]] \
  && pass "minor bump from a 0.x version" || fail "0.x minor bump mismatch: $(release::bump_version "0.1.0" "minor")"

echo "── release::classify_subject ──"
[[ "$(release::classify_subject "feat: add widget")" == "minor" ]] \
  && pass "feat: classifies minor" || fail "feat: classification wrong: $(release::classify_subject "feat: add widget")"
[[ "$(release::classify_subject "feat(api): add widget")" == "minor" ]] \
  && pass "feat(scope): classifies minor" || fail "feat(scope): classification wrong"
[[ "$(release::classify_subject "fix: correct off-by-one")" == "patch" ]] \
  && pass "fix: classifies patch" || fail "fix: classification wrong: $(release::classify_subject "fix: correct off-by-one")"
[[ "$(release::classify_subject "chore!: drop legacy config")" == "major" ]] \
  && pass "chore!: classifies major" || fail "chore!: classification wrong: $(release::classify_subject "chore!: drop legacy config")"
[[ "$(release::classify_subject "feat: rework auth

BREAKING CHANGE: tokens are no longer accepted")" == "major" ]] \
  && pass "BREAKING CHANGE: classifies major even without a bang" || fail "BREAKING CHANGE: classification wrong"
[[ "$(release::classify_subject "docs: fix typo")" == "patch" ]] \
  && pass "unrecognized type falls back to patch" || fail "docs: classification wrong: $(release::classify_subject "docs: fix typo")"

echo "── release::infer_bump (no-flag inference across mixed subjects) ──"
[[ "$(release::infer_bump "feat: add widget" "fix: correct off-by-one")" == "minor" ]] \
  && pass "feat + fix infers minor (feat outranks fix)" || fail "feat+fix inference wrong: $(release::infer_bump "feat: add widget" "fix: correct off-by-one")"
[[ "$(release::infer_bump "fix: correct off-by-one" "chore: bump deps")" == "patch" ]] \
  && pass "fix + chore infers patch (no feat, no breaking)" || fail "fix+chore inference wrong: $(release::infer_bump "fix: correct off-by-one" "chore: bump deps")"
[[ "$(release::infer_bump "feat: add widget" "chore!: drop legacy config")" == "major" ]] \
  && pass "feat + chore!: infers major (breaking outranks feat)" || fail "feat+chore! inference wrong: $(release::infer_bump "feat: add widget" "chore!: drop legacy config")"
[[ "$(release::infer_bump "feat: rework auth" "BREAKING CHANGE: tokens are no longer accepted")" == "major" ]] \
  && pass "feat + BREAKING CHANGE infers major" || fail "feat+BREAKING inference wrong"
[[ "$(release::infer_bump)" == "patch" ]] \
  && pass "no commit subjects infers patch" || fail "empty inference wrong: $(release::infer_bump)"

echo ""
echo "═══ release: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
