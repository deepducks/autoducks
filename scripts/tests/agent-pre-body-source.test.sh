#!/usr/bin/env bash
# Run via scripts/tests/run.sh, or directly: bash scripts/tests/agent-pre-body-source.test.sh
set -uo pipefail

# The load-bearing assertion for the whole lane: the definition body that ends
# up in the assembled prompt must come from the base ref, never from the
# checked-out tree. discover-agents.sh reading from the base ref is not enough
# on its own — pre.sh re-reads the file to build the prompt, and an earlier
# version of this lane had discovery reading from one tree and prompt assembly
# from the other, which left the "execute unreviewed content" hole wide open
# while every discovery-level test passed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIG_PATH="$PATH"
TEST_ISSUE_NUM=778822

PASS=0
FAIL=0
pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "$d" ]] && rm -rf "$d"
  done
  rm -f /tmp/agent-descriptor.json /tmp/agent-registry.json \
        /tmp/agent-definition-body.md /tmp/steering-prompt.md \
        /tmp/issue-request.md /tmp/issue-comments.md /tmp/issue-meta.md \
        /tmp/context-manifest.json \
        "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
}
trap cleanup EXIT

new_tmp() { local d; d="$(mktemp -d)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }

MERGED_MARKER="MERGED-BODY-THAT-WAS-REVIEWED"
PRHEAD_MARKER="PR-HEAD-BODY-THAT-NOBODY-REVIEWED"

# Each fixture carries its own machinery copy: load-config.sh derives
# AUTODUCKS_ROOT by walking up from its own path.
make_workspace() {
  local d; d="$(new_tmp)"
  mkdir -p "$d/.claude/agents" "$d/.autoducks"
  cp -R "$REPO_ROOT/.autoducks/agents"    "$d/.autoducks/agents"
  cp -R "$REPO_ROOT/.autoducks/core"      "$d/.autoducks/core"
  cp -R "$REPO_ROOT/.autoducks/providers" "$d/.autoducks/providers"
  cp -R "$REPO_ROOT/.autoducks/design"    "$d/.autoducks/design" 2>/dev/null || true
  cp "$REPO_ROOT/.autoducks/autoducks.json" "$d/.autoducks/autoducks.json"
  printf -- '---\nsurface: pr\ntools: [Read]\n---\n%s\n' "$MERGED_MARKER" > "$d/.claude/agents/helper.md"
  (
    cd "$d"
    git init -q -b main 2>/dev/null || git init -q
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    git config core.autocrlf false
    git add -A && git commit -qm base && git branch -f base-ref HEAD
  ) >/dev/null 2>&1
  # What a PR head would look like: same file, different body.
  printf -- '---\nsurface: pr\ntools: [Read]\n---\n%s\n' "$PRHEAD_MARKER" > "$d/.claude/agents/helper.md"
  printf '%s' "$d"
}

make_fake_gh() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/gh" <<FAKE_GH
#!/usr/bin/env bash
{ printf '>>> gh\n'; printf '%s\n' "\$@"; printf '<<<\n'; } >> "$log_file"
case "\$1 \$2" in
  "issue view")    echo '{"title": "T", "body": "b", "labels": [], "comments": []}' ;;
  "issue comment") echo "https://github.com/o/r/issues/0#issuecomment-1" ;;
  *)               exit 0 ;;
esac
FAKE_GH
  chmod +x "$bin_dir/gh"
}

run_pre() {
  local ws="$1" bin_dir="$2" marker_dir="$3"
  ( cd "$ws" && \
    env -i \
      PATH="$bin_dir:$ORIG_PATH" HOME="$HOME" GITHUB_ACTIONS=true \
      GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$marker_dir" GITHUB_RUN_ID="test" \
      REPO="acme/widgets" RUN_ID="1" ISSUE_NUM="$TEST_ISSUE_NUM" COMMENT_ID="" \
      IS_PR="true" AGENT_NAME="helper" AUTODUCKS_BASE_REF="base-ref" \
      AUTODUCKS_PINNED_ROOT="$ws" \
      bash "$ws/.autoducks/agents/agent/pre.sh" )
}

echo "1) the assembled prompt carries the merged body, not the PR-head body"
WS="$(make_workspace)"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

PROMPT="$WS/.autoducks/agents/agent/resolved-prompt.md"
if [[ -f "$PROMPT" ]]; then
  pass "a prompt was assembled"
else
  fail "no prompt assembled — cannot check its contents"
fi
if grep -q "$MERGED_MARKER" "$PROMPT" 2>/dev/null; then
  pass "the prompt contains the merged body"
else
  fail "the merged body is missing from the assembled prompt"
fi
if ! grep -q "$PRHEAD_MARKER" "$PROMPT" 2>/dev/null; then
  pass "the prompt does NOT contain the PR-head body"
else
  fail "SECURITY: unreviewed PR-head body reached the prompt"
fi

echo ""
echo "2) the intermediate body file is the merged one too"
if grep -q "$MERGED_MARKER" /tmp/agent-definition-body.md 2>/dev/null \
   && ! grep -q "$PRHEAD_MARKER" /tmp/agent-definition-body.md 2>/dev/null; then
  pass "/tmp/agent-definition-body.md holds the merged body"
else
  fail "the intermediate body file came from the checked-out tree"
fi

echo ""
echo "3) a definition deleted on the PR head still runs from the base ref"
WS="$(make_workspace)"
rm -f "$WS/.claude/agents/helper.md"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

PROMPT="$WS/.autoducks/agents/agent/resolved-prompt.md"
if grep -q "$MERGED_MARKER" "$PROMPT" 2>/dev/null; then
  pass "deleting the file on the PR head does not affect the run"
else
  fail "the run depended on the file being present in the checkout"
fi

echo ""
echo "=== agent lane pre.sh body source (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
