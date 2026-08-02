#!/usr/bin/env bash
set -uo pipefail

# Exercises pre.sh's unverified-definition refusal against a real git fixture:
# a definition that differs from the base ref must be refused before the LLM
# step unless custom_agents.allow_unverified is set.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Each fixture gets its own copy of the machinery, so AUTODUCKS_ROOT (derived
# from load-config.sh's own path) resolves to the fixture's autoducks.json
# rather than this repo's.
ORIG_PATH="$PATH"
TEST_ISSUE_NUM=778811

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
  rm -f /tmp/agent-descriptor.json "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
}
trap cleanup EXIT

new_tmp() { local d; d="$(mktemp -d)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }

# A workspace whose definition is committed on `base-ref` and then edited, so
# discover-agents.sh reports verified=unverified.
make_workspace() {
  local d; d="$(new_tmp)"
  mkdir -p "$d/.claude/agents" "$d/.autoducks"
  cp -R "$REPO_ROOT/.autoducks/agents" "$d/.autoducks/agents"
  cp -R "$REPO_ROOT/.autoducks/core" "$d/.autoducks/core"
  cp -R "$REPO_ROOT/.autoducks/providers" "$d/.autoducks/providers"
  cp -R "$REPO_ROOT/.autoducks/design" "$d/.autoducks/design" 2>/dev/null || true
  # Start from the repo's real config: a bare {} makes downstream jq merges
  # fail on null, which is a fixture artifact rather than anything under test.
  cp "$REPO_ROOT/.autoducks/autoducks.json" "$d/.autoducks/autoducks.json"
  printf -- '---\ntools: [Read]\n---\nOriginal reviewed body.\n' > "$d/.claude/agents/helper.md"
  (
    cd "$d"
    git init -q -b main 2>/dev/null || git init -q
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    git config core.autocrlf false
    git add -A && git commit -qm base && git branch -f base-ref HEAD
  ) >/dev/null 2>&1
  # Now edit it, the way a PR head would.
  printf -- '---\ntools: [Read]\n---\nBody rewritten on the PR head.\n' > "$d/.claude/agents/helper.md"
  printf '%s' "$d"
}

make_fake_gh() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/gh" <<FAKE_GH
#!/usr/bin/env bash
{ printf '>>> gh\n'; printf '%s\n' "\$@"; printf '<<<\n'; } >> "$log_file"
case "\$1 \$2" in
  "issue view")    echo '{"title": "T", "body": "b", "labels": []}' ;;
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
      PATH="$bin_dir:$ORIG_PATH" \
      HOME="$HOME" \
      GITHUB_ACTIONS=true \
      GITHUB_WORKSPACE="$ws" \
      RUNNER_TEMP="$marker_dir" \
      GITHUB_RUN_ID="test" \
      REPO="acme/widgets" \
      RUN_ID="1" \
      ISSUE_NUM="$TEST_ISSUE_NUM" \
      COMMENT_ID="" \
      IS_PR="true" \
      AGENT_NAME="helper" \
      AUTODUCKS_BASE_REF="base-ref" \
      AUTODUCKS_PINNED_ROOT="$ws" \
      bash "$ws/.autoducks/agents/agent/pre.sh" )
}

echo "1) an unverified definition is refused, with no LLM step reached"
WS="$(make_workspace)"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if grep -qi "does not match the default branch" "$LOG"; then
  pass "refusal names the unverified definition"
else
  fail "expected the unverified refusal in the posted comment"
fi
if grep -q "allow_unverified" "$LOG"; then
  pass "refusal tells the user how to opt in"
else
  fail "expected allow_unverified in the refusal message"
fi

echo ""
echo "2) custom_agents.allow_unverified lets it through"
WS="$(make_workspace)"
jq '.custom_agents = ((.custom_agents // {}) + {allow_unverified: true})' \
  "$WS/.autoducks/autoducks.json" > "$WS/.autoducks/autoducks.json.tmp" \
  && mv "$WS/.autoducks/autoducks.json.tmp" "$WS/.autoducks/autoducks.json"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if ! grep -qi "does not match the default branch" "$LOG"; then
  pass "no refusal when allow_unverified is set"
else
  fail "refused despite allow_unverified: true"
fi

echo ""
echo "3) a definition matching the base ref is never refused"
WS="$(make_workspace)"
git -C "$WS" checkout -- .claude/agents/helper.md 2>/dev/null || \
  printf -- '---\ntools: [Read]\n---\nOriginal reviewed body.\n' > "$WS/.claude/agents/helper.md"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if ! grep -qi "does not match the default branch" "$LOG"; then
  pass "a verified definition runs without the refusal"
else
  fail "a base-identical definition was refused"
fi

echo ""
echo "=== agent lane pre.sh unverified (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
