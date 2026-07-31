#!/usr/bin/env bash
# Offline unit tests for .autoducks/core/config/interpolate-artifacts.sh
# (issue #157). No network, no gh/git. Run via scripts/tests/run.sh, or
# directly: bash scripts/tests/interpolate-artifacts.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/interpolate-artifacts.sh"

PASS=0
FAIL=0
pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

TMP_DIRS=()
cleanup() {
  local d
  if [[ ${#TMP_DIRS[@]} -gt 0 ]]; then
    for d in "${TMP_DIRS[@]}"; do
      rm -rf "$d"
    done
  fi
}
trap cleanup EXIT

new_dir() {
  NEW_DIR="$(mktemp -d)"
  TMP_DIRS+=("$NEW_DIR")
}

# -----------------------------------------------------------------------
echo "1) a body with no placeholders is byte-identical before and after interpolation"
new_dir; D="$NEW_DIR"
printf 'Plain body.\nNo placeholders here.\nTrailing newline above.\n' > "$D/body.md"
cp "$D/body.md" "$D/body-expected.md"
bash "$SCRIPT" render "$D/body.md" > "$D/out.md"
if cmp -s "$D/body-expected.md" "$D/out.md"; then
  pass "body with no {{...}} is byte-for-byte untouched"
else
  fail "body without placeholders was altered: $(diff "$D/body-expected.md" "$D/out.md")"
fi

echo "1b) a body with no trailing newline stays byte-identical too"
new_dir; D="$NEW_DIR"
printf 'No trailing newline' > "$D/body.md"
bash "$SCRIPT" render "$D/body.md" > "$D/out.md"
if cmp -s "$D/body.md" "$D/out.md"; then
  pass "body without a trailing newline is preserved exactly"
else
  fail "trailing-newline-free body was altered"
fi

# -----------------------------------------------------------------------
echo "2) a materialized part is spliced verbatim and NOT re-expanded, even if it contains {{...}}"
new_dir; D="$NEW_DIR"
printf 'Here is the referenced title verbatim: {{issue_title}}\n' > "$D/part-title.md"
printf 'A literal placeholder appears in the title text: {{issue_title}}\n' > "$D/part-desc.md"
cat > "$D/manifest.json" <<JSON
{"agent":"agent","parts":[
  {"id":"issue_title","file":"$D/part-desc.md","bytes":0}
]}
JSON
printf 'Body says: {{issue_title}}\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" render "$D/body.md" "$D/manifest.json")"
EXPECTED="Body says: A literal placeholder appears in the title text: {{issue_title}}"
if [[ "$OUT" == "$EXPECTED" ]]; then
  pass "part content containing {{issue_title}} is spliced verbatim, not re-expanded"
else
  fail "splice/re-expansion mismatch. got: [$OUT] want: [$EXPECTED]"
fi

# -----------------------------------------------------------------------
echo "3) an unknown/unmaterialized placeholder becomes the unavailable marker and emits a ::warning::"
new_dir; D="$NEW_DIR"
printf '{}' > "$D/empty-manifest.json"
printf 'Missing: {{no_such_part}} end.\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" render "$D/body.md" "$D/empty-manifest.json" 2>"$D/stderr.txt")"
if [[ "$OUT" == 'Missing: _(artifact "no_such_part" unavailable)_ end.' ]]; then
  pass "unknown placeholder replaced with the unavailable marker"
else
  fail "unknown placeholder handling wrong: got [$OUT]"
fi
if grep -q "::warning::" "$D/stderr.txt" && grep -q "no_such_part" "$D/stderr.txt"; then
  pass "unknown placeholder emits a ::warning:: naming the id"
else
  fail "no ::warning:: emitted for unknown placeholder: $(cat "$D/stderr.txt")"
fi

echo "3b) an id absent from the manifest (no manifest file at all) also gets the marker"
new_dir; D="$NEW_DIR"
printf 'X: {{nope}}\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" render "$D/body.md" "$D/does-not-exist.json" 2>/dev/null)"
if [[ "$OUT" == 'X: _(artifact "nope" unavailable)_' ]]; then
  pass "missing manifest file still yields the unavailable marker (no crash)"
else
  fail "missing manifest handling wrong: got [$OUT]"
fi

# -----------------------------------------------------------------------
echo "4) scalar placeholders resolve from env, independent of the manifest"
new_dir; D="$NEW_DIR"
printf '{}' > "$D/manifest.json"
printf 'Issue #{{issue_number}} in {{repo}} by {{actor}}. Steer: {{steering_prompt}}\n' > "$D/body.md"
STEER_B64="$(printf 'do the thing' | base64 | tr -d '\n')"
OUT="$(ISSUE_NUM=42 REPO=acme/widgets ACTOR=alice STEERING_PROMPT="$STEER_B64" \
  bash "$SCRIPT" render "$D/body.md" "$D/manifest.json" 2>"$D/stderr.txt")"
if [[ "$OUT" == "Issue #42 in acme/widgets by alice. Steer: do the thing" ]]; then
  pass "issue_number/repo/actor/steering_prompt resolve from env"
else
  fail "scalar resolution wrong: got [$OUT]"
fi
if [[ -s "$D/stderr.txt" ]]; then
  fail "scalar placeholders should not emit warnings: $(cat "$D/stderr.txt")"
else
  pass "no warnings emitted when scalars are all present"
fi

echo "4b) steering_prompt with no env var set resolves to empty, not an unavailable marker"
new_dir; D="$NEW_DIR"
printf '{}' > "$D/manifest.json"
printf 'Steer:[{{steering_prompt}}]\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" render "$D/body.md" "$D/manifest.json" 2>"$D/stderr.txt")"
if [[ "$OUT" == "Steer:[]" ]]; then
  pass "unset steering_prompt resolves to empty string, not a marker"
else
  fail "unset steering_prompt handling wrong: got [$OUT]"
fi
if [[ -s "$D/stderr.txt" ]]; then
  fail "unset-but-known scalar should not warn: $(cat "$D/stderr.txt")"
else
  pass "no warning for an unset-but-known scalar id"
fi

# -----------------------------------------------------------------------
echo "5) 'list' mode prints every distinct {{...}} id, in first-seen order, deduplicated"
new_dir; D="$NEW_DIR"
printf 'A {{foo}} B {{bar}} C {{foo}} D {{baz}}\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" list "$D/body.md")"
EXPECTED=$'foo\nbar\nbaz'
if [[ "$OUT" == "$EXPECTED" ]]; then
  pass "list mode returns distinct ids in first-seen order"
else
  fail "list mode mismatch: got [$OUT] want [$EXPECTED]"
fi

echo "5b) 'list' mode on a body with no placeholders prints nothing"
new_dir; D="$NEW_DIR"
printf 'Nothing to see here.\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" list "$D/body.md")"
if [[ -z "$OUT" ]]; then
  pass "list mode on a placeholder-free body prints nothing"
else
  fail "expected empty output, got [$OUT]"
fi

# -----------------------------------------------------------------------
echo "6) an unterminated '{{' is left as literal text, not consumed or crashed on"
new_dir; D="$NEW_DIR"
printf 'Broken {{oops\n' > "$D/body.md"
OUT="$(bash "$SCRIPT" render "$D/body.md" 2>/dev/null)"
if [[ "$OUT" == $'Broken {{oops' ]]; then
  pass "unterminated {{ is passed through literally"
else
  fail "unterminated {{ handling wrong: got [$OUT]"
fi

# -----------------------------------------------------------------------
echo ""
echo "=== interpolate-artifacts (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
