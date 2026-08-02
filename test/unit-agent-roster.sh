#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/agent-roster.sh
# Run: bash test/unit-agent-roster.sh
#
# The roster drifted twice: generate-trigger-conditions.sh knew about 13
# agents while parse-directive.sh's normalize_verb() resolved 10, so a
# `triage`/`merge`/`update` alias validated at install, fired its workflow,
# and then emitted the raw alias as `command=`. These tests assert the two
# ends agree and that no second copy of the list has grown back.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/.autoducks/core/config"
ROSTER="$CONFIG_DIR/agent-roster.sh"
PARSE="$CONFIG_DIR/parse-directive.sh"
GENERATE="$CONFIG_DIR/generate-trigger-conditions.sh"
DISCOVER="$CONFIG_DIR/discover-agents.sh"
SCAFFOLD="$REPO_ROOT/.autoducks/autoducks.json"

PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$ROSTER"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
echo "── the roster is populated and self-consistent ──"

if [[ "${#AUTODUCKS_AGENTS[@]}" -ge 13 ]]; then
  pass "AUTODUCKS_AGENTS has ${#AUTODUCKS_AGENTS[@]} entries"
else
  fail "AUTODUCKS_AGENTS has only ${#AUTODUCKS_AGENTS[@]} entries"
fi

for _agent in triage merge update; do
  if [[ " ${AUTODUCKS_AGENTS[*]} " == *" $_agent "* ]]; then
    pass "roster includes $_agent"
  else
    fail "roster is missing $_agent"
  fi
done

# Every canonical name and every synonym key must be a built-in verb, or
# generate-trigger-conditions.sh will let a custom alias shadow an agent.
for _agent in "${AUTODUCKS_AGENTS[@]}"; do
  if [[ " $AUTODUCKS_BUILTIN_VERBS " == *" $_agent "* ]]; then
    pass "builtin verbs cover agent $_agent"
  else
    fail "builtin verbs are missing agent $_agent"
  fi
done

for _syn in "${AUTODUCKS_VERB_SYNONYMS[@]}"; do
  _from="${_syn%%:*}"; _to="${_syn#*:}"
  if [[ " $AUTODUCKS_BUILTIN_VERBS " == *" $_from "* ]]; then
    pass "builtin verbs cover synonym $_from"
  else
    fail "builtin verbs are missing synonym $_from"
  fi
  if [[ " ${AUTODUCKS_AGENTS[*]} " == *" $_to "* ]]; then
    pass "synonym $_from resolves to real agent $_to"
  else
    fail "synonym $_from resolves to unknown agent $_to"
  fi
done

# ---------------------------------------------------------------------------
echo "── the roster is the only copy of the list ──"

# A literal agent list in either consumer is how the drift happened, in both
# cases as a space-separated run — an array literal or a `for x in ...` list.
# Match four or more canonical names in a row.
_NAME='(architect|engineer|execute|fix|revert|close|review|rework|defer|resolve|triage|merge|update)'
for _f in "$PARSE" "$GENERATE" "$DISCOVER"; do
  if grep -qE "$_NAME( $_NAME){3,}" "$_f"; then
    fail "$(basename "$_f") still spells out an agent list — source agent-roster.sh instead"
  else
    pass "$(basename "$_f") carries no second copy of the roster"
  fi
done

# is_chainable_verb() is a deliberate subset (a chainable verb needs a
# workflow_dispatch entry point), so it cannot derive from the roster — but
# every verb it names must still be a real agent.
while IFS= read -r _verb; do
  if [[ " ${AUTODUCKS_AGENTS[*]} " == *" $_verb "* ]]; then
    pass "chainable verb $_verb is in the roster"
  else
    fail "chainable verb $_verb is not a known agent"
  fi
done < <(sed -n '/^is_chainable_verb()/,/^}/p' "$PARSE" \
           | grep -oE '^ *[a-z|]+\) return 0' | grep -oE '[a-z|]+' | head -1 | tr '|' '\n')

# ---------------------------------------------------------------------------
echo "── the scaffolded config matches the roster ──"

if command -v jq &>/dev/null; then
  _cfg_keys=$(jq -r '.triggers | keys[]' "$SCAFFOLD" | sort | tr '\n' ' ')
  _roster_keys=$(printf '%s\n' "${AUTODUCKS_AGENTS[@]}" | sort | tr '\n' ' ')
  if [[ "$_cfg_keys" == "$_roster_keys" ]]; then
    pass "autoducks.json .triggers keys == AUTODUCKS_AGENTS"
  else
    fail "autoducks.json .triggers keys drifted — config '$_cfg_keys' vs roster '$_roster_keys'"
  fi
else
  echo "  ⏭  jq not installed — skipping config comparison"
fi

# ---------------------------------------------------------------------------
echo "── an alias resolves for every agent, install-time and run-time ──"

