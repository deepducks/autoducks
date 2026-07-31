#!/usr/bin/env bash
# Offline unit tests for .autoducks/core/config/discover-agents.sh.
#
# Builds throwaway fixture repos under mktemp and points the script at them
# via GITHUB_WORKSPACE (the script reads the live working tree, never
# $AUTODUCKS_PINNED_ROOT), so this suite never touches the real repo tree
# and needs no network access. Run via scripts/tests/run.sh, or directly:
# bash scripts/tests/discover-agents.test.sh
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
  mkdir -p "$d/.autoducks"
  echo '{}' > "$d/.autoducks/autoducks.json"
  printf '%s' "$d"
}

# discover FIXTURE_DIR list|get... — runs discover-agents.sh against the
# fixture, capturing stdout separately from exit status.
discover() {
  local dir="$1"; shift
  GITHUB_WORKSPACE="$dir" bash "$DISCOVER" "$@"
}

# -----------------------------------------------------------------------
echo "1) empty repo — list emits {\"agents\":[],\"errors\":[]} and exits 0"
D="$(new_fixture)"
OUT="$(discover "$D" list)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == '{"agents":[],"errors":[]}' ]]; then
  pass "empty repo: exact empty registry, exit 0"
else
  fail "empty repo: got rc=$RC out=$OUT"
fi

# -----------------------------------------------------------------------
echo "2) get on an unknown name exits 4"
D="$(new_fixture)"
discover "$D" get does-not-exist >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 4 ]]; then
  pass "get unknown name exits 4"
else
  fail "get unknown name: expected exit 4, got $RC"
fi

# -----------------------------------------------------------------------
echo "3) precedence across all four built-in roots + shadowing"
D="$(new_fixture)"
mkdir -p "$D/.autoducks/custom/agents/dup-agent" "$D/.claude/agents" "$D/.agents" "$D/.github/agents"
printf -- '---\ndescription: root1 (highest precedence)\n---\nBody.\n' \
  > "$D/.autoducks/custom/agents/dup-agent/agent.md"
printf -- '---\ndescription: root2 (shadowed)\n---\nBody.\n' > "$D/.claude/agents/dup-agent.md"
printf -- '---\ndescription: root3 (shadowed)\n---\nBody.\n' > "$D/.agents/dup-agent.md"
printf -- '---\ndescription: root4 (shadowed)\n---\nBody.\n' > "$D/.github/agents/dup-agent.md"
# a distinct, non-colliding definition in root4 to prove root4 is scanned at all
printf -- '---\ndescription: unique to root4\n---\nBody.\n' > "$D/.github/agents/root4-only.md"

OUT="$(discover "$D" list)"
NAMES_COUNT="$(jq '[.agents[] | select(.name=="dup-agent")] | length' <<<"$OUT")"
if [[ "$NAMES_COUNT" -eq 4 ]]; then
  pass "definition present in all 4 roots yields 4 registry entries"
else
  fail "expected 4 dup-agent entries across roots, got $NAMES_COUNT"
fi

WINNER_SOURCE="$(jq -r '.agents[] | select(.name=="dup-agent" and .shadowed==false) | .source' <<<"$OUT")"
if [[ "$WINNER_SOURCE" == ".autoducks/custom/agents/dup-agent/agent.md" ]]; then
  pass "highest-precedence root (.autoducks/custom/agents) wins as non-shadowed"
else
  fail "expected root1 to win, got source '$WINNER_SOURCE'"
fi

SHADOWED_COUNT="$(jq '[.agents[] | select(.name=="dup-agent" and .shadowed==true)] | length' <<<"$OUT")"
if [[ "$SHADOWED_COUNT" -eq 3 ]]; then
  pass "the 3 lower-precedence duplicates are all shadowed:true"
else
  fail "expected 3 shadowed duplicates, got $SHADOWED_COUNT"
fi

R4_PRESENT="$(jq -r '.agents[] | select(.name=="root4-only") | .name' <<<"$OUT")"
if [[ "$R4_PRESENT" == "root4-only" ]]; then
  pass ".github/agents (root 4) is scanned"
else
  fail ".github/agents (root 4) definition was not discovered"
fi

GET_OUT="$(discover "$D" get dup-agent)"
GET_SOURCE="$(jq -r '.source' <<<"$GET_OUT")"
if [[ "$GET_SOURCE" == ".autoducks/custom/agents/dup-agent/agent.md" ]]; then
  pass "get returns the non-shadowed (highest-precedence) descriptor"
