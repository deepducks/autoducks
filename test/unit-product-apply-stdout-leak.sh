#!/usr/bin/env bash
# Regression test for the product/post.sh apply-loop stdout leak (Task #992,
# fixed by #1002 — "Isolate the JSON data channel in all three post.sh apply
# loops").
#
# Before the fix, each of the three apply loops (priorities, duplicates,
# classifications) built its result array with:
#   RESULT=$(jq -s '.' < <( while ...; do ...mutating calls...; jq -n '{...}'; done ))
# Several of the mutating calls (`gh label create`, `fold_duplicate::reference`,
# `classify_label::apply`) were not fully redirected to /dev/null, so any
# stdout they produced (an issue URL, a "✓ Label ... created" line — exactly
# what `gh` prints on a real mutation) landed in the same stream as the
# `jq -n` JSON objects. `jq -s '.'` then choked on the mixed stream (exit 5),
# which `set -euo pipefail` turned into a hard failure of the whole run.
# T1 fixed this by routing only `jq -n`'s output through a private collector
# file, so side-effect stdout can never contaminate the slurp.
#
# This test stubs the mutating helpers to leak a realistic line to stdout
# (mimicking the pre-fix behavior of real `gh`) and drives all three apply
# loops via a fixture. It must fail against the pre-fix post.sh and pass
# against the T1-fixed one.
#
# Style follows test/unit-idempotency.sh and test/unit-classify-label.sh:
# PASS/FAIL counters, mktemp -d scratch, trap ... EXIT, an isolated marker
# dir via RUNNER_TEMP/GITHUB_RUN_ID, no network. One deliberate deviation:
# post.sh never persists APPLIED_PRIORITIES_JSON / FLAGGED_DUPLICATES_JSON /
# APPLIED_CLASSIFICATIONS_JSON anywhere external (no GITHUB_OUTPUT, no file),
# and it `exit`s on every path (success and the ERR trap alike) — so instead
# of running it as an opaque subprocess, this test `source`s it inside an
# isolated subshell with `exit` shadowed by a function that dumps those
# still-in-scope locals to disk right before actually exiting.
#
# Run: bash test/unit-product-apply-stdout-leak.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_POST="$REPO_ROOT/.autoducks/agents/product/post.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
cleanup() {
  rm -rf "$SCRATCH"
  rm -f /tmp/triage-decisions.json /tmp/triage-decisions.valid.json /tmp/triage-validation-report.json
}
trap cleanup EXIT

REPO_NAME="acme/widgets"
MARKER_RUN_ID="apply-stdout-leak"
MOCK_ISSUE_DIR="$SCRATCH/issues"
GH_LOG="$SCRATCH/gh.log"
mkdir -p "$MOCK_ISSUE_DIR"
: > "$GH_LOG"

# ── Scratch AUTODUCKS_ROOT: a copy of the real .autoducks tree with the
# leak-prone helpers replaced by realistic stdout-leaking stubs ───────────
# post.sh resolves these purely through $AUTODUCKS_ROOT (exported by the
# real, unmodified load-config.sh once we override it in the environment),
# so everything else — validate-triage-decisions.py, its::get_issue,
# its::set_priority, delivery_phase::started, autoducks.json defaults —
# stays the real, unmodified implementation.
SCRATCH_ROOT="$SCRATCH/autoducks-root"
cp -r "$REPO_ROOT/.autoducks" "$SCRATCH_ROOT"

# classify_label::apply stub — leaks a "✓ Label ... created" confirmation
# plus its::add_label's issue-URL leak, exactly like the real
# classify-label.sh does when its stdout isn't redirected.
cat > "$SCRATCH_ROOT/core/config/classify-label.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${_CLASSIFY_LABEL_SH_LOADED:-}" ]] && return 0
readonly _CLASSIFY_LABEL_SH_LOADED=1
classify_label::apply() {
  local issue="$1" kind="$2"
  echo "✓ Label \"$kind\" created"
  its::add_label "$issue" "$kind"
  return 0
}
EOF

# fold_duplicate::reference stub — leaks the same shape of output the real
# fold-duplicate.sh produces via `gh label create` + its::add_label +
# its::close_issue when unredirected.
cat > "$SCRATCH_ROOT/core/orchestration/fold-duplicate.sh" <<'EOF'
#!/usr/bin/env bash
fold_duplicate::reference() {
  local dup="$1" canonical="$2"
  echo "✓ Label \"Duplicate\" created"
  its::add_label "$dup" "Duplicate"
  its::close_issue "$dup" "Duplicate of #$canonical." "not_planned"
  return 0
}
EOF

