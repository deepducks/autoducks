#!/usr/bin/env bash
# Unit tests for .autoducks/migrations/0.2.0/migrate.sh: adds the `update`
# config block, `triggers.update`, and `security.per_agent.update` to a
# consumer autoducks.json only when absent, idempotently, appending prose to
# $AUTODUCKS_MIGRATION_REPORT only on the run that changes something, and
# never touching an existing `security.deny` list or existing per_agent
# entries.
# Run: bash test/unit-update-migration-0.2.0.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$REPO_ROOT/.autoducks/migrations/0.2.0/migrate.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture layout mirrors the real tree: migrate.sh discovers AUTODUCKS_ROOT
# by walking up from its own directory, so it must live at
# <root>/migrations/0.2.0/migrate.sh relative to <root>/autoducks.json.
AUTZ_ROOT="$SCRATCH/autoducks"
mkdir -p "$AUTZ_ROOT/migrations/0.2.0"
cp "$MIGRATE" "$AUTZ_ROOT/migrations/0.2.0/migrate.sh"

CONFIG="$AUTZ_ROOT/autoducks.json"
REPORT="$SCRATCH/report.md"

run_migration() {
  : > "$REPORT" 2>/dev/null || true
  AUTODUCKS_ROOT="$AUTZ_ROOT" AUTODUCKS_MIGRATION_REPORT="$REPORT" \
    bash "$AUTZ_ROOT/migrations/0.2.0/migrate.sh"
}

# run_migration_keep_report — like run_migration but does not truncate the
# report first, so successive calls accumulate (for idempotency checks).
run_migration_keep_report() {
  AUTODUCKS_ROOT="$AUTZ_ROOT" AUTODUCKS_MIGRATION_REPORT="$REPORT" \
    bash "$AUTZ_ROOT/migrations/0.2.0/migrate.sh"
}

echo "── first run: pre-0.2.0 config gains update/triggers.update/security.per_agent.update ──"
cat > "$CONFIG" <<'JSON'
{
  "providers": {"its": "github", "git": "github", "llm": "claude"},
  "defaults": {"model": "m", "effort": "high", "base_branch": "main", "merge_method": "auto"},
  "triggers": {"architect": [], "merge": []},
  "security": {
    "trusted_associations": ["OWNER", "MEMBER", "COLLABORATOR"],
    "deny": ["mallory"],
    "per_agent": {
      "revert": {"trusted_associations": ["OWNER", "MEMBER"]}
    }
  }
}
JSON
: > "$REPORT"
run_migration_keep_report

if jq -e '.update.enabled == true and .update.schedule == "23 6 * * 1" and .update.channel == "stable" and .update.pin == null and .update.mode == "pr" and .update.auto_merge == "off" and .update.on_drift == "warn" and .update.notify_issue == null and .update.source_repo == "deepducks/autoducks"' "$CONFIG" >/dev/null; then
  pass "update block added with documented defaults"
else
  fail "update block missing or wrong: $(jq -c '.update' "$CONFIG")"
fi

if jq -e '.triggers.update == []' "$CONFIG" >/dev/null; then
  pass "triggers.update added as empty array"
else
  fail "triggers.update missing/wrong: $(jq -c '.triggers' "$CONFIG")"
fi
if jq -e '.triggers.architect == [] and (.triggers | has("merge"))' "$CONFIG" >/dev/null; then
  pass "existing triggers entries untouched"
else
  fail "existing triggers entries clobbered: $(jq -c '.triggers' "$CONFIG")"
fi

if jq -e '.security.per_agent.update == {"trusted_associations": ["OWNER", "MEMBER"]}' "$CONFIG" >/dev/null; then
  pass "security.per_agent.update added"
else
  fail "security.per_agent.update missing/wrong: $(jq -c '.security.per_agent' "$CONFIG")"
fi
if jq -e '.security.per_agent.revert == {"trusted_associations": ["OWNER", "MEMBER"]}' "$CONFIG" >/dev/null; then
  pass "existing per_agent entry (revert) untouched"
else
  fail "existing per_agent entry clobbered: $(jq -c '.security.per_agent' "$CONFIG")"
fi
if jq -e '.security.deny == ["mallory"]' "$CONFIG" >/dev/null; then
  pass "existing security.deny list untouched"
else
  fail "security.deny list changed: $(jq -c '.security.deny' "$CONFIG")"
fi

if [[ -s "$REPORT" ]]; then
  pass "report gained prose on the changing run"
else
  fail "report is empty after a run that changed the config"
fi
if grep -qi 'update' "$REPORT"; then
  pass "report prose is human-readable and mentions what changed"
else
  fail "report prose missing/unclear: $(cat "$REPORT")"
fi

echo ""
echo "── idempotency: second run against the now-migrated config is a no-op ──"
cp "$CONFIG" "$SCRATCH/config-after-first-run.json"
report_lines_before="$(wc -l < "$REPORT")"
run_migration_keep_report
if diff -q "$SCRATCH/config-after-first-run.json" "$CONFIG" >/dev/null; then
  pass "second run produces byte-identical config"
else
  fail "second run changed the config"
fi
report_lines_after="$(wc -l < "$REPORT")"
if [[ "$report_lines_after" -eq "$report_lines_before" ]]; then
  pass "second run appends nothing to the report"
else
  fail "second run appended to the report ($report_lines_before → $report_lines_after lines)"
fi

echo ""
echo "── an already-present, hand-customized update block is left untouched ──"
cat > "$CONFIG" <<'JSON'
{
  "providers": {"its": "github", "git": "github", "llm": "claude"},
  "defaults": {"model": "m", "effort": "high", "base_branch": "main", "merge_method": "auto"},
  "update": {
    "enabled": false,
    "schedule": "0 0 * * 0",
    "channel": "edge",
    "pin": "v9.9.9",
    "mode": "commit",
    "auto_merge": "minor",
    "on_drift": "abort",
    "notify_issue": 42,
    "source_repo": "acme/fork"
  },
  "triggers": {"update": []},
  "security": {"per_agent": {"update": {"trusted_associations": ["OWNER"]}}}
}
JSON
cp "$CONFIG" "$SCRATCH/config-customized.json"
run_migration
if diff -q "$SCRATCH/config-customized.json" "$CONFIG" >/dev/null; then
  pass "hand-customized update/triggers.update/per_agent.update left untouched"
else
  fail "migration overwrote a hand-customized config: $(diff "$SCRATCH/config-customized.json" "$CONFIG" || true)"
fi
if [[ -s "$REPORT" ]]; then
  fail "report gained prose on a fully-already-migrated config"
else
  pass "report stays empty when nothing needed to change"
fi

echo ""
echo "═══ update-migration-0.2.0: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
