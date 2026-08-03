#!/usr/bin/env bash
# Run via scripts/tests/run.sh, or directly: bash scripts/tests/agent-pre-required-tools.test.sh
set -uo pipefail

# The lane's output contract requires the agent to write /tmp/agent-response.md.
# A definition that declares `tools` REPLACES the lane default outright, so
# `tools: [WebSearch, WebFetch]` produced an agent ordered to write a file with
# no tool that can write: 18 permission denials, 26 turns burned, and a
# `scope-missing` failure that blamed the definition for not stating an output
# contract. required_tools is the floor that cannot be replaced away.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIG_PATH="$PATH"
TEST_ISSUE_NUM=778844

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

# make_workspace TOOLS_YAML — TOOLS_YAML is the frontmatter `tools:` value, or
# empty to omit the key entirely.
make_workspace() {
  local tools="$1" d
  d="$(new_tmp)"
  mkdir -p "$d/.agents" "$d/.autoducks"
  cp -R "$REPO_ROOT/.autoducks/agents"    "$d/.autoducks/agents"
  cp -R "$REPO_ROOT/.autoducks/core"      "$d/.autoducks/core"
  cp -R "$REPO_ROOT/.autoducks/providers" "$d/.autoducks/providers"
  cp -R "$REPO_ROOT/.autoducks/design"    "$d/.autoducks/design" 2>/dev/null || true
  cp "$REPO_ROOT/.autoducks/autoducks.json" "$d/.autoducks/autoducks.json"
  if [[ -n "$tools" ]]; then
    printf -- '---\nsurface: both\ntools: %s\n---\nA body.\n' "$tools" > "$d/.agents/helper.md"
  else
    printf -- '---\nsurface: both\n---\nA body.\n' > "$d/.agents/helper.md"
  fi
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

# resolved_tools WORKSPACE — the `tools=` line pre.sh writes to GITHUB_OUTPUT.
resolved_tools() {
  local ws="$1" out bin marker log
  bin="$(new_tmp)"; marker="$(new_tmp)"; log="$(new_tmp)/gh.log"
  out="$(new_tmp)/gh_output"
  : > "$out"
  make_fake_gh "$bin" "$log"
  ( cd "$ws" && \
    env -i \
      PATH="$bin:$ORIG_PATH" HOME="$HOME" GITHUB_ACTIONS=true \
      GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$marker" GITHUB_RUN_ID="test" \
      GITHUB_OUTPUT="$out" \
      REPO="acme/widgets" RUN_ID="1" ISSUE_NUM="$TEST_ISSUE_NUM" COMMENT_ID="" \
      IS_PR="false" AGENT_NAME="helper" AUTODUCKS_BASE_REF="base-ref" \
      AUTODUCKS_PINNED_ROOT="$ws" \
      bash "$ws/.autoducks/agents/agent/pre.sh" ) >/dev/null 2>&1
  sed -n 's/^tools=//p' "$out" | tail -1
}

echo "1) a definition that declares tools still gets the output-contract tool"
T="$(resolved_tools "$(make_workspace '[WebSearch, WebFetch]')")"
if grep -q "Write" <<<"$T"; then
  pass "Write is present despite the definition not asking for it ($T)"
else
  fail "Write missing — the agent cannot satisfy its own output contract ($T)"
fi
if grep -q "WebSearch" <<<"$T" && grep -q "WebFetch" <<<"$T"; then
  pass "the declared tools survive alongside it"
else
  fail "declared tools were lost: $T"
fi

echo ""
echo "2) the floor does not silently widen a declared grant"
if ! grep -qE "(^|,)Edit(,|$)" <<<"$T" && ! grep -qE "(^|,)Bash" <<<"$T"; then
  pass "nothing beyond required_tools was added"
else
  fail "the resolved grant picked up more than the floor: $T"
fi

echo ""
echo "3) a definition with no tools still falls through to the lane default"
T2="$(resolved_tools "$(make_workspace '')")"
if [[ -z "$T2" ]]; then
  pass "empty tools= is emitted, so the workflow uses the lane default"
else
  fail "expected an empty tools= for a definition declaring none, got: $T2"
fi

echo ""
echo "4) Write is not duplicated when the definition already asks for it"
T3="$(resolved_tools "$(make_workspace '[Read, Write]')")"
if [[ "$(grep -o "Write" <<<"$T3" | wc -l | tr -d ' ')" == "1" ]]; then
  pass "Write appears exactly once ($T3)"
else
  fail "Write duplicated: $T3"
fi

echo ""
echo "=== agent lane pre.sh required tools (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
