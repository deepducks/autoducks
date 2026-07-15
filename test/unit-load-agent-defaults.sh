#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/load-agent-defaults.sh — specifically
# the `tools=` resolution (union of per-agent base tools and the universal
# `defaults.tools` grant, overridable per-agent via `tools_default`).
# Run: bash test/unit-load-agent-defaults.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.autoducks/core/config/load-agent-defaults.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# new_root NAME — fresh synthetic $AUTODUCKS_ROOT with an "agent" agent dir;
# returns via global ROOT.
new_root() {
  ROOT="$SCRATCH/$1"
  mkdir -p "$ROOT/agents/agent"
}

# tools_line ROOT — runs the resolver against ROOT for AUTODUCKS_AGENT=agent
# and echoes just the `tools=` output line's value.
tools_line() {
  local root="$1"
  AUTODUCKS_AGENT=agent AUTODUCKS_ROOT="$root" bash "$SCRIPT" | sed -n 's/^tools=//p'
}

echo "── union of per-agent base and defaults.tools ──"
new_root union
echo '{"defaults":{"tools":["Read","Write"]}}' > "$ROOT/autoducks.json"
echo '{"tools":["Bash","WebFetch"]}' > "$ROOT/agents/agent/defaults.json"
GOT="$(tools_line "$ROOT")"
EXPECTED="$(jq -rn '(["Bash","WebFetch"] + ["Read","Write"]) | unique_by(.) | join(",")')"
[[ "$GOT" == "$EXPECTED" ]] && pass "union of agent base and universal default" || fail "expected [$EXPECTED], got [$GOT]"

echo "── exact-duplicate tokens collapse ──"
new_root dedup
echo '{"defaults":{"tools":["WebFetch"]}}' > "$ROOT/autoducks.json"
echo '{"tools":["WebFetch"]}' > "$ROOT/agents/agent/defaults.json"
GOT="$(tools_line "$ROOT")"
[[ "$GOT" == "WebFetch" ]] && pass "duplicate WebFetch collapses to one token" || fail "expected [WebFetch], got [$GOT]"

echo "── tools_default: [] suppresses the universal default for that agent, base survives ──"
new_root suppress
echo '{"defaults":{"tools":["Read","Write"]}}' > "$ROOT/autoducks.json"
echo '{"tools":["Bash"],"tools_default":[]}' > "$ROOT/agents/agent/defaults.json"
GOT="$(tools_line "$ROOT")"
[[ "$GOT" == "Bash" ]] && pass "tools_default:[] drops universal default, keeps agent base" || fail "expected [Bash], got [$GOT]"

echo "── tools_default: [] on one agent does not affect another agent's resolution ──"
mkdir -p "$ROOT/agents/other"
echo '{"tools":["Bash"]}' > "$ROOT/agents/other/defaults.json"
GOT_OTHER="$(AUTODUCKS_AGENT=other AUTODUCKS_ROOT="$ROOT" bash "$SCRIPT" | sed -n 's/^tools=//p')"
EXPECTED_OTHER="$(jq -rn '(["Bash"] + ["Read","Write"]) | unique_by(.) | join(",")')"
[[ "$GOT_OTHER" == "$EXPECTED_OTHER" ]] && pass "unrelated agent still receives the universal default" || fail "expected [$EXPECTED_OTHER], got [$GOT_OTHER]"

echo "── space-bearing token round-trips through the CSV without splitting ──"
new_root spacetoken
echo '{"defaults":{"tools":[]}}' > "$ROOT/autoducks.json"
echo '{"tools":["Bash(git branch --list:*)","Read"]}' > "$ROOT/agents/agent/defaults.json"
GOT="$(tools_line "$ROOT")"
IFS=',' read -ra TOKENS <<< "$GOT"
if [[ "${#TOKENS[@]}" -eq 2 ]] && printf '%s\n' "${TOKENS[@]}" | grep -qxF 'Bash(git branch --list:*)'; then
  pass "space-bearing token survives as a single CSV field"
else
  fail "space-bearing token was split or malformed: [$GOT] (${#TOKENS[@]} fields)"
fi

echo "── absent per-agent tools and absent defaults.tools → tools= emitted empty, no error ──"
new_root empty
echo '{}' > "$ROOT/autoducks.json"
rm -rf "$ROOT/agents/agent"
RC=0
OUT="$(AUTODUCKS_AGENT=agent AUTODUCKS_ROOT="$ROOT" bash "$SCRIPT" 2>"$SCRATCH/empty.err")" || RC=$?
[[ "$RC" -eq 0 ]] && pass "script exits successfully with no per-agent config at all" || fail "expected exit 0, got $RC: $(cat "$SCRATCH/empty.err")"
echo "$OUT" | grep -qx 'tools=' && pass "tools= emitted empty" || fail "expected an empty tools= line, got: $OUT"

echo "── output is a single line with no trailing newline embedded in the value ──"
new_root singleline
echo '{"defaults":{"tools":["Read"]}}' > "$ROOT/autoducks.json"
echo '{"tools":["Bash"]}' > "$ROOT/agents/agent/defaults.json"
LINE_COUNT="$(AUTODUCKS_AGENT=agent AUTODUCKS_ROOT="$ROOT" bash "$SCRIPT" | grep -c '^tools=')"
[[ "$LINE_COUNT" -eq 1 ]] && pass "exactly one tools= line emitted" || fail "expected exactly one tools= line, got $LINE_COUNT"

echo ""
echo "═══ load-agent-defaults: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
