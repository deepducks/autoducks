#!/usr/bin/env bash
# Offline unit tests for .autoducks/agents/agent/post.sh's missing-response
# and clean-tree paths (the two scenarios the Tasks checklist calls out).
#
# post.sh sources load-config.sh, which unconditionally re-sources the real
# GitHub provider implementations — so fake bash functions defined before
# invoking it get clobbered. Instead this fakes the underlying `gh` binary via
# a PATH shim, runs post.sh as a real subprocess (never sourced) against a
# throwaway git repo, and inspects its exit code, git side effects, and the
# fake gh's call log. No network, no real GitHub auth.
#
# Run via scripts/tests/run.sh, or directly: bash scripts/tests/agent-post.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_SH="$REPO_ROOT/.autoducks/agents/agent/post.sh"
ORIG_PATH="$PATH"
TEST_ISSUE_NUM=778899   # unlikely to collide with a real leftover marker file

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
  rm -f /tmp/agent-response.md /tmp/agent-descriptor.json \
        "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
}
trap cleanup EXIT

new_tmp() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  printf '%s' "$d"
}

# A fake `gh` on PATH: logs every invocation and returns just enough stdout
# for the its:: provider wrappers post.sh calls (issue comment/edit, pr
# create, api reactions) — no network, no auth, no real GitHub calls.
make_fake_gh() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/gh" <<FAKE_GH
#!/usr/bin/env bash
{
  printf '>>> gh invocation\n'
  printf '%s\n' "\$@"
  printf '<<<\n'
} >> "$log_file"
case "\$1 \$2" in
  "issue comment") echo "https://github.com/\${REPO:-o/r}/issues/0#issuecomment-999001" ;;
  "issue edit")    exit 0 ;;
  "pr create")     echo "https://github.com/\${REPO:-o/r}/pull/999" ;;
  *)               exit 0 ;;
esac
FAKE_GH
  chmod +x "$bin_dir/gh"
}

# run_post WORKDIR BIN_DIR — invokes the real post.sh as a subprocess in a
# scrubbed environment (env -i) so a CI-inherited GITHUB_RUN_ID/RUNNER_TEMP/
# GITHUB_STEP_SUMMARY from the outer job can never leak into or collide with
# what this test observes.
run_post() {
  local workdir="$1" bin_dir="$2" marker_dir="$3"
  ( cd "$workdir" && \
    env -i \
      PATH="$bin_dir:$ORIG_PATH" \
      HOME="$HOME" \
      GITHUB_ACTIONS=true \
      RUNNER_TEMP="$marker_dir" \
      GITHUB_RUN_ID="test" \
      REPO="acme/widgets" \
      RUN_ID="123456" \
      ISSUE_NUM="$TEST_ISSUE_NUM" \
      COMMENT_ID="" \
      AUTODUCKS_PINNED_ROOT="$workdir" \
      bash "$POST_SH" )
}

# ---------------------------------------------------------------------------
echo "1) missing /tmp/agent-response.md -> scope-missing failure, exit 1, no delivery"
rm -f /tmp/agent-response.md /tmp/agent-descriptor.json "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"

WORK="$(new_tmp)"
LOG="$(new_tmp)/gh.log"
BIN="$(new_tmp)"
MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"

if run_post "$WORK" "$BIN" "$MARKER"; then rc=0; else rc=$?; fi

if [[ "$rc" -eq 1 ]]; then
  pass "exits 1 when /tmp/agent-response.md is missing"
else
  fail "expected exit 1, got $rc"
fi

if grep -q "scope-missing" "$LOG"; then
  pass "failure comment names the scope-missing category"
else
  fail "expected 'scope-missing' in the posted failure comment"
fi

if ! grep -q "pr create" "$LOG"; then
  pass "no PR was opened for a run with no response"
else
  fail "unexpected 'gh pr create' call with no agent response"
fi

# ---------------------------------------------------------------------------
echo ""
echo "2) whitespace-only /tmp/agent-response.md -> same scope-missing failure"
rm -f /tmp/agent-response.md /tmp/agent-descriptor.json "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
printf '   \n\t\n  ' > /tmp/agent-response.md

WORK="$(new_tmp)"
LOG="$(new_tmp)/gh.log"
BIN="$(new_tmp)"
MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"

if run_post "$WORK" "$BIN" "$MARKER"; then rc=0; else rc=$?; fi

if [[ "$rc" -eq 1 ]]; then
  pass "whitespace-only response is treated the same as missing"
else
  fail "expected exit 1 for whitespace-only response, got $rc"
fi

if grep -q "scope-missing" "$LOG"; then
  pass "whitespace-only response also reports scope-missing"
else
  fail "expected 'scope-missing' in the posted failure comment"
fi

# ---------------------------------------------------------------------------
echo ""
echo "3) clean working tree -> response posted, no branch/commit/PR"
rm -f /tmp/agent-response.md /tmp/agent-descriptor.json "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
printf 'All done. No repo changes were needed for this request.\n' > /tmp/agent-response.md
cat > /tmp/agent-descriptor.json <<'JSON'
{"name": "doc-explainer", "source": ".agents/doc-explainer.md", "tools_effective": ["Read", "Grep"]}
JSON

