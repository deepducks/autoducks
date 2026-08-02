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

# The marker lives in its own file precisely so it can be sourced without the
# whole config loader (which needs a repo, a token and a config file).
# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/config/comment-marker.sh"

[[ "$AUTODUCKS_COMMENT_MARKER" == "$MARKER" ]] \
  && pass "comment-marker.sh defines the expected marker" \
  || fail "marker changed to '$AUTODUCKS_COMMENT_MARKER' — revert matches on the literal above"

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

echo "── the ITS writers stamp unconditionally ──"

# Both writers used to stamp only `if declare -F comment_marker::stamp`, so a
# call path that had not sourced load-config posted an unstamped comment and
# said nothing about it. That is #183 again with no symptom: revert strips the
# labels and deletes nothing. The writers source the marker themselves now, so
# the guard is gone — these run them in a shell where load-config never ran.
for _w in comment-issue update-comment; do
  if grep -q 'declare -F comment_marker::stamp' \
       "$REPO_ROOT/.autoducks/providers/its/github/$_w.sh"; then
    fail "$_w.sh still stamps behind a declare -F guard"
  else
    pass "$_w.sh has no silent unstamped path"
  fi
done

_SPY="$(mktemp -d)"; trap 'rm -rf "$_SPY"' EXIT
cat > "$_SPY/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_SPY_OUT"
STUB
chmod +x "$_SPY/gh"

_body_posted() {
  # Fresh bash: nothing sourced load-config, so only the writer's own source
  # line can put the marker there.
  GH_SPY_OUT="$_SPY/args" PATH="$_SPY:$PATH" REPO="acme/repo" \
    bash -c "source '$1'; $2" >/dev/null 2>&1
  cat "$_SPY/args" 2>/dev/null || true
}

_out="$(_body_posted "$REPO_ROOT/.autoducks/providers/its/github/comment-issue.sh" \
                     'its::comment_issue 7 "hello"')"
[[ "$_out" == *"$MARKER"* ]] \
  && pass "its::comment_issue stamps without load-config" \
  || fail "its::comment_issue posted an unstamped body: $_out"

_out="$(_body_posted "$REPO_ROOT/.autoducks/providers/its/github/update-comment.sh" \
                     'its::update_comment 7 "hello"')"
[[ "$_out" == *"$MARKER"* ]] \
  && pass "its::update_comment stamps without load-config" \
  || fail "its::update_comment posted an unstamped body: $_out"

echo ""
echo "═══ revert-comment-identity: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
