#!/usr/bin/env bash
# Run via scripts/tests/run.sh, or directly: bash scripts/tests/agent-pre-unverified.test.sh
set -uo pipefail

# Exercises pre.sh's unverified-definition refusal against a real git fixture.
# A definition that differs from the base ref must be refused before the LLM
# step, unless custom_agents.allow_unverified is set ON THE BASE REF — the
# whole point being that the opt-in cannot ride in on the same pull request as
# the definition it would permit.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  # pre.sh writes several files into the shared /tmp that sibling suites also
  # use; leaving them behind leaks state across scripts/tests/run.sh.
  rm -f /tmp/agent-descriptor.json /tmp/agent-registry.json \
        /tmp/agent-definition-body.md /tmp/steering-prompt.md \
        /tmp/issue-request.md /tmp/issue-comments.md /tmp/issue-meta.md \
        /tmp/context-manifest.json \
        "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
}
trap cleanup EXIT

new_tmp() { local d; d="$(mktemp -d)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }

# A workspace whose definition is committed on `base-ref`. `surface: pr` so the
# run is not diverted by the surface-mismatch refusal that follows this one —
# without it, cases below would "pass" by stopping for the wrong reason.
#
# Each fixture carries its own copy of the machinery: load-config.sh derives
# AUTODUCKS_ROOT by walking up from its own path, so a fixture reusing this
# repo's scripts would read this repo's autoducks.json.
make_workspace() {
  local d; d="$(new_tmp)"
  mkdir -p "$d/.claude/agents" "$d/.autoducks"
  cp -R "$REPO_ROOT/.autoducks/agents"    "$d/.autoducks/agents"
  cp -R "$REPO_ROOT/.autoducks/core"      "$d/.autoducks/core"
  cp -R "$REPO_ROOT/.autoducks/providers" "$d/.autoducks/providers"
  cp -R "$REPO_ROOT/.autoducks/design"    "$d/.autoducks/design" 2>/dev/null || true
  # Start from the repo's real config: a bare {} makes downstream jq merges
  # fail on null, which is a fixture artifact rather than anything under test.
  cp "$REPO_ROOT/.autoducks/autoducks.json" "$d/.autoducks/autoducks.json"
  printf -- '---\nsurface: pr\ntools: [Read]\n---\nOriginal reviewed body.\n' > "$d/.claude/agents/helper.md"
  (
    cd "$d"
    git init -q -b main 2>/dev/null || git init -q
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    git config core.autocrlf false
    git add -A && git commit -qm base && git branch -f base-ref HEAD
  ) >/dev/null 2>&1
  printf '%s' "$d"
}

# Edit the definition the way a PR head would, making it unverified.
dirty_definition() {
  printf -- '---\nsurface: pr\ntools: [Read]\n---\nBody rewritten on the PR head.\n' > "$1/.claude/agents/helper.md"
}

# set_flag WORKSPACE true|false yes|no
# yes commits the flag onto base-ref (the trusted source); no leaves it only in
# the working tree, i.e. only on the "PR head".
set_flag() {
  local ws="$1" value="$2" committed="$3"
  jq --argjson v "$value" '.custom_agents = ((.custom_agents // {}) + {allow_unverified: $v})' \
    "$ws/.autoducks/autoducks.json" > "$ws/.autoducks/autoducks.json.tmp" \
    && mv "$ws/.autoducks/autoducks.json.tmp" "$ws/.autoducks/autoducks.json"
  if [[ "$committed" == "yes" ]]; then
    ( cd "$ws" && git add -A && git commit -qm flag && git branch -f base-ref HEAD ) >/dev/null 2>&1
  fi
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

REFUSAL="does not match reviewed history"
# pre.sh only assembles the prompt once every refusal is behind it, so the
# file's presence is the positive signal that the run was actually permitted —
# asserting only the absence of a string would pass on any earlier failure.
proceeded() { [[ -f "$1/.autoducks/agents/agent/resolved-prompt.md" ]]; }

echo "1) an unverified definition is refused before the LLM step"
WS="$(make_workspace)"; dirty_definition "$WS"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if grep -qi "$REFUSAL" "$LOG" 2>/dev/null; then
  pass "refusal names the unverified definition"
else
  fail "expected the unverified refusal in the posted comment"
fi
if ! proceeded "$WS"; then
  pass "no prompt assembled — the run stopped before the LLM step"
else
  fail "a prompt was assembled despite the refusal"
fi

echo ""
echo "2) allow_unverified on the base ref lets it through"
WS="$(make_workspace)"; set_flag "$WS" true yes; dirty_definition "$WS"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if ! grep -qi "$REFUSAL" "$LOG" 2>/dev/null; then
  pass "no refusal when the opt-in is committed on the base ref"
else
  fail "refused despite allow_unverified committed on base-ref"
fi
if proceeded "$WS"; then
  pass "the permitted run actually proceeds to prompt assembly"
else
  fail "opt-in accepted but the run never reached prompt assembly"
fi
# AGENTS.md claims the opt-in "widens who may run, never what they may reach".
# The definition asks for [Read] but an unverified run must land on the
# unverified_tools floor regardless, and that floor must exclude writes.
EFFECTIVE="$(jq -c '.tools_effective' /tmp/agent-descriptor.json 2>/dev/null)"
FLOOR="$(jq -c '.unverified_tools' "$WS/.autoducks/agents/agent/defaults.json" 2>/dev/null)"
if [[ -n "$EFFECTIVE" && "$EFFECTIVE" == "$FLOOR" ]]; then
  pass "the opt-in run is still clamped to unverified_tools"
else
  fail "opt-in run not clamped: tools_effective=$EFFECTIVE floor=$FLOOR"
fi
if ! grep -q '"Write"' <<<"$EFFECTIVE" && ! grep -q '"Edit"' <<<"$EFFECTIVE"; then
  pass "the clamped grant carries neither Write nor Edit"
else
  fail "clamped grant still contains a write tool: $EFFECTIVE"
fi

echo ""
echo "3) allow_unverified only on the PR head does NOT let it through"
WS="$(make_workspace)"; dirty_definition "$WS"; set_flag "$WS" true no
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if grep -qi "$REFUSAL" "$LOG" 2>/dev/null; then
  pass "the opt-in cannot be switched on by the pull request it would permit"
else
  fail "an uncommitted allow_unverified bypassed the refusal"
fi

echo ""
echo "4) a definition matching the base ref runs without the refusal"
WS="$(make_workspace)"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "$BIN" "$MARKER" >/dev/null 2>&1

if ! grep -qi "$REFUSAL" "$LOG" 2>/dev/null; then
  pass "a verified definition is never refused"
else
  fail "a base-identical definition was refused"
fi
if proceeded "$WS"; then
  pass "the verified run proceeds to prompt assembly"
else
  fail "a verified definition never reached prompt assembly"
fi

echo ""
echo "5) with no AUTODUCKS_BASE_REF there is nothing to verify against"
# This is the local setup.sh path: verified stays "unchecked" and the guard is
# off by design. Pinned because it is the single input that disables it.
WS="$(make_workspace)"; dirty_definition "$WS"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
( cd "$WS" && \
  env -i PATH="$BIN:$ORIG_PATH" HOME="$HOME" GITHUB_ACTIONS=true \
    GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$MARKER" GITHUB_RUN_ID=test \
    REPO=acme/widgets RUN_ID=1 ISSUE_NUM="$TEST_ISSUE_NUM" COMMENT_ID="" \
    IS_PR=true AGENT_NAME=helper AUTODUCKS_PINNED_ROOT="$WS" \
    bash "$WS/.autoducks/agents/agent/pre.sh" ) >/dev/null 2>&1

if ! grep -qi "$REFUSAL" "$LOG" 2>/dev/null; then
  pass "no base ref: the refusal does not fire"
else
  fail "refused with no base ref configured"
fi
if [[ "$(jq -r '.verified' /tmp/agent-descriptor.json 2>/dev/null)" == "unchecked" ]]; then
  pass "no base ref: the descriptor records verified=unchecked"
else
  fail "expected verified=unchecked with no base ref"
fi

echo ""
echo "6) the catalog marks an unverified agent instead of advertising it plainly"
WS="$(make_workspace)"; dirty_definition "$WS"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
( cd "$WS" && \
  env -i PATH="$BIN:$ORIG_PATH" HOME="$HOME" GITHUB_ACTIONS=true \
    GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$MARKER" GITHUB_RUN_ID=test \
    REPO=acme/widgets RUN_ID=1 ISSUE_NUM="$TEST_ISSUE_NUM" COMMENT_ID="" \
    IS_PR=true AGENT_NAME="" AUTODUCKS_BASE_REF=base-ref AUTODUCKS_PINNED_ROOT="$WS" \
    bash "$WS/.autoducks/agents/agent/pre.sh" ) >/dev/null 2>&1

if grep -q "unverified" "$LOG" 2>/dev/null; then
  pass "the catalog flags the agent that /agent <name> would refuse"
else
  fail "catalog listed an unverified agent with no marker"
fi

echo ""
echo "=== agent lane pre.sh unverified (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