WORK="$(new_tmp)"
( cd "$WORK" && git init -q && git config user.email t@example.com && git config user.name tester \
    && git commit -q --allow-empty -m init )
BEFORE_HEAD="$(cd "$WORK" && git rev-parse HEAD)"

LOG="$(new_tmp)/gh.log"
BIN="$(new_tmp)"
MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"

if run_post "$WORK" "$BIN" "$MARKER"; then rc=0; else rc=$?; fi

if [[ "$rc" -eq 0 ]]; then
  pass "exits 0 on a clean tree with a valid response"
else
  fail "expected exit 0, got $rc"
fi

AFTER_HEAD="$(cd "$WORK" && git rev-parse HEAD)"
if [[ "$AFTER_HEAD" == "$BEFORE_HEAD" ]]; then
  pass "no commit was created on a clean tree"
else
  fail "HEAD moved ($BEFORE_HEAD -> $AFTER_HEAD) despite a clean tree"
fi

AFTER_BRANCHES="$(cd "$WORK" && git branch --list 'agent/*')"
if [[ -z "$AFTER_BRANCHES" ]]; then
  pass "no agent/* branch was created on a clean tree"
else
  fail "unexpected branch(es): $AFTER_BRANCHES"
fi

if ! grep -q "pr create" "$LOG"; then
  pass "no PR was opened on a clean tree"
else
  fail "unexpected 'gh pr create' call on a clean tree"
fi

if grep -q "doc-explainer" "$LOG"; then
  pass "response comment is attributed to the descriptor's agent name"
else
  fail "expected the posted comment to name 'doc-explainer'"
fi

if grep -q "All done. No repo changes were needed" "$LOG"; then
  pass "response comment includes the agent's response text"
else
  fail "expected the agent's response text in the posted comment"
fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
echo ""
echo "4) agent edits conflict with the base -> no PR, no conflict markers committed"
rm -f /tmp/agent-response.md /tmp/agent-descriptor.json "/tmp/autoducks-status-comment-id.${TEST_ISSUE_NUM}"
printf 'I rewrote the config.\n' > /tmp/agent-response.md
cat > /tmp/agent-descriptor.json <<'JSON'
{"name": "doc-explainer", "source": ".agents/doc-explainer.md", "tools_effective": ["Read", "Write"]}
JSON

# Base branch and PR head both touch the same line; the agent then edits it
# again. Replaying the agent's edit onto the base is a genuine conflict —
# the case the rebase was written for, and the one that must not produce a
# branch containing <<<<<<< markers.
WORK="$(new_tmp)"
(
  cd "$WORK"
  git init -q -b main 2>/dev/null || git init -q
  git config user.email t@example.com; git config user.name tester
  git config commit.gpgsign false
  printf 'base\n' > shared.txt
  git add -A; git commit -q -m init
  git branch -f main HEAD 2>/dev/null || true
  git checkout -q -b pr-head
  printf 'from the contributor PR\n' > shared.txt
  git commit -qam pr
  printf 'from the agent\n' > shared.txt          # uncommitted agent edit
) >/dev/null 2>&1

LOG="$(new_tmp)/gh.log"
BIN="$(new_tmp)"
MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
# The shared stub answers `issue view` with nothing; this path needs the
# issue title to build the branch name, so extend it just for this case.
cat > "$BIN/gh" <<FAKE_GH
#!/usr/bin/env bash
{
  printf '>>> gh invocation\n'
  printf '%s\n' "\$@"
  printf '<<<\n'
} >> "$LOG"
case "\$1 \$2" in
  "issue view")    echo '{"title": "Conflicting change", "body": "b", "labels": []}' ;;
  "issue comment") echo "https://github.com/\${REPO:-o/r}/issues/0#issuecomment-999001" ;;
  "issue edit")    exit 0 ;;
  "pr create")     echo "https://github.com/\${REPO:-o/r}/pull/999" ;;
  *)               exit 0 ;;
esac
FAKE_GH
chmod +x "$BIN/gh"

if run_post "$WORK" "$BIN" "$MARKER"; then rc=0; else rc=$?; fi

if ! grep -q "pr create" "$LOG"; then
  pass "no PR is opened when the agent's edits conflict with the base"
else
  fail "opened a PR from a conflicted tree"
fi

CONFLICTED=0
while IFS= read -r ref; do
  if (cd "$WORK" && git grep -q '^<<<<<<< ' "$ref" -- 2>/dev/null); then CONFLICTED=1; fi
done < <(cd "$WORK" && git for-each-ref --format='%(refname)' refs/heads 2>/dev/null)
if [[ "$CONFLICTED" -eq 0 ]]; then
  pass "no branch carries committed conflict markers"
else
  fail "a committed tree contains conflict markers"
fi

if grep -q "conflict" "$LOG"; then
  pass "the response comment tells the user the changes could not be delivered"
else
  fail "expected the conflict to be reported in the posted comment"
fi

echo ""
echo "=== agent lane post.sh (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
