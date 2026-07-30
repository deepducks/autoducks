#!/usr/bin/env bash
# migrate.sh — 0.2.0
#
# Adds the `update` config block, `triggers.update`, and
# `security.per_agent.update` to a consumer autoducks.json, each only when
# absent. Idempotent: a second run against an already-migrated config makes
# no further change and appends nothing to the report.
#
# Required env: AUTODUCKS_ROOT (or discoverable by walking up from this
# script's own directory, same as load-config.sh / apply-plugins.sh).
# Optional env: AUTODUCKS_MIGRATION_REPORT — append-only report path.
set -euo pipefail

# ── Locate .autoducks root (mirrors load-config.sh / apply-plugins.sh) ──────
if [[ -z "${AUTODUCKS_ROOT:-}" ]]; then
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _depth=0
  while [[ "$_depth" -lt 10 ]]; do
    if [[ -f "$_dir/autoducks.json" ]]; then
      AUTODUCKS_ROOT="$_dir"
      break
    fi
    _dir="$(dirname "$_dir")"
    (( _depth++ )) || true
  done
fi
[[ -n "${AUTODUCKS_ROOT:-}" ]] || { echo "migrate 0.2.0: could not find autoducks.json" >&2; exit 1; }

CONFIG="$AUTODUCKS_ROOT/autoducks.json"
[[ -f "$CONFIG" ]] || { echo "migrate 0.2.0: $CONFIG not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "migrate 0.2.0: jq is required" >&2; exit 1; }

report() {
  [[ -n "${AUTODUCKS_MIGRATION_REPORT:-}" ]] || return 0
  printf '%s\n' "$1" >> "$AUTODUCKS_MIGRATION_REPORT"
}

changed=0
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.new"' EXIT
cp "$CONFIG" "$tmp"

if ! jq -e 'has("update")' "$tmp" >/dev/null; then
  jq '.update = {
    "enabled": true,
    "schedule": "23 6 * * 1",
    "channel": "stable",
    "pin": null,
    "mode": "pr",
    "auto_merge": "off",
    "on_drift": "warn",
    "notify_issue": null,
    "source_repo": "deepducks/autoducks"
  }' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  changed=1
  report "0.2.0: added the \`update\` config block with documented defaults."
fi

if ! jq -e '(.triggers // {}) | has("update")' "$tmp" >/dev/null; then
  jq '.triggers = ((.triggers // {}) + {"update": []})' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  changed=1
  report "0.2.0: added \`triggers.update\` (no custom aliases)."
fi

if ! jq -e '(.security.per_agent // {}) | has("update")' "$tmp" >/dev/null; then
  jq '.security = ((.security // {}) + {
    "per_agent": ((.security.per_agent // {}) + {
      "update": {"trusted_associations": ["OWNER", "MEMBER"]}
    })
  })' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  changed=1
  report "0.2.0: added \`security.per_agent.update\` (trusted_associations: OWNER, MEMBER)."
fi

if [[ "$changed" -eq 1 ]]; then
  mv "$tmp" "$CONFIG"
fi

exit 0
