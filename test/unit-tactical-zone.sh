#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/tactical-zone.sh
# Run: bash test/unit-tactical-zone.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Set AUTODUCKS_ROOT so the guard variable resolves (tactical-zone.sh doesn't
# need the full config; we only need AUTODUCKS_ROOT to be set so any nested
# source calls resolve paths correctly if ever added later).
export AUTODUCKS_ROOT="$REPO_ROOT/.autoducks"

# Source the helper under test
source "$REPO_ROOT/.autoducks/core/orchestration/tactical-zone.sh"

# Scratch directory cleaned up on exit
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
make_body() {
  # make_body <design_content> [<tactical_content>]
  # Writes a properly assembled body file to stdout.
  local design="$1"
  local tactical="${2:-}"
  local d_file="$SCRATCH/mb_design.md"
  local t_file="$SCRATCH/mb_tactical.md"
  local out="$SCRATCH/mb_out.md"
  printf '%s' "$design"  > "$d_file"
  printf '%s' "$tactical" > "$t_file"
  assemble_body "$d_file" "$t_file" "$out"
  cat "$out"
}

# ---------------------------------------------------------------------------
# Test 1: body_has_markers — no markers
# ---------------------------------------------------------------------------
echo "[1] body_has_markers — no markers"
printf 'Just some content\n' > "$SCRATCH/t1.md"
if body_has_markers "$SCRATCH/t1.md"; then
  fail "should return 1 (no markers) but returned 0"
else
  pass "returns 1 when no markers present"
fi

# ---------------------------------------------------------------------------
# Test 2: body_has_markers — both markers present
# ---------------------------------------------------------------------------
echo "[2] body_has_markers — both markers present"
{
  echo "Design content"
  echo "<!-- autoducks:tactical:begin -->"
  echo "Tactical content"
  echo "<!-- autoducks:tactical:end -->"
} > "$SCRATCH/t2.md"
if body_has_markers "$SCRATCH/t2.md"; then
  pass "returns 0 when both markers present"
else
  fail "should return 0 but returned 1"
fi

# ---------------------------------------------------------------------------
# Test 3: split_body — no markers (exit code 1, design = full body, tactical = empty)
# ---------------------------------------------------------------------------
echo "[3] split_body — no markers"
printf 'Full body content\n' > "$SCRATCH/t3_body.md"
RC=0
split_body "$SCRATCH/t3_body.md" "$SCRATCH/t3_design.md" "$SCRATCH/t3_tactical.md" || RC=$?
if [[ "$RC" -eq 1 ]]; then
  pass "returns exit code 1"
else
  fail "expected exit code 1, got $RC"
fi
if [[ "$(cat "$SCRATCH/t3_design.md")" == "Full body content" ]]; then
  pass "design_zone = full body"
else
  fail "design_zone mismatch: '$(cat "$SCRATCH/t3_design.md")'"
fi
if [[ ! -s "$SCRATCH/t3_tactical.md" ]]; then
  pass "tactical_zone = empty"
else
  fail "tactical_zone should be empty, got: '$(cat "$SCRATCH/t3_tactical.md")'"
fi

# ---------------------------------------------------------------------------
# Test 4: split_body — both markers, correct split
# ---------------------------------------------------------------------------
echo "[4] split_body — markers present"
{
  printf '## Design\n\nSome design.\n\n'
  printf '<!-- autoducks:tactical:begin -->\n'
  printf '## Plan\n\nTactical stuff.\n'
  printf '<!-- autoducks:tactical:end -->\n'
} > "$SCRATCH/t4_body.md"
split_body "$SCRATCH/t4_body.md" "$SCRATCH/t4_design.md" "$SCRATCH/t4_tactical.md"
DESIGN=$(cat "$SCRATCH/t4_design.md")
TACTICAL=$(cat "$SCRATCH/t4_tactical.md")
if echo "$DESIGN" | grep -q "## Design"; then
  pass "design zone contains design content"
else
  fail "design zone missing: '$DESIGN'"
fi
if echo "$DESIGN" | grep -q "<!-- autoducks:tactical"; then
  fail "design zone must not contain markers"
else
  pass "design zone does not contain markers"
fi
if echo "$TACTICAL" | grep -q "## Plan"; then
  pass "tactical zone contains tactical content"
else
  fail "tactical zone missing: '$TACTICAL'"
fi
if echo "$TACTICAL" | grep -q "<!-- autoducks:tactical"; then
  fail "tactical zone must not contain markers"
else
  pass "tactical zone does not contain markers"
fi

# ---------------------------------------------------------------------------
# Test 5: split_body — malformed: only begin marker (exit code 2)
# ---------------------------------------------------------------------------
echo "[5] split_body — malformed: only begin marker"
{
  echo "Content"
  echo "<!-- autoducks:tactical:begin -->"
  echo "More content"
} > "$SCRATCH/t5_body.md"
RC=0
split_body "$SCRATCH/t5_body.md" "$SCRATCH/t5_d.md" "$SCRATCH/t5_t.md" 2>/dev/null || RC=$?
if [[ "$RC" -eq 2 ]]; then
  pass "returns exit code 2 for malformed body"
else
  fail "expected exit code 2, got $RC"
