#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/validate-triage-decisions.py
# Run: bash test/unit-validate-triage-decisions.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/.autoducks/core/robustness/validate-triage-decisions.py"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

run_validator() { # $1=decisions file → sets OUT, REPORT, RC
  OUT="$SCRATCH/validated-out.json"
  REPORT="$SCRATCH/report.json"
  rm -f "$OUT" "$REPORT"
  RC=0
  REPORT_FILE="$REPORT" \
    python3 "$VALIDATOR" "$1" "$OUT" "high" "5" >/dev/null 2>&1 || RC=$?
}

echo "── well-formed classifications entry is accepted and canonicalized ──"
cat > "$SCRATCH/decisions1.json" <<'JSON'
{
  "priorities": [],
  "duplicates": [],
  "classifications": [
    {"issue": 42, "kind": "bug", "rationale": "reproduces a crash"}
  ]
}
JSON
run_validator "$SCRATCH/decisions1.json"
[[ "$RC" -eq 0 ]] && pass "run exits 0" || fail "rc=$RC"
KIND=$(python3 -c 'import json; print(json.load(open("'"$OUT"'"))["classifications"][0]["kind"])')
[[ "$KIND" == "Bug" ]] && pass "kind canonicalized bug -> Bug" || fail "kind: $KIND"
ISSUE=$(python3 -c 'import json; print(json.load(open("'"$OUT"'"))["classifications"][0]["issue"])')
[[ "$ISSUE" == "42" ]] && pass "issue preserved" || fail "issue: $ISSUE"
ACCEPTED=$(python3 -c 'import json; print(json.load(open("'"$REPORT"'"))["accepted_classifications"])')
[[ "$ACCEPTED" == "1" ]] && pass "report accepted_classifications = 1" || fail "accepted_classifications: $ACCEPTED"

echo "── missing classifications key yields [] ──"
cat > "$SCRATCH/decisions2.json" <<'JSON'
{
  "priorities": [],
  "duplicates": []
}
JSON
run_validator "$SCRATCH/decisions2.json"
[[ "$RC" -eq 0 ]] && pass "run exits 0" || fail "rc=$RC"
COUNT=$(python3 -c 'import json; print(len(json.load(open("'"$OUT"'"))["classifications"]))')
[[ "$COUNT" == "0" ]] && pass "classifications is empty array" || fail "count: $COUNT"

echo "── malformed entries are dropped without failing the run ──"
cat > "$SCRATCH/decisions3.json" <<'JSON'
{
  "priorities": [],
  "duplicates": [],
  "classifications": [
    {"issue": 1, "kind": "bug"},
    {"issue": 2, "kind": "wontfix"},
    "not-an-object",
    {"issue": "abc", "kind": "feature"},
    {"issue": 1, "kind": "feature"}
  ]
}
JSON
run_validator "$SCRATCH/decisions3.json"
[[ "$RC" -eq 0 ]] && pass "run exits 0 despite malformed entries" || fail "rc=$RC"
ACCEPTED_COUNT=$(python3 -c 'import json; print(len(json.load(open("'"$OUT"'"))["classifications"]))')
[[ "$ACCEPTED_COUNT" == "1" ]] && pass "only the one good entry accepted" || fail "accepted count: $ACCEPTED_COUNT"
DROPPED_COUNT=$(python3 -c 'import json; print(len(json.load(open("'"$REPORT"'"))["dropped"]))')
[[ "$DROPPED_COUNT" == "4" ]] && pass "4 bad entries dropped into report" || fail "dropped count: $DROPPED_COUNT"
REASONS=$(python3 -c 'import json; print(" | ".join(d["reason"] for d in json.load(open("'"$REPORT"'"))["dropped"]))')
echo "$REASONS" | grep -q "outside Bug|Feature" && pass "bad kind reason present" || fail "reasons: $REASONS"
echo "$REASONS" | grep -q "not an object" && pass "non-object entry reason present" || fail "reasons: $REASONS"
echo "$REASONS" | grep -q "missing/invalid \`issue\`" && pass "invalid issue reason present" || fail "reasons: $REASONS"
echo "$REASONS" | grep -q "duplicate entry" && pass "duplicate issue reason present" || fail "reasons: $REASONS"

echo "── priorities/duplicates outputs unaffected ──"
cat > "$SCRATCH/decisions4.json" <<'JSON'
{
  "priorities": [{"issue": 7, "priority": "high"}],
  "duplicates": [{"canonical": 8, "duplicates": [9], "confidence": "high"}],
  "classifications": [{"issue": 10, "kind": "Feature"}]
}
JSON
run_validator "$SCRATCH/decisions4.json"
[[ "$RC" -eq 0 ]] && pass "run exits 0" || fail "rc=$RC"
PRIO_COUNT=$(python3 -c 'import json; print(len(json.load(open("'"$OUT"'"))["priorities"]))')
[[ "$PRIO_COUNT" == "1" ]] && pass "priorities still validated" || fail "priorities count: $PRIO_COUNT"
DUP_COUNT=$(python3 -c 'import json; print(len(json.load(open("'"$OUT"'"))["duplicates"]))')
[[ "$DUP_COUNT" == "1" ]] && pass "duplicates still validated" || fail "duplicates count: $DUP_COUNT"

echo ""
echo "═══ validate-triage-decisions: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
