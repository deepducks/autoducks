#!/usr/bin/env bash
# Unit tests for metarepo::stale_submodule_keys / metarepo::unconfigured_submodules
# Run: bash test/unit-metarepo-submodule-config.sh
#
# `metarepo.submodules` is keyed by submodule path but nothing tied the two
# together, so a retired child (`autoducks-cli`, #77) left a key behind that
# read like live config for months. These assert the drift is now an error.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$REPO_ROOT/.autoducks/core/config/metarepo.sh"

PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# A real git repo, since metarepo::gitmodules_file resolves via `git rev-parse`.
git init -q "$SCRATCH/repo"
cd "$SCRATCH/repo"
mkdir -p .autoducks

# fixture GITMODULES_PATHS... — rewrite .gitmodules
fixture_gitmodules() {
  : > .gitmodules
  local p
  for p in "$@"; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = https://github.com/acme/%s.git\n' \
      "$p" "$p" "$p" >> .gitmodules
  done
}

# fixture_config KEYS... — rewrite autoducks.json's metarepo.submodules
fixture_config() {
  printf '%s\n' "$@" | jq -R . | jq -s \
    '{metarepo: {enabled: true, submodules: (map({key: ., value: {protected: null}}) | from_entries)}}' \
    > .autoducks/autoducks.json
}

# shellcheck source=/dev/null
AUTODUCKS_ROOT=".autoducks" source "$MODULE"
export AUTODUCKS_ROOT=".autoducks"

# ---------------------------------------------------------------------------
echo "── config matching .gitmodules exactly ──"

fixture_gitmodules child-a child-b
fixture_config child-a child-b

if out=$(metarepo::stale_submodule_keys); then
  pass "no stale keys reported, exit 0"
else
  fail "clean config reported stale keys: '$out'"
fi

if out=$(metarepo::unconfigured_submodules); then
  pass "no unconfigured submodules reported, exit 0"
else
  fail "clean config reported unconfigured submodules: '$out'"
fi

# ---------------------------------------------------------------------------
echo "── a key with no submodule behind it (the autoducks-cli case) ──"

fixture_gitmodules child-a child-b
fixture_config child-a child-b retired-cli

if out=$(metarepo::stale_submodule_keys); then
  fail "stale key 'retired-cli' not reported — exit was 0"
else
  if [[ "$out" == "retired-cli" ]]; then
    pass "reports exactly 'retired-cli' and exits non-zero"
  else
    fail "wrong stale output: '$out' (want 'retired-cli')"
  fi
fi

# ---------------------------------------------------------------------------
echo "── several stale keys are all reported ──"

fixture_config child-a gone-1 gone-2

out=$(metarepo::stale_submodule_keys) && fail "expected non-zero exit"
if [[ "$(printf '%s' "$out" | sort | tr '\n' ' ')" == "gone-1 gone-2 " ]]; then
  pass "reports both stale keys"
else
  fail "wrong stale output: '$out'"
fi

# ---------------------------------------------------------------------------
echo "── a submodule with no config entry is advisory, not stale ──"

fixture_gitmodules child-a child-b child-c
fixture_config child-a child-b

if out=$(metarepo::stale_submodule_keys); then
  pass "an unconfigured submodule is not a stale key"
else
  fail "unconfigured submodule wrongly reported stale: '$out'"
fi

out=$(metarepo::unconfigured_submodules) && fail "expected non-zero exit"
if [[ "$out" == "child-c" ]]; then
  pass "reports child-c as unconfigured"
else
  fail "wrong unconfigured output: '$out' (want 'child-c')"
fi

# ---------------------------------------------------------------------------
echo "── an absent or empty submodules block is not an error ──"

fixture_gitmodules child-a
echo '{"metarepo": {"enabled": true}}' > .autoducks/autoducks.json
if metarepo::stale_submodule_keys >/dev/null; then
  pass "no submodules block → no stale keys"
else
  fail "absent submodules block reported stale keys"
fi

echo '{"metarepo": {"enabled": true, "submodules": {}}}' > .autoducks/autoducks.json
if metarepo::stale_submodule_keys >/dev/null; then
  pass "empty submodules block → no stale keys"
else
  fail "empty submodules block reported stale keys"
fi

# ---------------------------------------------------------------------------
echo "── nested submodule paths compare whole, not by prefix ──"

fixture_gitmodules vendor/child-a
fixture_config vendor/child-a
if metarepo::stale_submodule_keys >/dev/null; then
  pass "nested path matches its .gitmodules entry"
else
  fail "nested path wrongly reported stale"
fi

fixture_config child-a
out=$(metarepo::stale_submodule_keys) && fail "expected non-zero exit"
if [[ "$out" == "child-a" ]]; then
  pass "'child-a' does not match 'vendor/child-a'"
else
  fail "wrong output for prefix case: '$out'"
fi

# ---------------------------------------------------------------------------
echo "── protected: an explicit bool overrides runtime detection ──"

# Stub the provider. If the override works, this is never called; the stub
# returns a value neither test case expects, so a fall-through cannot pass.
git::submodule_protection() { echo "STUB-CALLED"; }

write_protected_config() { # VALUE (true|false|null)
  jq -n --arg p "child-a" --argjson v "$1" \
    '{metarepo: {enabled: true, submodules: {($p): {protected: $v}}}}' \
    > .autoducks/autoducks.json
}

fixture_gitmodules child-a

write_protected_config true
got=$(metarepo::protected_for_path child-a)
if [[ "$got" == "true" ]]; then
  pass "protected: true overrides detection"
else
  fail "protected: true → '$got' (want 'true')"
fi

# The one that jq's `//` operator gets wrong: `false // "null"` is "null", so an
# explicit false would fall through to detection and the override would work in
# one direction only.
write_protected_config false
got=$(metarepo::protected_for_path child-a)
if [[ "$got" == "false" ]]; then
  pass "protected: false overrides detection (not swallowed by jq //)"
elif [[ "$got" == "STUB-CALLED" ]]; then
  fail "protected: false fell through to runtime detection — jq // pitfall"
else
  fail "protected: false → '$got' (want 'false')"
fi

write_protected_config null
got=$(metarepo::protected_for_path child-a)
if [[ "$got" == "STUB-CALLED" ]]; then
  pass "protected: null falls through to runtime detection"
else
  fail "protected: null → '$got' (want the provider to be consulted)"
fi

echo '{"metarepo": {"enabled": true, "submodules": {"child-a": {}}}}' > .autoducks/autoducks.json
got=$(metarepo::protected_for_path child-a)
if [[ "$got" == "STUB-CALLED" ]]; then
  pass "absent protected key falls through to runtime detection"
else
  fail "absent key → '$got' (want the provider to be consulted)"
fi

echo '{"metarepo": {"enabled": true}}' > .autoducks/autoducks.json
got=$(metarepo::protected_for_path child-a)
if [[ "$got" == "STUB-CALLED" ]]; then
  pass "absent submodules block falls through to runtime detection"
else
  fail "absent block → '$got' (want the provider to be consulted)"
fi

# A path with no .gitmodules entry has no slug to probe — fail safe rather than
# calling the provider with an empty argument.
write_protected_config null
got=$(metarepo::protected_for_path not-a-submodule)
if [[ "$got" == "false" ]]; then
  pass "unknown path with no slug → false, provider not called"
else
  fail "unknown path → '$got' (want 'false')"
fi

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