# its::add_label / its::close_issue / its::comment_issue stubs — each leaks
# a realistic issue URL to stdout (what the real `gh issue edit` / `gh issue
# close` / `gh issue comment` print on success) and returns 0.
cat > "$SCRATCH_ROOT/providers/its/github/add-label.sh" <<'EOF'
#!/usr/bin/env bash
its::add_label() {
  echo "https://github.com/${REPO}/issues/$1"
  return 0
}
EOF

cat > "$SCRATCH_ROOT/providers/its/github/close-issue.sh" <<'EOF'
#!/usr/bin/env bash
its::close_issue() {
  echo "https://github.com/${REPO}/issues/$1"
  return 0
}
EOF

cat > "$SCRATCH_ROOT/providers/its/github/comment-issue.sh" <<'EOF'
#!/usr/bin/env bash
its::comment_issue() {
  echo "https://github.com/${REPO}/issues/$1#issuecomment-9001"
  return 0
}
EOF

# ── gh shim ────────────────────────────────────────────────────────────
# Handles what's left after the its::*/classify_label/fold_duplicate stubs
# above: `gh issue view` (its::get_issue + post.sh's own closed-guard) and
# `gh label create` (the priorities loop's own direct call, which leaked a
# "✓ Label ... created" line pre-fix).
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{ echo "=== gh $* ==="; } >> "$GH_LOG"

case "$1 $2" in
  "issue view")
    id="$3"
    json_field=""
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "--json" ]] && json_field="$arg"
      prev="$arg"
    done
    file="$MOCK_ISSUE_DIR/$id.json"
    [[ -f "$file" ]] || file=/dev/null
    if [[ "$json_field" == "closed" ]]; then
      jq -r '.closed // false' "$file" 2>/dev/null || echo false
    else
      cat "$file" 2>/dev/null || echo '{}'
    fi
    ;;
  "label create")
    echo "✓ Label \"$3\" created"
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# ── Fixtures: one open issue per apply loop ──────────────────────────────
jq -n '{title: "Slow API response", body: "...", labels: [], author: "alice", closed: false}' \
  > "$MOCK_ISSUE_DIR/101.json"
jq -n '{title: "Duplicate bug report", body: "...", labels: [], author: "bob", closed: false}' \
  > "$MOCK_ISSUE_DIR/202.json"
jq -n '{title: "Crash on startup", body: "...", labels: [], author: "carol", closed: false}' \
  > "$MOCK_ISSUE_DIR/301.json"

rm -f /tmp/triage-decisions.json /tmp/triage-decisions.valid.json /tmp/triage-validation-report.json
jq -n '{
  priorities: [{issue: 101, priority: "High", rationale: "blocks release"}],
  duplicates: [{canonical: 201, duplicates: [202], confidence: "high", rationale: "same report"}],
  classifications: [{issue: 301, kind: "Bug", rationale: "reproduces a crash"}]
}' > /tmp/triage-decisions.json

# run_post OUT_DIR — sources the real product/post.sh in an isolated
# subshell (scratch AUTODUCKS_ROOT + gh shim on PATH, sweep scope, labels
# priority backend, no network) and dumps its apply-loop result variables
# to OUT_DIR right before it exits. Returns post.sh's own exit code.
run_post() {
  local out_dir="$1"
  mkdir -p "$out_dir"
  (
    export PATH="$SCRATCH/bin:$PATH"
    export AUTODUCKS_ROOT="$SCRATCH_ROOT"
    export RUNNER_TEMP="$SCRATCH"
    export GITHUB_RUN_ID="$MARKER_RUN_ID"
    export GH_LOG="$GH_LOG"
    export MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR"
    export GITHUB_ACTIONS=true
    export GH_TOKEN=t
    export REPO="$REPO_NAME"
    export RUN_ID=1
    export AUTODUCKS_PRIORITY_BACKEND=labels
    export AUTODUCKS_SUB_ISSUES_STATUS=unavailable
    export DRY_RUN=false
    export GITHUB_STEP_SUMMARY="$SCRATCH/summary.md"
    unset ISSUE_NUM COMMENT_ISSUE_NUM COMMENT_ID EVENT_NAME 2>/dev/null || true

    exit() {
      local rc="${1:-0}"
      printf '%s' "$rc" > "$out_dir/rc"
      printf '%s' "${APPLIED_PRIORITIES_JSON:-}" > "$out_dir/applied_priorities.json"
      printf '%s' "${FLAGGED_DUPLICATES_JSON:-}" > "$out_dir/flagged_duplicates.json"
      printf '%s' "${APPLIED_CLASSIFICATIONS_JSON:-}" > "$out_dir/applied_classifications.json"
      printf '%s' "${APPLIED_PRIORITY_COUNT:-}" > "$out_dir/applied_priority_count"
      printf '%s' "${FLAGGED_COUNT:-}" > "$out_dir/flagged_count"
      printf '%s' "${APPLIED_CLASSIFICATION_COUNT:-}" > "$out_dir/applied_classification_count"
      builtin exit "$rc"
    }

    source "$PRODUCT_POST"
  ) > "$out_dir/stdout.log" 2> "$out_dir/stderr.log"
}