else
  fail "get returned unexpected source '$GET_SOURCE'"
fi

# -----------------------------------------------------------------------
echo "4) each validation refusal lands in errors[] with a distinct reason"
D="$(new_fixture)"
mkdir -p "$D/.agents"
echo '{"triggers":{"architect":["blueprint"]}}' > "$D/.autoducks/autoducks.json"

printf -- '---\ndescription: bad\n---\nBody\n' > "$D/.agents/Bad Name.md"
printf -- '---\ndescription: reserved builtin\n---\nBody\n' > "$D/.agents/architect.md"
printf -- '---\ndescription: reserved alias\n---\nBody\n' > "$D/.agents/blueprint.md"
python3 -c "open('$D/.agents/huge-agent.md','w').write('---\ndescription: huge\n---\n' + 'x'*70000)"
printf -- '---\ndescription: empty\n---\n\n\n' > "$D/.agents/empty-body-agent.md"
OUTSIDE="$(mktemp -d)"; TMP_DIRS+=("$OUTSIDE")
echo "outside content" > "$OUTSIDE/target.md"
ln -s "$OUTSIDE/target.md" "$D/.agents/escape-agent.md"

OUT="$(discover "$D" list)"

check_reason() {
  local source="$1" want="$2" label="$3"
  local got
  got="$(jq -r --arg s "$source" '.errors[] | select(.source==$s) | .reason' <<<"$OUT")"
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (got reason '$got', want '$want')"
  fi
}
check_reason ".agents/Bad Name.md"        "invalid-name"    "invalid name -> reason invalid-name"
check_reason ".agents/architect.md"       "reserved-name"   "built-in verb name -> reason reserved-name"
check_reason ".agents/blueprint.md"       "reserved-name"   "custom trigger alias name -> reason reserved-name"
check_reason ".agents/huge-agent.md"      "too-large"       "file over 64 KiB -> reason too-large"
check_reason ".agents/empty-body-agent.md" "empty-body"     "empty body after frontmatter -> reason empty-body"
check_reason ".agents/escape-agent.md"    "symlink-escape"  "symlink escaping the repo -> reason symlink-escape"

ERR_COUNT="$(jq '.errors | length' <<<"$OUT")"
if [[ "$ERR_COUNT" -eq 6 ]]; then
  pass "exactly 6 refusals recorded, none silently dropped"
else
  fail "expected 6 errors, got $ERR_COUNT: $(jq -c '.errors' <<<"$OUT")"
fi

for bad in "Bad Name" architect blueprint huge-agent empty-body-agent escape-agent; do
  IN_AGENTS="$(jq --arg n "$bad" '[.agents[] | select(.name==$n)] | length' <<<"$OUT")"
  if [[ "$IN_AGENTS" -ne 0 ]]; then
    fail "refused definition '$bad' must not also appear in agents[]"
  fi
done
pass "none of the refused definitions leaked into agents[]"

REFUSED_GET_RC=0
discover "$D" get architect >/dev/null 2>&1 || REFUSED_GET_RC=$?
if [[ "$REFUSED_GET_RC" -eq 4 ]]; then
  pass "get on a refused name exits 4"
else
  fail "get on a refused name: expected exit 4, got $REFUSED_GET_RC"
fi

# -----------------------------------------------------------------------
echo "5) 'tools: Read, Grep' and 'tools: [Read, Grep]' produce identical tools_declared"
D="$(new_fixture)"
mkdir -p "$D/.agents"
printf -- '---\ndescription: comma form\ntools: Read, Grep\n---\nBody.\n' > "$D/.agents/comma-tools.md"
printf -- '---\ndescription: list form\ntools: [Read, Grep]\n---\nBody.\n' > "$D/.agents/list-tools.md"

OUT="$(discover "$D" list)"
COMMA_JSON="$(jq -c '.agents[] | select(.name=="comma-tools") | .tools_declared' <<<"$OUT")"
LIST_JSON="$(jq -c '.agents[] | select(.name=="list-tools") | .tools_declared' <<<"$OUT")"
if [[ "$COMMA_JSON" == '["Read","Grep"]' && "$LIST_JSON" == '["Read","Grep"]' ]]; then
  pass "comma-string and inline-array tools spellings produce identical tools_declared"
else
  fail "tools spellings diverged: comma=$COMMA_JSON list=$LIST_JSON"
fi

