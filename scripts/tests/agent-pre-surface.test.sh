#!/usr/bin/env bash
# Run via scripts/tests/run.sh, or directly: bash scripts/tests/agent-pre-surface.test.sh
set -uo pipefail

# `surface` gating, and the shape of a refusal.
#
# Both were broken on the lane's first live run: an agent declared
# `surface: both` was refused on an issue with the message "is declared
# surface: issue and can only run from an issue" — the check compared for
# equality, so `both` matched nothing, and the message's else branch only
# distinguished `pr`. The same run posted the refusal twice.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIG_PATH="$PATH"
TEST_ISSUE_NUM=778833

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

# make_workspace SURFACE — a fixture whose definition declares SURFACE and is
# committed on base-ref, since definitions are only ever read from there.
make_workspace() {
  local surface="$1" d
  d="$(new_tmp)"
  mkdir -p "$d/.agents" "$d/.autoducks"
  cp -R "$REPO_ROOT/.autoducks/agents"    "$d/.autoducks/agents"
  cp -R "$REPO_ROOT/.autoducks/core"      "$d/.autoducks/core"
  cp -R "$REPO_ROOT/.autoducks/providers" "$d/.autoducks/providers"
  cp -R "$REPO_ROOT/.autoducks/design"    "$d/.autoducks/design" 2>/dev/null || true
  cp "$REPO_ROOT/.autoducks/autoducks.json" "$d/.autoducks/autoducks.json"
  printf -- '---\nsurface: %s\ntools: [Read]\n---\nA body.\n' "$surface" > "$d/.agents/helper.md"
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

make_fake_gh() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/gh" <<FAKE_GH
#!/usr/bin/env bash
{ printf '>>> gh %s\n' "\$*"; } >> "$log_file"
case "\$1 \$2" in
  "issue view")    echo '{"title": "T", "body": "b", "labels": [], "comments": []}' ;;
  "issue comment") echo "https://github.com/o/r/issues/0#issuecomment-1" ;;
  *)               exit 0 ;;
esac
FAKE_GH
  chmod +x "$bin_dir/gh"
}

run_pre() {
  local ws="$1" is_pr="$2" bin_dir="$3" marker_dir="$4"
  ( cd "$ws" && \
    env -i \
      PATH="$bin_dir:$ORIG_PATH" HOME="$HOME" GITHUB_ACTIONS=true \
      GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$marker_dir" GITHUB_RUN_ID="test" \
      REPO="acme/widgets" RUN_ID="1" ISSUE_NUM="$TEST_ISSUE_NUM" COMMENT_ID="" \
      IS_PR="$is_pr" AGENT_NAME="helper" AUTODUCKS_BASE_REF="base-ref" \
      AUTODUCKS_PINNED_ROOT="$ws" \
      bash "$ws/.autoducks/agents/agent/pre.sh" )
}

proceeded() { [[ -f "$1/.autoducks/agents/agent/resolved-prompt.md" ]]; }

# check SURFACE IS_PR EXPECT("run"|"refuse") LABEL
check() {
  local surface="$1" is_pr="$2" expect="$3" label="$4"
  local ws log bin marker
  ws="$(make_workspace "$surface")"
  log="$(new_tmp)/gh.log"; bin="$(new_tmp)"; marker="$(new_tmp)"
  make_fake_gh "$bin" "$log"
  run_pre "$ws" "$is_pr" "$bin" "$marker" >/dev/null 2>&1
  if [[ "$expect" == "run" ]]; then
    if proceeded "$ws"; then pass "$label"; else fail "$label — was refused"; fi
  else
    if ! proceeded "$ws"; then pass "$label"; else fail "$label — was allowed"; fi
  fi
}

echo "1) surface gating"
check both  false run    "surface: both runs on an issue"
check both  true  run    "surface: both runs on a pull request"
check issue false run    "surface: issue runs on an issue"
check issue true  refuse "surface: issue is refused on a pull request"
check pr    true  run    "surface: pr runs on a pull request"
check pr    false refuse "surface: pr is refused on an issue"

echo ""
echo "2) a refusal names the surface it was actually declared with"
WS="$(make_workspace pr)"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "false" "$BIN" "$MARKER" >/dev/null 2>&1
if grep -q "surface: pr" "$LOG" 2>/dev/null && ! grep -q "surface: issue" "$LOG" 2>/dev/null; then
  pass "a surface: pr agent refused on an issue is described as surface: pr"
else
  fail "refusal misreported the declared surface"
fi

echo ""
echo "3) a refusal is reported once, not twice"
WS="$(make_workspace pr)"
LOG="$(new_tmp)/gh.log"; BIN="$(new_tmp)"; MARKER="$(new_tmp)"
make_fake_gh "$BIN" "$LOG"
run_pre "$WS" "false" "$BIN" "$MARKER" >/dev/null 2>&1
N="$(grep -c "can only run from a pull request" "$LOG" 2>/dev/null || echo 0)"
if [[ "$N" -eq 1 ]]; then
  pass "the refusal reason reaches the issue exactly once (n=$N)"
else
  fail "the refusal reason was written $N times, expected 1"
fi

echo ""
echo "=== agent lane pre.sh surface (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