# One custom alias per agent, named after it, so a passthrough cannot be
# mistaken for a successful resolution. Both ends need jq to read the config.
if ! command -v jq &>/dev/null; then
  echo "  ⏭  jq not installed — skipping alias round-trip"
  echo
  echo "Passed: $PASS  Failed: $FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

printf '%s\n' "${AUTODUCKS_AGENTS[@]}" | jq -R . | jq -s \
  '{command: "", triggers: (map({key: ., value: ["zz-" + .]}) | from_entries)}' \
  > "$TMP_DIR/config.json"

for _agent in "${AUTODUCKS_AGENTS[@]}"; do
  # Run time: parse-directive.sh must map the alias back to the canonical verb.
  _out=$(COMMENT_BODY="/zz-$_agent" AUTODUCKS_CONFIG="$TMP_DIR/config.json" \
           bash "$PARSE" </dev/null)
  _got=$(printf '%s\n' "$_out" | grep '^command=' || true)
  if [[ "$_got" == "command=$_agent" ]]; then
    pass "run-time: /zz-$_agent → command=$_agent"
  else
    fail "run-time: /zz-$_agent → '$_got' (want 'command=$_agent')"
  fi

  # Install time: the same alias must be baked into that agent's guard.
  _frag=$(AUTODUCKS_CONFIG="$TMP_DIR/config.json" AUTODUCKS_AGENT="$_agent" \
            bash "$GENERATE" 2>/dev/null || true)
  if [[ "$_frag" == *"zz-$_agent"* ]]; then
    pass "install-time: guard for $_agent bakes /zz-$_agent"
  else
    fail "install-time: guard for $_agent omits /zz-$_agent — got '$_frag'"
  fi
done

# ---------------------------------------------------------------------------
echo "── discover-agents reserves every canonical name and every alias ──"

# The third consumer. It carried its own copy of both lists, already a release
# behind: `agent` was missing, so a definition called agent.md was not reserved
# and shadowed /agent, and aliases under triggers.agent[] were not collected
# into RESERVED_NAMES either. Grepping for a literal list (above) proves the
# copy is gone; this proves the behaviour it was supposed to produce.
_SCRATCH="$TMP_DIR/repo"
mkdir -p "$_SCRATCH/.claude/agents" "$_SCRATCH/.autoducks"
cp "$TMP_DIR/config.json" "$_SCRATCH/.autoducks/autoducks.json"

for _agent in "${AUTODUCKS_AGENTS[@]}"; do
  : > "$_SCRATCH/.claude/agents/$_agent.md"        # canonical name
  : > "$_SCRATCH/.claude/agents/zz-$_agent.md"     # its configured alias
done
for _syn in "${AUTODUCKS_VERB_SYNONYMS[@]}"; do
  : > "$_SCRATCH/.claude/agents/${_syn%%:*}.md"    # built-in synonym
done

_REG=$(cd "$_SCRATCH" && GITHUB_WORKSPACE="$_SCRATCH" bash "$DISCOVER" list 2>/dev/null || echo '{}')

_check_reserved() {
  local name="$1" kind="$2"
  if [[ "$(jq -r --arg s ".claude/agents/$name.md" \
            '[.errors[]? | select(.source == $s and .reason == "reserved-name")] | length' \
            <<< "$_REG")" == "1" ]]; then
    pass "discover-agents reserves $kind $name"
  else
    fail "discover-agents did not reserve $kind $name — it would shadow /$name"
  fi
}

for _agent in "${AUTODUCKS_AGENTS[@]}"; do
  _check_reserved "$_agent" "agent"
  _check_reserved "zz-$_agent" "alias"
done
for _syn in "${AUTODUCKS_VERB_SYNONYMS[@]}"; do
  _check_reserved "${_syn%%:*}" "synonym"
done

# ---------------------------------------------------------------------------
echo "── a .triggers key naming no agent is rejected at install time ──"

# The inverse of the scaffold check above. A missing key is legitimate ("no
# aliases"); a key naming nothing is a typo that validates, installs, and never
# fires, because the generator only ever reads keys it already knows.
jq '.triggers += {"triage-all": ["classify"]}' "$TMP_DIR/config.json" > "$TMP_DIR/bogus.json"
if AUTODUCKS_CONFIG="$TMP_DIR/bogus.json" AUTODUCKS_AGENT="triage" \
     bash "$GENERATE" >/dev/null 2>&1; then
  fail "validate_triggers accepted '.triggers.triage-all', which names no agent"
else
  pass "validate_triggers rejects a .triggers key that names no agent"
fi

if AUTODUCKS_CONFIG="$TMP_DIR/config.json" AUTODUCKS_AGENT="triage" \
     bash "$GENERATE" >/dev/null 2>&1; then
  pass "validate_triggers still accepts a config whose keys are all agents"
else
  fail "validate_triggers rejected a valid config"
fi

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
