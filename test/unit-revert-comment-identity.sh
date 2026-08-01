#!/usr/bin/env bash
# Unit tests for how /revert recognises the machinery's own comments (#183).
#
# It used to match the author against `github-actions[bot]`. That name is only
# correct when the install runs on the default GITHUB_TOKEN: under
# AUTODUCKS_PAT the machinery posts as the PAT owner's own account, under a
# GitHub App as `<app>[bot]`. On a PAT install the selection therefore matched
# nothing — revert stripped the labels and deleted no comments at all, leaving
# an issue that looked reverted and was not. Recognition is now by marker.
#
# The marker also has to survive an edit: the status comment is posted once and
# rewritten in place from "running" to "finished", and an edit replaces the body
# wholesale.
#
# Run: bash test/unit-revert-comment-identity.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

MARKER="<!-- autoducks:comment -->"

# The stamp helper, lifted from load-config.sh without running the whole config
# loader (which needs a repo, a token and a config file).
eval "$(sed -n '/^comment_marker::stamp() {/,/^}/p' "$REPO_ROOT/.autoducks/core/config/load-config.sh")"
AUTODUCKS_COMMENT_MARKER="$MARKER"

echo "── comment_marker::stamp ──"

out="$(comment_marker::stamp "hello")"
[[ "$out" == *"$MARKER"* ]] && pass "appends the marker" || fail "no marker appended: $out"
[[ "$out" == "hello"* ]] && pass "preserves the original body" || fail "body mangled: $out"

twice="$(comment_marker::stamp "$out")"
if [[ "$(grep -c -- "$MARKER" <<< "$twice")" -eq 1 ]]; then
  pass "idempotent — stamping twice leaves one marker"
else
  fail "double-stamped: $twice"
fi

# ── The selection revert actually runs ────────────────────────────────────
echo "── revert's comment selection ──"

# Extracted from agents/revert/run.sh so the test exercises the real filter.
SELECT_JQ=$(sed -n '/^BOT_COMMENT_IDS=/,/| .id.)$/p' "$REPO_ROOT/.autoducks/agents/revert/run.sh" \
  | sed -e "s/^BOT_COMMENT_IDS=\$(its::list_comments \"\$FEATURE\" | jq -r --arg marker \"\$AUTODUCKS_COMMENT_MARKER\" '//" -e "s/')\$//")

select_ids() { jq -r --arg marker "$MARKER" "$SELECT_JQ"; }

COMMENTS=$(cat <<EOF
[
  {"id": 1, "author": "ggondim",            "body": "⚠️ Agent run failed.\n\n$MARKER"},
  {"id": 2, "author": "ggondim",            "body": "/engineer"},
  {"id": 3, "author": "github-actions[bot]", "body": "legacy comment, no marker"},
  {"id": 4, "author": "autoducks[bot]",     "body": "status: running\n\n$MARKER"},
  {"id": 5, "author": "someone-else",       "body": "I think this design is wrong"}
]
EOF
)

ids=$(echo "$COMMENTS" | select_ids | tr '\n' ' ')

case " $ids " in
  *" 1 "*) pass "PAT-authored machinery comment (marker) selected" ;;
  *) fail "missed the PAT-authored machinery comment: got '$ids'" ;;
esac
case " $ids " in
  *" 4 "*) pass "App-authored machinery comment (marker) selected" ;;
  *) fail "missed the App-authored machinery comment: got '$ids'" ;;
esac
case " $ids " in
  *" 3 "*) pass "legacy github-actions[bot] comment still selected" ;;
  *) fail "dropped the legacy bot comment: got '$ids'" ;;
esac
case " $ids " in
  *" 2 "*) fail "selected the human's /engineer trigger comment — revert would delete it: '$ids'" ;;
  *) pass "human trigger comment left alone" ;;
esac
case " $ids " in
  *" 5 "*) fail "selected a human discussion comment — revert would delete it: '$ids'" ;;
  *) pass "human discussion comment left alone" ;;
esac

# The regression in one line: the old filter against this same input.
old_ids=$(echo "$COMMENTS" | jq -r '.[] | select(.author == "github-actions[bot]" or .author == "github-actions") | .id' | tr '\n' ' ')
new_count=$(wc -w <<< "$ids"); old_count=$(wc -w <<< "$old_ids")
if [[ "$new_count" -gt "$old_count" ]]; then
  pass "recognises more than the author-only filter did ($new_count vs $old_count)"
else
  fail "no better than the old filter ($new_count vs $old_count)"
fi

# ── Body restore picks a human body, not the machinery's ──────────────────
echo "── revert's original-body selection ──"

RESTORE_JQ=$(sed -n '/^ORIGINAL_BODY=\$(echo "\$EDIT_HISTORY" | jq -r .$/,/^.)$/p' \
  "$REPO_ROOT/.autoducks/agents/revert/run.sh" | sed -e '1d' -e '$d')

restore() { jq -r "$RESTORE_JQ"; }

HISTORY=$(cat <<'EOF'
{"data":{"repository":{"issue":{"userContentEdits":{"nodes":[
  {"editedAt":"2026-01-01T00:00:00Z","editor":{"login":"ggondim"},"diff":"# The original human draft"},
  {"editedAt":"2026-01-02T00:00:00Z","editor":{"login":"ggondim"},"diff":"# Draft\n\n<!-- autoducks:tactical:begin -->\n## Plan\n<!-- autoducks:tactical:end -->"}
]}}}}}
EOF
)

restored=$(echo "$HISTORY" | restore)
if [[ "$restored" == "# The original human draft" ]]; then
  pass "restores the human draft, not the machinery's later body"
else
  fail "restored the wrong revision: $restored"
fi

# ── The smoke test's three-way plan classification ────────────────────────
# Structural assertions: the classifier lives inline in a 1000-line script that
# cannot be sourced without hitting the API, so this pins its shape, not its
# behaviour on live data.
echo "── smoke-test-plan: plan-shape classification ──"

SMOKE="$REPO_ROOT/scripts/smoke-test-plan.sh"
grep -q 'TACTICAL_ZONE=' "$SMOKE" \
  && pass "classifies on the tactical zone, not the whole body" \
  || fail "no tactical-zone extraction — the seed's own headings would match"
grep -q 'single-task fast path' "$SMOKE" \
  && pass "has a branch for the legitimate single-task fast path" \
  || fail "single-task fast path still reported as a failure"
grep -q 'present but carries no task numbers' "$SMOKE" \
  && pass "still fails on a genuinely empty splitter" \
  || fail "lost the real empty-splitter assertion"
if grep -q 'wait_for_feature_unplanned "\$FEATURE" 120' "$SMOKE"; then
  fail "revert wait is still 120s — an outlier against the 600-900s used elsewhere"
else
  pass "revert wait budget is no longer the 120s outlier"
fi

echo ""
echo "═══ revert-comment-identity: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
