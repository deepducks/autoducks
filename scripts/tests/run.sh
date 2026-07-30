#!/usr/bin/env bash
# Runs every scripts/tests/*.test.sh and exits non-zero if any failed.
# Usage: bash scripts/tests/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
failed=()

for t in "$SCRIPT_DIR"/*.test.sh; do
  [[ -f "$t" ]] || continue
  echo "── $(basename "$t") ──"
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed+=("$(basename "$t")")
  fi
  echo ""
done

echo "scripts/tests: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  printf 'failed: %s\n' "${failed[@]}"
  exit 1
fi
