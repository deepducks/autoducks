#!/usr/bin/env bash
# Unit tests for the "Build claude args" step of
# .autoducks/providers/llm/claude/action.yml.
#
# Extracts the step's embedded `run: |` script (the actual composite-action
# source, not a reimplementation) and executes it directly against a
# sandboxed .autoducks/providers/llm/claude/ tree, covering:
#   1. no compiled/ files            → claude_args/settings identical to today
#   2. base settings.json present    → settings points at it (no compiled/)
#   3. compiled/<agent>.allowed-tools → deduped union, input order then sorted delta
#   4. compiled/<agent>.allowed-tools with overlap → no duplicate tokens
#   5. compiled/<agent>.settings.json → preferred over the base settings.json
#   6. AUTODUCKS_PINNED_ROOT prefix respected for both compiled paths
#   7. agent name derived from prompt_file's parent directory
#
# Run: bash test/unit-llm-action-compiled-settings.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_FILE="$REPO_ROOT/.autoducks/providers/llm/claude/action.yml"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# extract_run_block FILE STEP_NAME — prints the de-indented body of the
# named step's `run: |` block (steps are at 4-space indent, script lines at
# 8-space indent in this composite action).
extract_run_block() {
  local file="$1" step_name="$2"
  awk -v step="    - name: $step_name" '
    $0 == step { instep=1; next }
    instep && /^    - name:/ { exit }
    instep && /^      run: \|/ { inrun=1; next }
    instep && inrun {
      if ($0 == "") { print ""; next }
      if (substr($0,1,8) == "        ") { print substr($0,9); next }
      exit
    }
  ' "$file"
}

SCRIPT="$SCRATCH/build-claude-args.sh"
extract_run_block "$ACTION_FILE" "Build claude args" > "$SCRIPT"

if [[ ! -s "$SCRIPT" ]]; then
  fail "could not extract 'Build claude args' run block from action.yml"
  echo ""
  echo "═══ llm-action-compiled-settings: $PASS passed, $FAIL failed ═══"
  exit 1
fi

SANDBOX="$SCRATCH/sandbox"
CLAUDE_DIR=".autoducks/providers/llm/claude"

reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/$CLAUDE_DIR"
}

# run_args MODEL MAX_TURNS ALLOWED_TOOLS EFFORT PROMPT_FILE [PINNED_ROOT]
# Executes the extracted script in the sandbox and returns claude_args=...
# and settings=... via globals CLAUDE_ARGS / SETTINGS.
run_args() {
  local model="$1" max_turns="$2" allowed_tools="$3" effort="$4" prompt_file="$5" pinned_root="${6:-}"
  local out="$SCRATCH/github_output"
  : > "$out"
  (
    cd "$SANDBOX"
    env -i \
      PATH="$PATH" \
      MODEL="$model" \
      MAX_TURNS="$max_turns" \
      ALLOWED_TOOLS="$allowed_tools" \
      EFFORT="$effort" \
      PROMPT_FILE="$prompt_file" \
      ${pinned_root:+AUTODUCKS_PINNED_ROOT="$pinned_root"} \
      GITHUB_OUTPUT="$out" \
      bash "$SCRIPT"
  )
  CLAUDE_ARGS="$(grep '^claude_args=' "$out" | sed 's/^claude_args=//')"
  SETTINGS="$(grep '^settings=' "$out" | sed 's/^settings=//')"
}

# ---------------------------------------------------------------------------
echo "── 1. no compiled/, no settings.json → matches today's behavior ──"
reset_sandbox
run_args "claude-sonnet-5" "50" "Read,Edit,Bash" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read,Edit,Bash' --effort high" ]]; then
  pass "claude_args unchanged with no compiled files"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi
if [[ -z "$SETTINGS" ]]; then
  pass "settings empty with no compiled/ and no base settings.json"
else
  fail "settings unexpectedly non-empty: $SETTINGS"
fi

# ---------------------------------------------------------------------------
echo "── 2. base settings.json present, no compiled/ → settings points at base ──"
reset_sandbox
echo '{}' > "$SANDBOX/$CLAUDE_DIR/settings.json"
run_args "claude-sonnet-5" "50" "Read,Edit,Bash" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$SETTINGS" == "./$CLAUDE_DIR/settings.json" ]]; then
  pass "settings points at base settings.json"
