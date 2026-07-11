#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/design-sections.sh
# Run: bash test/unit-design-sections.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

export AUTODUCKS_ROOT="$REPO_ROOT/.autoducks"

# Source the helper under test
source "$REPO_ROOT/.autoducks/core/orchestration/design-sections.sh"

# Scratch directory cleaned up on exit
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Test 1: source guard — sourcing a second time is a no-op, not an error
# ---------------------------------------------------------------------------
echo "[1] double-source guard"
if source "$REPO_ROOT/.autoducks/core/orchestration/design-sections.sh"; then
  pass "second source is a no-op (readonly re-declare did not error)"
else
  fail "second source errored"
fi

# ---------------------------------------------------------------------------
# Test 2: has_markers — no markers present
# ---------------------------------------------------------------------------
echo "[2] has_markers — no markers"
printf 'Just some content, no sections.\n' > "$SCRATCH/t2.md"
if design_sections::has_markers "$SCRATCH/t2.md"; then
  fail "should return 1 (no markers) but returned 0"
else
  pass "returns 1 when no section markers present"
fi

# ---------------------------------------------------------------------------
# Test 3: has_markers — one section marker pair present
# ---------------------------------------------------------------------------
echo "[3] has_markers — one section present"
{
  echo "<!-- autoducks:design:problem_statement:begin -->"
  echo "The problem."
  echo "<!-- autoducks:design:problem_statement:end -->"
} > "$SCRATCH/t3.md"
if design_sections::has_markers "$SCRATCH/t3.md"; then
  pass "returns 0 when a section marker pair is present"
else
  fail "should return 0 but returned 1"
fi

# ---------------------------------------------------------------------------
# Test 4: wrap — zero recognized headings passes through unchanged
# ---------------------------------------------------------------------------
echo "[4] wrap — zero recognized headings"
printf 'Random prose.\n\nNo headings here at all.\n' > "$SCRATCH/t4_in.md"
design_sections::wrap "$SCRATCH/t4_in.md" "$SCRATCH/t4_out.md"
if diff -q "$SCRATCH/t4_in.md" "$SCRATCH/t4_out.md" > /dev/null 2>&1; then
  pass "body with no recognized headings passes through unchanged"
else
  fail "body was altered despite no recognized headings"
  diff "$SCRATCH/t4_in.md" "$SCRATCH/t4_out.md" || true
fi

# ---------------------------------------------------------------------------
# Test 5: wrap — `## Heading` form recognized and wrapped
# ---------------------------------------------------------------------------
echo "[5] wrap — ## heading form"
{
  printf '## Problem Statement\n'
  printf 'Users cannot do the thing.\n'
} > "$SCRATCH/t5_in.md"
design_sections::wrap "$SCRATCH/t5_in.md" "$SCRATCH/t5_out.md"
if grep -qE '^<!-- autoducks:design:problem_statement:begin -->$' "$SCRATCH/t5_out.md"; then
  pass "## heading form produces a begin marker"
else
  fail "no begin marker produced: $(cat "$SCRATCH/t5_out.md")"
fi
if grep -q "Users cannot do the thing." "$SCRATCH/t5_out.md"; then
  pass "## heading form content preserved"
else
  fail "content missing after ## wrap"
fi

# ---------------------------------------------------------------------------
# Test 6: wrap — stand-alone `**Heading**` form recognized and wrapped
# ---------------------------------------------------------------------------
echo "[6] wrap — **bold** heading form"
{
  printf '**Proposed Solution**\n'
  printf 'Build the thing.\n'
} > "$SCRATCH/t6_in.md"
design_sections::wrap "$SCRATCH/t6_in.md" "$SCRATCH/t6_out.md"
if grep -qE '^<!-- autoducks:design:proposed_solution:begin -->$' "$SCRATCH/t6_out.md"; then
  pass "**bold** heading form produces a begin marker"
else
  fail "no begin marker produced: $(cat "$SCRATCH/t6_out.md")"
fi
if grep -q "Build the thing." "$SCRATCH/t6_out.md"; then
  pass "**bold** heading form content preserved"
else
  fail "content missing after ** wrap"
fi

# ---------------------------------------------------------------------------
# Test 7: wrap — preamble above the first recognized heading is preserved
# verbatim
# ---------------------------------------------------------------------------
echo "[7] wrap — preamble preservation"
{
  printf 'This is unstructured design preamble.\n'
  printf 'It should survive untouched.\n'
  printf '\n'
  printf '## Problem Statement\n'
  printf 'The actual problem.\n'
} > "$SCRATCH/t7_in.md"
design_sections::wrap "$SCRATCH/t7_in.md" "$SCRATCH/t7_out.md"
PREAMBLE=$(sed -n '1,3p' "$SCRATCH/t7_out.md")
if [[ "$PREAMBLE" == "$(printf 'This is unstructured design preamble.\nIt should survive untouched.\n')" ]]; then
  pass "preamble text preserved verbatim before first marker"
else
  fail "preamble mismatch: '$PREAMBLE'"
fi
if grep -qE '^<!-- autoducks:design:problem_statement:begin -->$' "$SCRATCH/t7_out.md"; then
  pass "section marker follows preamble"
else
  fail "no section marker found after preamble"
fi

