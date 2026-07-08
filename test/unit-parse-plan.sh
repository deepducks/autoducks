#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/parse-plan.py
# Run: bash test/unit-parse-plan.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$REPO_ROOT/.autoducks/core/robustness/parse-plan.py"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

run_parser() { # $1=body file → sets OUT (jsonl path) and RC
  OUT="$SCRATCH/tasks.jsonl"
  rm -f "$OUT"
  RC=0
  PARSE_ERROR_FILE="$SCRATCH/parse-error.md" \
    python3 "$PARSER" "$1" "$OUT" >/dev/null 2>&1 || RC=$?
}

echo "── priority-less headings (current format, D14) ──"
cat > "$SCRATCH/plan1.md" <<'MD'
## Plan

```yaml
waves:
  - name: Foundation
    tasks: [T1, T2]
```

## Tasks

### T1 — Create the config module

**Summary:** One sentence.

**Tasks:**
- [ ] do a thing

**Acceptance Criteria:**
- [ ] thing works

### T2 — Wire the module up

**Summary:** Another sentence.

**Tasks:**
- [ ] wire it

**Acceptance Criteria:**
- [ ] wired

## Progress

- [ ] #T1 Create the config module
- [ ] #T2 Wire the module up
MD
run_parser "$SCRATCH/plan1.md"
[[ "$RC" -eq 0 ]] && pass "parses cleanly (rc=0)" || fail "rc=$RC"
[[ "$(wc -l < "$OUT" | tr -d ' ')" == "2" ]] && pass "2 tasks emitted" || fail "task count: $(wc -l < "$OUT")"
TITLE=$(head -1 "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')
[[ "$TITLE" == "Create the config module" ]] && pass "title extracted" || fail "title: $TITLE"
LABELS=$(head -1 "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["labels"]))')
[[ "$LABELS" == "Task" ]] && pass "labels = [Task] only (no priority)" || fail "labels: $LABELS"

echo "── legacy priority suffix still tolerated ──"
cat > "$SCRATCH/plan2.md" <<'MD'
## Tasks

### T1 — Old style task `priority:P0`

**Summary:** Legacy heading.

**Tasks:**
- [ ] migrate

**Acceptance Criteria:**
- [ ] migrated
MD
run_parser "$SCRATCH/plan2.md"
[[ "$RC" -eq 0 ]] && pass "legacy heading parses (rc=0)" || fail "rc=$RC"
TITLE=$(head -1 "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')
[[ "$TITLE" == "Old style task" ]] && pass "priority suffix stripped from title" || fail "title: $TITLE"
LABELS=$(head -1 "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["labels"]))')
[[ "$LABELS" == "Task" ]] && pass "legacy priority NOT emitted as label" || fail "labels: $LABELS"

echo "── preserved-number headings (revision mode) ──"
cat > "$SCRATCH/plan3.md" <<'MD'
## Tasks

### 15 — Preserved task

**Summary:** Kept by number.

**Tasks:**
- [ ] keep

**Acceptance Criteria:**
- [ ] kept
MD
run_parser "$SCRATCH/plan3.md"
REF=$(head -1 "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ref"])')
[[ "$REF" == "15" ]] && pass "numeric ref preserved" || fail "ref: $REF"

echo "── failures still fail loudly ──"
cat > "$SCRATCH/plan4.md" <<'MD'
## Tasks

### T1 — Missing sections

**Summary:** Only a summary.
MD
run_parser "$SCRATCH/plan4.md"
[[ "$RC" -ne 0 ]] && pass "missing sections rejected" || fail "expected failure"
[[ -s "$SCRATCH/parse-error.md" ]] && pass "parse-error.md written" || fail "no parse-error.md"
if grep -q 'priority' "$SCRATCH/parse-error.md"; then
  fail "error hint still mentions priority"
else
  pass "error hint free of priority"
fi

echo ""
echo "═══ parse-plan: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