echo "── product/post.sh apply loops survive leaking gh/its stdout ──"

OUT="$SCRATCH/out"
RC=0
run_post "$OUT" || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "run exits 0 (not 5 — the jq -s parse-error code a leaked line triggers)" \
  || fail "run exited $RC, expected 0; stderr: $(tail -10 "$OUT/stderr.log" 2>/dev/null)"

read_out() { cat "$OUT/$1" 2>/dev/null || echo ""; }

APPLIED_PRIORITIES=$(read_out applied_priorities.json)
FLAGGED_DUPLICATES=$(read_out flagged_duplicates.json)
APPLIED_CLASSIFICATIONS=$(read_out applied_classifications.json)

for pair in "applied_priorities.json:$APPLIED_PRIORITIES" "flagged_duplicates.json:$FLAGGED_DUPLICATES" "applied_classifications.json:$APPLIED_CLASSIFICATIONS"; do
  name="${pair%%:*}"
  content="${pair#*:}"
  if echo "$content" | grep -qE 'https://github\.com|✓ Label'; then
    fail "$name still contains leaked URL/✓ text: $content"
  else
    pass "$name has no leaked URL/✓ text"
  fi
done

if jq -e '.' >/dev/null 2>&1 <<<"$APPLIED_PRIORITIES"; then
  pass "APPLIED_PRIORITIES_JSON is valid JSON"
  [[ "$(jq -c '.' <<<"$APPLIED_PRIORITIES")" == '[{"issue":101,"priority":"High"}]' ]] \
    && pass "APPLIED_PRIORITIES_JSON contains exactly the intended entry" \
    || fail "APPLIED_PRIORITIES_JSON unexpected content: $APPLIED_PRIORITIES"
else
  fail "APPLIED_PRIORITIES_JSON is not valid JSON: $APPLIED_PRIORITIES"
fi

if jq -e '.' >/dev/null 2>&1 <<<"$FLAGGED_DUPLICATES"; then
  pass "FLAGGED_DUPLICATES_JSON is valid JSON"
  [[ "$(jq -c '.' <<<"$FLAGGED_DUPLICATES")" == '[{"canonical":201,"duplicate":202}]' ]] \
    && pass "FLAGGED_DUPLICATES_JSON contains exactly the intended entry" \
    || fail "FLAGGED_DUPLICATES_JSON unexpected content: $FLAGGED_DUPLICATES"
else
  fail "FLAGGED_DUPLICATES_JSON is not valid JSON: $FLAGGED_DUPLICATES"
fi

if jq -e '.' >/dev/null 2>&1 <<<"$APPLIED_CLASSIFICATIONS"; then
  pass "APPLIED_CLASSIFICATIONS_JSON is valid JSON"
  [[ "$(jq -c '.' <<<"$APPLIED_CLASSIFICATIONS")" == '[{"issue":301,"kind":"Bug"}]' ]] \
    && pass "APPLIED_CLASSIFICATIONS_JSON contains exactly the intended entry" \
    || fail "APPLIED_CLASSIFICATIONS_JSON unexpected content: $APPLIED_CLASSIFICATIONS"
else
  fail "APPLIED_CLASSIFICATIONS_JSON is not valid JSON: $APPLIED_CLASSIFICATIONS"
fi

APPLIED_PRIORITY_COUNT=$(read_out applied_priority_count)
FLAGGED_COUNT=$(read_out flagged_count)
APPLIED_CLASSIFICATION_COUNT=$(read_out applied_classification_count)

[[ "$APPLIED_PRIORITY_COUNT" == "1" ]] \
  && pass "APPLIED_PRIORITY_COUNT == 1" || fail "APPLIED_PRIORITY_COUNT: '$APPLIED_PRIORITY_COUNT'"
[[ "$FLAGGED_COUNT" == "1" ]] \
  && pass "FLAGGED_COUNT == 1 (DUPLICATE_GROUP_COUNT > 0 path exercised)" || fail "FLAGGED_COUNT: '$FLAGGED_COUNT'"
[[ "$APPLIED_CLASSIFICATION_COUNT" == "1" ]] \
  && pass "APPLIED_CLASSIFICATION_COUNT == 1" || fail "APPLIED_CLASSIFICATION_COUNT: '$APPLIED_CLASSIFICATION_COUNT'"

grep -q '=== gh label create' "$GH_LOG" \
  && pass "sanity: the leaking gh label create path was actually exercised" \
  || fail "sanity: gh label create was never invoked — fixture didn't drive the priorities loop"

echo ""
echo "═══ product-apply-stdout-leak: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