# -----------------------------------------------------------------------
echo "6) an unrecognized frontmatter key is ignored, not an error, and doesn't change the descriptor"
D="$(new_fixture)"
mkdir -p "$D/.agents"
printf -- '---\ndescription: baseline\n---\nBody.\n' > "$D/.agents/baseline.md"
printf -- '---\ndescription: baseline\nunknown_scalar: surprise\nunknown_list:\n  - x\n  - y\n---\nBody.\n' > "$D/.agents/with-unknown-key.md"

OUT="$(discover "$D" list)"
ERR_COUNT="$(jq '.errors | length' <<<"$OUT")"
if [[ "$ERR_COUNT" -eq 0 ]]; then
  pass "unrecognized frontmatter key produces zero entries in errors[]"
else
  fail "expected 0 errors, got $ERR_COUNT: $(jq -c '.errors' <<<"$OUT")"
fi
BASELINE_DESC="$(jq -c '.agents[] | select(.name=="baseline") | del(.source,.name)' <<<"$OUT")"
UNKNOWN_DESC="$(jq -c '.agents[] | select(.name=="with-unknown-key") | del(.source,.name)' <<<"$OUT")"
if [[ "$BASELINE_DESC" == "$UNKNOWN_DESC" ]]; then
  pass "descriptor is unchanged by the presence of an unrecognized key"
else
  fail "descriptor differs because of an unknown key: baseline=$BASELINE_DESC unknown=$UNKNOWN_DESC"
fi

# -----------------------------------------------------------------------
echo "7) a .md with no frontmatter at all is discovered with defaults and the whole file as body"
D="$(new_fixture)"
mkdir -p "$D/.agents"
printf 'Just a plain body, no frontmatter delimiters here.\n' > "$D/.agents/no-frontmatter.md"

OUT="$(discover "$D" list)"
ENTRY="$(jq -c '.agents[] | select(.name=="no-frontmatter")' <<<"$OUT")"
if [[ -n "$ENTRY" ]]; then
  pass "file with no frontmatter is discovered"
else
  fail "file with no frontmatter was not discovered at all: $OUT"
fi
DESC_NULL="$(jq -r '.description' <<<"$ENTRY")"
SURFACE_DEFAULT="$(jq -r '.surface' <<<"$ENTRY")"
BODY_BYTES="$(jq -r '.body_bytes' <<<"$ENTRY")"
if [[ "$DESC_NULL" == "null" && "$SURFACE_DEFAULT" == "issue" && "$BODY_BYTES" -gt 0 ]]; then
  pass "no-frontmatter file gets null description, default surface, non-zero body_bytes"
else
  fail "no-frontmatter descriptor wrong: $ENTRY"
fi

# -----------------------------------------------------------------------
echo "8) config-over-frontmatter for tools, frontmatter-over-config for model"
D="$(new_fixture)"
mkdir -p "$D/.claude/agents"
cat > "$D/.autoducks/autoducks.json" <<'JSON'
{
  "custom_agents": {
    "agents": {
      "merge-agent": {
        "tools": ["Bash"],
        "model": "haiku"
      }
    }
  }
}
JSON
printf -- '---\ndescription: merge precedence\ntools: [Read, Grep]\nmodel: opus\n---\nBody.\n' \
  > "$D/.claude/agents/merge-agent.md"

OUT="$(discover "$D" list)"
ENTRY="$(jq -c '.agents[] | select(.name=="merge-agent")' <<<"$OUT")"
TOOLS_DECLARED="$(jq -c '.tools_declared' <<<"$ENTRY")"
TOOLS_EFFECTIVE="$(jq -c '.tools_effective' <<<"$ENTRY")"
MODEL="$(jq -r '.model' <<<"$ENTRY")"
if [[ "$TOOLS_DECLARED" == '["Read","Grep"]' ]]; then
  pass "tools_declared reflects the frontmatter value"
else
  fail "tools_declared wrong: $TOOLS_DECLARED"
fi
if [[ "$TOOLS_EFFECTIVE" == '["Bash"]' ]]; then
  pass "tools: config wins over frontmatter in tools_effective"
else
  fail "tools_effective wrong: expected config to win, got $TOOLS_EFFECTIVE"
fi
if [[ "$MODEL" == "claude-opus-5" ]]; then
  pass "model: frontmatter wins over config (and is alias-resolved)"
else
  fail "model wrong: expected frontmatter 'opus' -> claude-opus-5 to win, got $MODEL"
fi

# -----------------------------------------------------------------------
echo ""
echo "=== discover-agents (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