else
  fail "settings unexpected: $SETTINGS"
fi

# ---------------------------------------------------------------------------
echo "── 3. compiled/<agent>.allowed-tools → deduped union, input order then sorted delta ──"
reset_sandbox
mkdir -p "$SANDBOX/$CLAUDE_DIR/compiled"
printf 'Zebra\nApple\n' > "$SANDBOX/$CLAUDE_DIR/compiled/developer.allowed-tools"
run_args "claude-sonnet-5" "50" "Read,Edit" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read,Edit,Apple,Zebra' --effort high" ]]; then
  pass "allowedTools is input tools followed by sorted delta"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi

# ---------------------------------------------------------------------------
echo "── 4. compiled/<agent>.allowed-tools overlapping input → no duplicates ──"
reset_sandbox
mkdir -p "$SANDBOX/$CLAUDE_DIR/compiled"
printf 'Edit\nBash\n' > "$SANDBOX/$CLAUDE_DIR/compiled/developer.allowed-tools"
run_args "claude-sonnet-5" "50" "Read,Edit" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read,Edit,Bash' --effort high" ]]; then
  pass "overlapping delta tools are not duplicated, input-only tools preserved"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi

# ---------------------------------------------------------------------------
echo "── 5. compiled/<agent>.settings.json → preferred over base settings.json ──"
reset_sandbox
mkdir -p "$SANDBOX/$CLAUDE_DIR/compiled"
echo '{}' > "$SANDBOX/$CLAUDE_DIR/settings.json"
echo '{"compiled":true}' > "$SANDBOX/$CLAUDE_DIR/compiled/developer.settings.json"
run_args "claude-sonnet-5" "50" "Read,Edit" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$SETTINGS" == "./$CLAUDE_DIR/compiled/developer.settings.json" ]]; then
  pass "settings points at compiled/developer.settings.json over the base"
else
  fail "settings unexpected: $SETTINGS"
fi

# ---------------------------------------------------------------------------
echo "── 6. AUTODUCKS_PINNED_ROOT prefix respected for compiled lookups ──"
reset_sandbox
mkdir -p "$SANDBOX/pinned/$CLAUDE_DIR/compiled"
printf 'Extra\n' > "$SANDBOX/pinned/$CLAUDE_DIR/compiled/developer.allowed-tools"
echo '{"compiled":true}' > "$SANDBOX/pinned/$CLAUDE_DIR/compiled/developer.settings.json"
run_args "claude-sonnet-5" "50" "Read" "high" ".autoducks/agents/developer/prompt.md" "pinned"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read,Extra' --effort high" ]]; then
  pass "pinned root respected for the allowed-tools delta"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi
if [[ "$SETTINGS" == "pinned/$CLAUDE_DIR/compiled/developer.settings.json" ]]; then
  pass "pinned root respected for the compiled settings path"
else
  fail "settings unexpected: $SETTINGS"
fi

# ---------------------------------------------------------------------------
echo "── 7. agent name is derived from prompt_file's parent directory ──"
reset_sandbox
mkdir -p "$SANDBOX/$CLAUDE_DIR/compiled"
printf 'ReviewerOnly\n' > "$SANDBOX/$CLAUDE_DIR/compiled/reviewer.allowed-tools"
run_args "claude-sonnet-5" "50" "Read" "high" ".autoducks/agents/reviewer/prompt.md"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read,ReviewerOnly' --effort high" ]]; then
  pass "reviewer.allowed-tools picked up when prompt_file is under agents/reviewer/"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi
# The same delta file must NOT apply to a different agent's prompt_file.
run_args "claude-sonnet-5" "50" "Read" "high" ".autoducks/agents/developer/prompt.md"
if [[ "$CLAUDE_ARGS" == "--model claude-sonnet-5 --max-turns 50 --allowedTools 'Read' --effort high" ]]; then
  pass "reviewer.allowed-tools does not leak into the developer agent"
else
  fail "claude_args unexpected: $CLAUDE_ARGS"
fi

echo ""
echo "═══ llm-action-compiled-settings: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
