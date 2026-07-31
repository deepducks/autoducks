#!/usr/bin/env bash
# Offline unit tests for the "agent" lane's tool resolution as consumed by
# .autoducks/agents/agent/pre.sh: the CSV `tools=` step output it derives
# from a discover-agents.sh descriptor's `.tools_effective`.
#
# Builds throwaway fixture repos under mktemp and drives the real
# discover-agents.sh (never a re-implementation of its precedence logic),
# then applies the exact jq transform pre.sh itself uses to turn
# `.tools_effective` into the comma-separated `tools=` output. Mirrors the
# fixture conventions in discover-agents.test.sh. Run via scripts/tests/run.sh,
# or directly: bash scripts/tests/agent-pre-tools.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISCOVER="$REPO_ROOT/.autoducks/core/config/discover-agents.sh"

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
}
trap cleanup EXIT

new_fixture() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  mkdir -p "$d/.autoducks" "$d/.agents"
  echo '{}' > "$d/.autoducks/autoducks.json"
  printf '%s' "$d"
}

discover() {
  local dir="$1"; shift
  GITHUB_WORKSPACE="$dir" bash "$DISCOVER" "$@"
}

# tools_csv DESCRIPTOR_JSON — the exact transform pre.sh applies to a
# discover-agents.sh `get` descriptor to produce its `tools=` step output.
tools_csv() {
  jq -r '.tools_effective // [] | join(",")' <<<"$1"
}

# ---------------------------------------------------------------------------
echo "1) neither custom_agents.agents.<name>.tools nor frontmatter tools -> tools= empty"
D="$(new_fixture)"
printf -- '---\ndescription: no tools declared anywhere\n---\nBody.\n' > "$D/.agents/bare-agent.md"

DESC="$(discover "$D" get bare-agent)"
CSV="$(tools_csv "$DESC")"
if [[ -z "$CSV" ]]; then
  pass "level 3 (neither declares): tools= empty, falls through to lane defaults.json"
else
  fail "expected empty tools=, got '$CSV'"
fi

# ---------------------------------------------------------------------------
echo "2) frontmatter tools alone becomes the effective, comma-joined list"
D="$(new_fixture)"
printf -- '---\ndescription: frontmatter only\ntools: [Read, Grep]\n---\nBody.\n' > "$D/.agents/fm-only-agent.md"

DESC="$(discover "$D" get fm-only-agent)"
CSV="$(tools_csv "$DESC")"
if [[ "$CSV" == "Read,Grep" ]]; then
  pass "level 2 (frontmatter alone): tools=Read,Grep"
else
  fail "expected tools=Read,Grep, got '$CSV'"
fi

# ---------------------------------------------------------------------------
echo "3) custom_agents.agents.<name>.tools beats frontmatter outright — no union, no intersection"
D="$(new_fixture)"
cat > "$D/.autoducks/autoducks.json" <<'JSON'
{
  "custom_agents": {
    "agents": {
      "override-agent": {
        "tools": ["Bash(git log:*)"]
      }
    }
  }
}
JSON
printf -- '---\ndescription: config beats frontmatter\ntools: [Read, Grep, Write]\n---\nBody.\n' \
  > "$D/.agents/override-agent.md"

DESC="$(discover "$D" get override-agent)"
CSV="$(tools_csv "$DESC")"
if [[ "$CSV" == "Bash(git log:*)" ]]; then
  pass "level 1 (config): tools=Bash(git log:*), entirely replacing frontmatter's [Read, Grep, Write]"
else
  fail "expected tools=Bash(git log:*) with no trace of frontmatter tools, got '$CSV'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== agent lane tool resolution (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
