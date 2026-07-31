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
echo "── --dry-run works on a branch that cannot be pushed to ──"

# The pushability guard exists because a refused push leaves a local release
# commit and tag to unwind. --dry-run creates neither, so refusing it blocked the
# one command that is always safe — you could not preview a release on exactly
# the repos where you most want to look before cutting one.
RSCRATCH="$(mktemp -d)"
trap 'rm -rf "$RSCRATCH"' EXIT

mkdir -p "$RSCRATCH/bin" "$RSCRATCH/repo/.autoducks"
cat > "$RSCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "repo view --json defaultBranchRef --jq .defaultBranchRef.name") echo "main" ;;
  "repo view --json nameWithOwner --jq .nameWithOwner")            echo "acme/child" ;;
  *branches/main/protection*)
    # Protected AND enforced on admins: the state that makes a direct push fail.
    echo '{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":["unit suite"]}}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$RSCRATCH/bin/gh"

(
  cd "$RSCRATCH/repo"
  git init -q -b main .
  git config user.email t@example.com
  git config user.name Test
  printf '0.1.0\n' > .autoducks/VERSION
  printf '# Changelog\n' > .autoducks/CHANGELOG.md
  git add -A && git commit -q -m "feat: initial"
) >/dev/null 2>&1

run_release() { # ARGS...
  ( cd "$RSCRATCH/repo" \
    && env PATH="$RSCRATCH/bin:$PATH" AUTODUCKS_ROOT=".autoducks" \
         bash "$RELEASE_SH" "$@" ) 2>&1
}

rc=0
out="$(run_release --dry-run --minor)" || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"Next version"* && "$out" == *"0.2.0"* ]]; then
  pass "--dry-run previews the release despite enforce_admins"
else
  fail "--dry-run refused (rc=$rc): $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
if [[ "$out" == *"Dry run: nothing was written"* ]]; then
  pass "--dry-run says plainly that it wrote nothing"
else
  fail "--dry-run did not report itself as a dry run"
fi
if [[ "$(cd "$RSCRATCH/repo" && cat .autoducks/VERSION)" == "0.1.0" ]]; then
  pass "--dry-run left VERSION untouched"
else
  fail "--dry-run wrote VERSION"
fi

# The real run must still be refused — the guard has to keep working.
rc=0
out="$(run_release --minor)" || rc=$?
if [[ "$rc" -ne 0 && "$out" == *"cannot be pushed directly"* ]]; then
  pass "a real release is still refused on the same branch"
else
  fail "the guard stopped firing on a real release (rc=$rc)"
fi
if [[ "$out" == *"--pr --minor"* ]]; then
  pass "the refusal names the bump flag it was called with"
else
  fail "the refusal lost the bump flag: $(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
fi
if [[ "$(cd "$RSCRATCH/repo" && git rev-list --count HEAD)" == "1" ]]; then
  pass "the refusal left no release commit behind"
else
  fail "a release commit was created before the refusal"
fi

echo ""
echo "═══ release: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
