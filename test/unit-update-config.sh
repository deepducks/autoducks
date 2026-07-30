#!/usr/bin/env bash
# Unit tests for the `update` config block and AUTODUCKS_VERSION resolution
# read by .autoducks/core/config/load-config.sh:
#   AUTODUCKS_UPDATE_ENABLED, _SCHEDULE, _CHANNEL, _PIN, _MODE, _AUTO_MERGE,
#   _ON_DRIFT, _NOTIFY_ISSUE, _SOURCE_REPO — each defaulted/clamped, garbage
#   tolerated (falls back to the documented default, never a hard failure).
#   AUTODUCKS_VERSION — autoducks.json.version, else .autoducks/VERSION,
#   else empty.
#
# Drives the real load-config.sh against a scratch AUTODUCKS_ROOT that
# symlinks the repo's real core/providers/agents (so every other export it
# performs resolves normally) but supplies its own autoducks.json (and
# optionally VERSION) per case, run in a subshell so load-config's
# `set -euo pipefail` and repeated top-level exports never leak between
# cases. Same scratch-root technique as test/unit-review-config-clamp.sh.
# Run: bash test/unit-update-config.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_CONFIG="$REPO_ROOT/.autoducks/core/config/load-config.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT
ln -s "$REPO_ROOT/.autoducks/agents" "$SCRATCH_ROOT/agents"
ln -s "$REPO_ROOT/.autoducks/core" "$SCRATCH_ROOT/core"
ln -s "$REPO_ROOT/.autoducks/providers" "$SCRATCH_ROOT/providers"
ln -s "$REPO_ROOT/.autoducks/security-guidelines.md" "$SCRATCH_ROOT/security-guidelines.md"

# write_config UPDATE_JSON [VERSION_FIELD] — (re)writes the scratch
# autoducks.json with the fixed provider/defaults scaffolding load-config.sh
# requires, varying only the `.update` block (and optionally `.version`)
# under test. UPDATE_JSON of "null" omits the `update` key entirely.
write_config() {
  local update_json="${1:-null}" version="${2:-}"
  jq -n --argjson update "$update_json" --arg version "$version" '
    {
      providers: {its:"github", git:"github", llm:"claude"},
      defaults: {model:"m", effort:"high", base_branch:"main", merge_method:"auto"}
    }
    + (if $update == null then {} else {update: $update} end)
    + (if $version == "" then {} else {version: $version} end)
  ' > "$SCRATCH_ROOT/autoducks.json"
}

# resolved UPDATE_JSON [VERSION_FIELD] → echoes every AUTODUCKS_UPDATE_* var
# plus AUTODUCKS_VERSION from a fresh load-config.sh run.
resolved() {
  write_config "$1" "${2:-}"
  (
    export AUTODUCKS_ROOT="$SCRATCH_ROOT" AUTODUCKS_AGENT="" GITHUB_ACTIONS=true
    # shellcheck source=/dev/null
    source "$LOAD_CONFIG"
    echo "enabled=$AUTODUCKS_UPDATE_ENABLED schedule=$AUTODUCKS_UPDATE_SCHEDULE channel=$AUTODUCKS_UPDATE_CHANNEL pin=$AUTODUCKS_UPDATE_PIN mode=$AUTODUCKS_UPDATE_MODE auto_merge=$AUTODUCKS_UPDATE_AUTO_MERGE on_drift=$AUTODUCKS_UPDATE_ON_DRIFT notify_issue=$AUTODUCKS_UPDATE_NOTIFY_ISSUE source_repo=$AUTODUCKS_UPDATE_SOURCE_REPO version=$AUTODUCKS_VERSION"
  )
}