# ---------------------------------------------------------------------------
# Test 8: wrap → extract round-trip for all six canonical sections, mixing
# ## and **bold** heading forms
# ---------------------------------------------------------------------------
echo "[8] wrap→extract round-trip — all six sections"
{
  printf '## Problem Statement\n'
  printf 'Problem content.\n\n'
  printf '**Proposed Solution**\n'
  printf 'Solution content.\n\n'
  printf '## Technical Design\n'
  printf 'Technical content.\n\n'
  printf '**Dependencies**\n'
  printf 'Dependency content.\n\n'
  printf '## Constraints\n'
  printf 'Constraint content.\n\n'
  printf '**Out of Scope**\n'
  printf 'Out of scope content.\n'
} > "$SCRATCH/t8_in.md"
design_sections::wrap "$SCRATCH/t8_in.md" "$SCRATCH/t8_wrapped.md"

declare -A EXPECTED=(
  [problem_statement]="Problem content."
  [proposed_solution]="Solution content."
  [technical_design]="Technical content."
  [dependencies]="Dependency content."
  [constraints]="Constraint content."
  [out_of_scope]="Out of scope content."
)
ALL_OK=1
for id in problem_statement proposed_solution technical_design dependencies constraints out_of_scope; do
  design_sections::extract "$SCRATCH/t8_wrapped.md" "$id" "$SCRATCH/t8_extract_$id.md"
  if ! grep -q "${EXPECTED[$id]}" "$SCRATCH/t8_extract_$id.md"; then
    fail "round-trip failed for '$id': expected '${EXPECTED[$id]}', got '$(cat "$SCRATCH/t8_extract_$id.md")'"
    ALL_OK=0
  fi
done
if [[ "$ALL_OK" -eq 1 ]]; then
  pass "all six sections round-trip through wrap→extract"
fi

# ---------------------------------------------------------------------------
# Test 9: extract — section absent from body writes an empty file and
# returns success (never errors)
# ---------------------------------------------------------------------------
echo "[9] extract — missing section"
{
  echo "<!-- autoducks:design:problem_statement:begin -->"
  echo "Only this section is present."
  echo "<!-- autoducks:design:problem_statement:end -->"
} > "$SCRATCH/t9_body.md"
RC=0
design_sections::extract "$SCRATCH/t9_body.md" "constraints" "$SCRATCH/t9_out.md" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "extract of an absent section returns success"
else
  fail "expected exit code 0, got $RC"
fi
if [[ ! -s "$SCRATCH/t9_out.md" ]]; then
  pass "extract of an absent section writes an empty file"
else
  fail "expected empty file, got: '$(cat "$SCRATCH/t9_out.md")'"
fi

# ---------------------------------------------------------------------------
# Test 10: extract — a marker string mentioned inside another section's
# prose must not be mistaken for a real sentinel (regression: unanchored
# match corrupting the split)
# ---------------------------------------------------------------------------
echo "[10] extract — marker mentioned in prose is not a sentinel"
{
  printf '<!-- autoducks:design:technical_design:begin -->\n'
  printf 'We wrap sections with `<!-- autoducks:design:dependencies:begin -->` as the sentinel.\n'
  printf 'This whole paragraph is technical_design content that MUST be preserved.\n'
  printf '<!-- autoducks:design:technical_design:end -->\n'
  printf '<!-- autoducks:design:dependencies:begin -->\n'
  printf 'real dependency content\n'
  printf '<!-- autoducks:design:dependencies:end -->\n'
} > "$SCRATCH/t10_body.md"
design_sections::extract "$SCRATCH/t10_body.md" "technical_design" "$SCRATCH/t10_td.md"
design_sections::extract "$SCRATCH/t10_body.md" "dependencies" "$SCRATCH/t10_dep.md"
if grep -q "MUST be preserved" "$SCRATCH/t10_td.md"; then
  pass "technical_design keeps content that mentions another section's marker"
else
  fail "technical_design truncated at the mention: '$(cat "$SCRATCH/t10_td.md")'"
fi
if grep -q "MUST be preserved" "$SCRATCH/t10_dep.md"; then
  fail "technical_design content leaked into dependencies section"
else
  pass "dependencies section free of leaked technical_design content"
fi
if grep -q "real dependency content" "$SCRATCH/t10_dep.md"; then
  pass "dependencies section holds its real content"
else
  fail "dependencies section missing real content: '$(cat "$SCRATCH/t10_dep.md")'"
fi

# ---------------------------------------------------------------------------
# Test 11: list — unmarked body prints nothing
# ---------------------------------------------------------------------------
echo "[11] list — unmarked body"
printf 'No sections here.\n' > "$SCRATCH/t11.md"
LIST_OUT=$(design_sections::list "$SCRATCH/t11.md")
if [[ -z "$LIST_OUT" ]]; then
  pass "list prints nothing for an unmarked body"
else
  fail "expected empty output, got: '$LIST_OUT'"
fi

# ---------------------------------------------------------------------------
# Test 12: list — marked body prints present ids in canonical order
# ---------------------------------------------------------------------------
echo "[12] list — marked body prints present ids in canonical order"
{
  printf '<!-- autoducks:design:constraints:begin -->\n'
  printf 'Constraint content.\n'
  printf '<!-- autoducks:design:constraints:end -->\n'
  printf '<!-- autoducks:design:problem_statement:begin -->\n'
  printf 'Problem content.\n'
  printf '<!-- autoducks:design:problem_statement:end -->\n'
} > "$SCRATCH/t12.md"
LIST_OUT=$(design_sections::list "$SCRATCH/t12.md")
EXPECTED_LIST=$'problem_statement\nconstraints'
if [[ "$LIST_OUT" == "$EXPECTED_LIST" ]]; then
  pass "list prints present ids in canonical (not file) order"
else
  fail "expected '$EXPECTED_LIST', got '$LIST_OUT'"
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
