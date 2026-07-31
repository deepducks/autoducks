#!/usr/bin/env bash
# Regression tests for #175 — agent context must reach jq through files, not argv.
# Run: bash test/unit-jq-large-payloads.sh
#
# Linux caps a *single* argv entry at 128 KiB (MAX_ARG_STRLEN), independently of
# how much total ARG_MAX allows. `jq --argjson issues "$BIG"` therefore dies with
# `Argument list too long` and exit 126 — execve refuses before jq parses a byte.
#
# This failed open in the worst way: it is size-dependent, so triage worked until
# the backlog crossed the line and then never worked again, and the more review
# rounds a PR needed the more certain the rework agent was to die on it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_PRE="$REPO_ROOT/.autoducks/agents/product/pre.sh"
REWORK_PRE="$REPO_ROOT/.autoducks/agents/rework/pre.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
echo "── the limit this guards against is real ──"

# ~2 MiB: past MAX_ARG_STRLEN on Linux and past total ARG_MAX on macOS, so the
# demonstration below is meaningful on both.
BIG_FILE="$SCRATCH/big.json"
jq -nc '[range(12000) | {number: ., title: ("issue " + (.|tostring)),
        body: ("x" * 150)}]' > "$BIG_FILE"
BIG_BYTES=$(wc -c < "$BIG_FILE" | tr -d ' ')
if [[ "$BIG_BYTES" -gt 1000000 ]]; then
  pass "built a ${BIG_BYTES}-byte payload (over the 128 KiB single-arg cap)"
else
  fail "payload is only $BIG_BYTES bytes — too small to exercise the limit"
fi

BIG_JSON="$(cat "$BIG_FILE")"
if jq -n --argjson issues "$BIG_JSON" '$issues | length' >/dev/null 2>&1; then
  fail "--argjson accepted a ${BIG_BYTES}-byte argument — this platform cannot demonstrate the bug"
else
  pass "--argjson refuses it, exactly as production did"
fi

if out=$(jq -n --slurpfile issues "$BIG_FILE" '$issues[0] | length' 2>/dev/null); then
  if [[ "$out" == "12000" ]]; then
    pass "--slurpfile handles the same payload and preserves every element"
  else
    fail "--slurpfile returned '$out' elements, expected 12000"
  fi
else
  fail "--slurpfile failed on the large payload"
fi

# ---------------------------------------------------------------------------
echo "── no agent passes an unbounded collection through argv ──"

# Named explicitly rather than pattern-matched: these are the inputs with no
# ceiling — the backlog, and a PR's accumulated review/comment history.
# Comment lines are stripped first: the fix documents the old `--argjson issues
# "$ISSUES_JSON"` call verbatim, and matching that would fail forever.
check_not_argjson() { # FILE VAR_NAME
  local file="$1" var="$2"
  if sed 's/^[[:space:]]*#.*$//' "$file" \
       | grep -qE -- "--argjson [a-z_]+ \"\\\$$var\""; then
    fail "$(basename "$(dirname "$file")")/pre.sh passes \$$var via --argjson"
  else
    pass "$(basename "$(dirname "$file")")/pre.sh does not pass \$$var via --argjson"
  fi
}

check_not_argjson "$PRODUCT_PRE" ISSUES_JSON
check_not_argjson "$PRODUCT_PRE" INBOX_NUMBERS
check_not_argjson "$REWORK_PRE" REVIEWS_JSON
check_not_argjson "$REWORK_PRE" PR_COMMENTS_JSON
check_not_argjson "$REWORK_PRE" FEATURE_COMMENTS_JSON

for f in "$PRODUCT_PRE" "$REWORK_PRE"; do
  n=$(grep -c -- '--slurpfile' "$f" || true)
  if [[ "$n" -ge 1 ]]; then
    pass "$(basename "$(dirname "$f")")/pre.sh reads its bulk context from files ($n)"
  else
    fail "$(basename "$(dirname "$f")")/pre.sh has no --slurpfile"
  fi
done

# ---------------------------------------------------------------------------
echo "── the rework transform still produces the same rendering ──"

# The --slurpfile rewrite had to rebind $reviews/$prc/$fc; a wrong index would
# silently render an empty context rather than fail, which is worse than a crash.
R="$SCRATCH/r.json"; P="$SCRATCH/p.json"; F="$SCRATCH/f.json"
echo '[{"author":"rev","body":"looks wrong","submittedAt":"2026-01-03","state":"COMMENTED"}]' > "$R"
echo '[{"author":"cmt","body":"a pr comment","created_at":"2026-01-02"}]' > "$P"
echo '[{"author":"feat","body":"a feature note","created_at":"2026-01-01"}]' > "$F"

out=$(jq -n -r \
  --slurpfile reviews_w "$R" --slurpfile prc_w "$P" --slurpfile fc_w "$F" '
  ($reviews_w[0]) as $reviews
  | ($prc_w[0]) as $prc
  | ($fc_w[0]) as $fc
  | ( [ $reviews[] | {author, body, when: (.submittedAt // .createdAt // ""),
        kind: (if (.state // "") != "" then "PR review" else "PR inline comment" end)} ]
    + [ $prc[] | {author, body, when: (.created_at // ""), kind: "PR comment"} ]
    + [ $fc[]  | {author, body, when: (.created_at // ""), kind: "Feature comment"} ] )
  | map(select((.body // "") != ""))
  | sort_by(.when) | reverse
  | .[] | .kind + "|" + .author' 2>/dev/null)

expected='PR review|rev
PR comment|cmt
Feature comment|feat'
if [[ "$out" == "$expected" ]]; then
  pass "all three sources render, newest first"
else
  fail "rendering changed — got: $(printf '%s' "$out" | tr '\n' ' ')"
fi

# An empty source must not blank the others out.
echo '[]' > "$P"
out=$(jq -n -r --slurpfile reviews_w "$R" --slurpfile prc_w "$P" --slurpfile fc_w "$F" '
  ($reviews_w[0]) as $reviews | ($prc_w[0]) as $prc | ($fc_w[0]) as $fc
  | ([ $reviews[] | {author} ] + [ $prc[] | {author} ] + [ $fc[] | {author} ])
  | length' 2>/dev/null)
if [[ "$out" == "2" ]]; then
  pass "an empty source drops out without taking the others with it"
else
  fail "empty source produced '$out' entries, expected 2"
fi

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