check() { # label update_json expected [version_field]
  local got
  got="$(resolved "$2" "${4:-}")"
  if [[ "$got" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 — expected '$3', got '$got'"
  fi
}

DEFAULTS="enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="

echo "── no update block → every documented default, no error ──"
check "no update block → defaults" 'null' "$DEFAULTS"
check "empty update block {} → defaults" '{}' "$DEFAULTS"

echo ""
echo "── AUTODUCKS_UPDATE_ENABLED (the \`// \` pitfall) ──"
check "enabled:false → AUTODUCKS_UPDATE_ENABLED=false (not true)" \
  '{"enabled":false}' \
  "enabled=false schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "enabled:true (explicit) → true" \
  '{"enabled":true}' "$DEFAULTS"

echo ""
echo "── clamp paths: invalid values fall back to default, load never fails ──"
check "auto_merge:major (illegal) → falls back to off" \
  '{"auto_merge":"major"}' "$DEFAULTS"
check "mode:nonsense → falls back to pr" \
  '{"mode":"nonsense"}' "$DEFAULTS"
check "channel:beta → falls back to stable" \
  '{"channel":"beta"}' "$DEFAULTS"
check "on_drift:explode → falls back to warn" \
  '{"on_drift":"explode"}' "$DEFAULTS"

echo ""
echo "── clamp paths: legal non-default values pass through unchanged ──"
check "channel:edge → edge" \
  '{"channel":"edge"}' \
  "enabled=true schedule=23 6 * * 1 channel=edge pin= mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "mode:commit → commit" \
  '{"mode":"commit"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=commit auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "mode:off → off" \
  '{"mode":"off"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=off auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "auto_merge:patch → patch" \
  '{"auto_merge":"patch"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=patch on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "auto_merge:minor → minor" \
  '{"auto_merge":"minor"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=minor on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "on_drift:abort → abort" \
  '{"on_drift":"abort"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=off on_drift=abort notify_issue= source_repo=deepducks/autoducks version="

echo ""
echo "── pin / notify_issue / schedule / source_repo pass-through ──"
check "pin:v1.2.3 → v1.2.3" \
  '{"pin":"v1.2.3"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin=v1.2.3 mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "pin:null (explicit) → empty" \
  '{"pin":null}' "$DEFAULTS"
check "notify_issue:42 → 42" \
  '{"notify_issue":42}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=off on_drift=warn notify_issue=42 source_repo=deepducks/autoducks version="
check "notify_issue:not-a-number → falls back to empty" \
  '{"notify_issue":"soon"}' "$DEFAULTS"
check "schedule:custom cron → passes through" \
  '{"schedule":"0 0 * * 0"}' \
  "enabled=true schedule=0 0 * * 0 channel=stable pin= mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=deepducks/autoducks version="
check "source_repo:custom → passes through" \
  '{"source_repo":"acme/fork"}' \
  "enabled=true schedule=23 6 * * 1 channel=stable pin= mode=pr auto_merge=off on_drift=warn notify_issue= source_repo=acme/fork version="

echo ""
echo "── AUTODUCKS_VERSION resolution order ──"
check "no version, no VERSION file → empty" 'null' "$DEFAULTS"

got="$(resolved 'null' '9.9.9')"
if [[ "$got" == *"version=9.9.9" ]]; then
  pass "autoducks.json.version present → wins"
else
  fail "autoducks.json.version present → expected version=9.9.9, got '$got'"
fi

write_config 'null'
printf '1.2.3\n' > "$SCRATCH_ROOT/VERSION"
got="$(
  export AUTODUCKS_ROOT="$SCRATCH_ROOT" AUTODUCKS_AGENT="" GITHUB_ACTIONS=true
  source "$LOAD_CONFIG"
  echo "$AUTODUCKS_VERSION"
)"
if [[ "$got" == "1.2.3" ]]; then
  pass "no autoducks.json.version, VERSION file present → falls back to VERSION file (whitespace trimmed)"
else
  fail "expected version=1.2.3 from VERSION file, got '$got'"
fi

write_config 'null' '9.9.9'
got="$(
  export AUTODUCKS_ROOT="$SCRATCH_ROOT" AUTODUCKS_AGENT="" GITHUB_ACTIONS=true
  source "$LOAD_CONFIG"
  echo "$AUTODUCKS_VERSION"
)"
if [[ "$got" == "9.9.9" ]]; then
  pass "autoducks.json.version wins over a present VERSION file"
else
  fail "expected version=9.9.9 (config overrides VERSION file), got '$got'"
fi
rm -f "$SCRATCH_ROOT/VERSION"

echo ""
echo "═══ update-config: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