fi

# ---------------------------------------------------------------------------
# Test 6: split_body — malformed: end before begin (exit code 2)
# ---------------------------------------------------------------------------
echo "[6] split_body — malformed: end before begin"
{
  echo "<!-- autoducks:tactical:end -->"
  echo "Content"
  echo "<!-- autoducks:tactical:begin -->"
} > "$SCRATCH/t6_body.md"
RC=0
split_body "$SCRATCH/t6_body.md" "$SCRATCH/t6_d.md" "$SCRATCH/t6_t.md" 2>/dev/null || RC=$?
if [[ "$RC" -eq 2 ]]; then
  pass "returns exit code 2 when end before begin"
else
  fail "expected exit code 2, got $RC"
fi

# ---------------------------------------------------------------------------
# Test 7: assemble_body — empty tactical zone emits both markers
# ---------------------------------------------------------------------------
echo "[7] assemble_body — empty tactical zone"
printf '## Design content\n' > "$SCRATCH/t7_design.md"
: > "$SCRATCH/t7_tactical.md"
assemble_body "$SCRATCH/t7_design.md" "$SCRATCH/t7_tactical.md" "$SCRATCH/t7_out.md"
OUT=$(cat "$SCRATCH/t7_out.md")
if echo "$OUT" | grep -q "<!-- autoducks:tactical:begin -->"; then
  pass "begin marker present with empty tactical zone"
else
  fail "begin marker missing: '$OUT'"
fi
if echo "$OUT" | grep -q "<!-- autoducks:tactical:end -->"; then
  pass "end marker present with empty tactical zone"
else
  fail "end marker missing: '$OUT'"
fi

# ---------------------------------------------------------------------------
# Test 8: split/assemble round-trip — bytewise stability
# ---------------------------------------------------------------------------
echo "[8] split/assemble round-trip"
DESIGN_CONTENT="## Problem Statement

This is the design zone.

### Sub-section

More content here."

TACTICAL_CONTENT="## Plan

\`\`\`yaml
waves:
  - name: Wave 1
    tasks: [101]
\`\`\`

## Progress

- [ ] #101 Do the thing \`P0\`"

# Build initial body using assemble_body
printf '%s\n' "$DESIGN_CONTENT" > "$SCRATCH/t8_design_init.md"
printf '%s\n' "$TACTICAL_CONTENT" > "$SCRATCH/t8_tactical_init.md"
assemble_body "$SCRATCH/t8_design_init.md" "$SCRATCH/t8_tactical_init.md" "$SCRATCH/t8_body1.md"

# Split body1 → design2 + tactical2
split_body "$SCRATCH/t8_body1.md" "$SCRATCH/t8_design2.md" "$SCRATCH/t8_tactical2.md"

# Reassemble → body2
assemble_body "$SCRATCH/t8_design2.md" "$SCRATCH/t8_tactical2.md" "$SCRATCH/t8_body2.md"

# body1 and body2 must be identical (idempotent)
if diff -q "$SCRATCH/t8_body1.md" "$SCRATCH/t8_body2.md" > /dev/null 2>&1; then
  pass "round-trip produces identical body (idempotent)"
else
  fail "round-trip body differs"
  diff "$SCRATCH/t8_body1.md" "$SCRATCH/t8_body2.md" || true
fi

# Tactical zone content is preserved
T2=$(cat "$SCRATCH/t8_tactical2.md")
if echo "$T2" | grep -q "waves:"; then
  pass "tactical zone YAML preserved after split"
else
  fail "tactical zone YAML missing after split: '$T2'"
fi

# Design zone does not contain tactical markers
D2=$(cat "$SCRATCH/t8_design2.md")
if echo "$D2" | grep -q "autoducks:tactical"; then
  fail "design zone contains tactical markers after split"
else
  pass "design zone clean after split"
fi

# Design zone content is preserved (sans trailing blank lines which are normalised)
if echo "$D2" | grep -q "## Problem Statement"; then
  pass "design zone content preserved"
else
  fail "design zone content missing: '$D2'"
fi

# ---------------------------------------------------------------------------
# Test 9: split_body — tolerates leading whitespace on markers
# ---------------------------------------------------------------------------
echo "[9] split_body — tolerates leading whitespace on markers"
{
  printf 'Design line\n'
  printf '  <!-- autoducks:tactical:begin -->\n'
  printf 'Tactical line\n'
  printf '  <!-- autoducks:tactical:end -->\n'
} > "$SCRATCH/t9_body.md"
RC=0
split_body "$SCRATCH/t9_body.md" "$SCRATCH/t9_d.md" "$SCRATCH/t9_t.md" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "exit code 0 with leading whitespace on markers"
else
  fail "expected exit code 0, got $RC"
fi
if grep -q "Design line" "$SCRATCH/t9_d.md"; then
  pass "design zone extracted correctly"
else
  fail "design zone wrong: '$(cat "$SCRATCH/t9_d.md")'"
fi
if grep -q "Tactical line" "$SCRATCH/t9_t.md"; then
  pass "tactical zone extracted correctly"
else
  fail "tactical zone wrong: '$(cat "$SCRATCH/t9_t.md")'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Unit Test Summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
