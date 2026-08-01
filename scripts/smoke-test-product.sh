#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Product Agent (Triage + Merge)
# =============================================================================
#
# PURPOSE
# -------
# Exercises the product-agent pair that scripts/smoke-test.sh and
# scripts/smoke-test-plan.sh don't cover:
#
#   1. /triage priority assignment — a fresh, unprioritized issue gets a
#      `Priority:*` label from a real triage sweep.
#   2. /merge duplicate close — a deterministic `/merge #<target>` comment
#      closes the commenting issue as a duplicate, cross-references both
#      issues, and labels the closed one `Duplicate`.
#
# WARNING — REAL BACKLOG SIDE EFFECTS
# ------------------------------------
# `/triage` always runs a **full backlog sweep** (see `pre.sh`/the product
# workflow's `Set context` step — a `/triage` comment never scopes to just
# the issue it was posted on). The bot's editable status comment still
# lands on the issue the `/triage` comment was posted on (pre.sh tracks
# that separately from the sweep scope), but it does not narrow what gets
# triaged. With the default config (`flag_duplicates: true`), the same sweep
# also lets the LLM flag duplicates across your *entire* open backlog.
#
# The sweep no longer CLOSES anything: duplicates are labelled and
# cross-referenced, and a human decides what to close. So the blast radius
# here is `Priority:*`/`Bug`/`Feature` labels and duplicate-pointer comments
# on real issues — annoying to undo by hand, but nothing disappears. The
# `/merge` half below still closes, because that half is an explicit command
# naming both issues. Prefer running against a disposable/staging repo
# anyway, or one whose backlog is already groomed.
#
# COST
# ----
# One product-agent LLM call (`sonnet high`, per `agents/product/defaults.json`)
# over the full open-issue backlog for the triage half; the merge half is
# fully deterministic (no LLM). Expected wall time: 1–5 min depending on
# backlog size.
#
# USAGE
# -----
#   ./scripts/smoke-test-product.sh [OPTIONS]
#
# OPTIONS
#   --keep          Do not close the fixture issues at the end (leaves them
#                   in place for manual inspection).
#   --no-wait       Create the priority fixture issue and trigger /triage,
#                   don't wait for completion or run the /merge half.
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`).
#   -h, --help      Show this help.
#
# ASSERTIONS (SOFT vs HARD)
# -------------------------
# Hard assertions (fail the test if violated):
#   - /triage run completes with success (👍 reaction on the trigger comment)
#   - Priority fixture issue receives a `Priority:*` label (when the active
#     priority backend is `labels`/`auto`, the default)
#   - /merge run completes with success (👍 reaction on the trigger comment)
#   - Duplicate fixture issue is closed with a `Duplicate` label
#   - Duplicate fixture issue's close comment cross-references the canonical
#   - Canonical fixture issue receives a fold-in cross-reference comment
#
# Soft assertions (logged as warning if violated, test still passes):
#   - Priority label when `product.priority_backend` is `project`/`off`
#     (can't be verified from labels alone)
#   - Sub-issue link between the duplicate and canonical issues (requires
#     sub-issues API enabled)
# =============================================================================

set -euo pipefail

KEEP=false
WAIT=true
REPO=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,64p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
else
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
fi

echo "=== Smoke Test — Product Agent (Triage + Merge) ==="
echo "Repo: $REPO"
echo "Timestamp: $TIMESTAMP"
echo ""

FAIL=0
WARN=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

# Poll a comment's reactions for the terminal signal every product-agent
# workflow posts: +1 → success, confused → failure. Scoped to the specific
# comment, immune to GitHub's occasional double-fire on issue_comment, and
# safe alongside parallel workflows on other issues. Returns 0=success,
# 1=failure, 2=timeout. Identical to smoke-test-plan.sh's helper.
wait_for_reaction() {
  local comment_id="$1"
  local timeout_s="$2"
  local label="$3"
  local interval=10
  local waited=0
  local reactions=""
  while [[ $waited -lt $timeout_s ]]; do
    reactions=$(gh api "repos/$REPO/issues/comments/$comment_id/reactions" \
      --jq '[.[].content] | join(",")' 2>/dev/null || echo "")
    case ",$reactions," in
      *,+1,*)       return 0 ;;
      *,confused,*) return 1 ;;
    esac
    sleep $interval
    waited=$((waited + interval))
    if [[ $((waited % 60)) -eq 0 ]]; then
      echo "  ... $label ${waited}/${timeout_s}s (reactions: ${reactions:-none})"
    fi
  done
  return 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/config/label-utils.sh"
PRIORITY_BACKEND_CONFIGURED=$(jq -r '.product.priority_backend // "auto"' "$SCRIPT_DIR/../.autoducks/autoducks.json" 2>/dev/null || echo "auto")

# --- Ensure labels exist ---
echo "[1/8] Ensuring labels exist..."
label::ensure "smoke-test" "FFA500" "Smoke test" || echo "Warning: failed to ensure label 'smoke-test'" >&2
label::ensure "Duplicate"  "CFD3D7" "Closed as a duplicate of another issue" || echo "Warning: failed to ensure label 'Duplicate'" >&2
pass "Labels ensured"
echo ""

# =============================================================================
# Part 1 — /triage priority assignment
# =============================================================================
echo "[2/8] Creating priority fixture issue..."
PRIORITY_BODY=$(cat <<EOF
# Triage smoke test — ${TIMESTAMP}

Users report that the nightly export job crashes with an out-of-memory
error whenever the dataset exceeds ~2GB, silently truncating the output
file. This blocks the weekly reporting pipeline for every team that
depends on the export, and there is no workaround short of manually
splitting the input.

This is a synthetic issue created by \`smoke-test-product.sh\` to exercise
the /triage priority-assignment pipeline end-to-end. It carries no real
priority signal beyond what's written here.

## Impact

- Nightly export job OOMs above ~2GB input
- Output file is silently truncated (no error surfaced to users)
- Blocks the weekly reporting pipeline repo-wide
EOF
)

PRIORITY_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [triage priority] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$PRIORITY_BODY")
PRIORITY_ISSUE=$(echo "$PRIORITY_URL" | grep -oE '[0-9]+$')
echo "  Priority fixture issue: #$PRIORITY_ISSUE → $PRIORITY_URL"
echo ""

# --- Trigger /triage (always a full backlog sweep — see WARNING above) ---
echo "[3/8] Triggering /triage..."
TRIAGE_COMMENT_URL=$(gh issue comment $PRIORITY_ISSUE $REPO_ARG --body "/triage")
TRIAGE_COMMENT_ID=$(echo "$TRIAGE_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Triage comment posted (id: ${TRIAGE_COMMENT_ID:-unknown})"

if [[ "$WAIT" == false ]]; then
  echo ""
  echo "Skipping wait (--no-wait). Priority fixture: $PRIORITY_URL"
  exit 0
fi
echo ""

echo "[4/8] Waiting for product-agent terminal reaction (triage)..."
if [[ -z "${TRIAGE_COMMENT_ID:-}" ]]; then
  fail "cannot track product-agent — missing TRIAGE_COMMENT_ID"
  exit 1
fi
TRIAGE_RC=0
wait_for_reaction "$TRIAGE_COMMENT_ID" 600 "product-agent (triage)" || TRIAGE_RC=$?
case $TRIAGE_RC in
  0) pass "product-agent triage run completed successfully" ;;
  1) fail "product-agent triage run failed (😕 reaction on /triage comment)"; exit 1 ;;
  2) fail "product-agent triage run did not complete within 10 min"; exit 1 ;;
esac
echo ""

echo "[5/8] Asserting priority assignment..."
PRIORITY_LABELS=$(gh issue view $PRIORITY_ISSUE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$PRIORITY_LABELS" | grep -qE "Priority:(Critical|High|Medium|Low)"; then
  pass "Priority label applied to #$PRIORITY_ISSUE (labels: $PRIORITY_LABELS)"
elif [[ "$PRIORITY_BACKEND_CONFIGURED" == "project" || "$PRIORITY_BACKEND_CONFIGURED" == "off" ]]; then
  warn "No Priority:* label on #$PRIORITY_ISSUE — product.priority_backend='$PRIORITY_BACKEND_CONFIGURED' (labels aren't the active backend, can't verify from here)"
else
  fail "No Priority:* label applied to #$PRIORITY_ISSUE after /triage sweep (labels: ${PRIORITY_LABELS:-none})"
fi
echo ""

# =============================================================================
# Part 2 — /merge duplicate close
# =============================================================================
# Created *after* the triage sweep above finishes so the sweep's own
# LLM-driven dedup pass (also enabled by default) never touches these
# fixtures before the deterministic /merge command gets to.
echo "[6/8] Creating duplicate-close fixture issues..."
CANONICAL_BODY=$(cat <<EOF
# Merge smoke test (canonical) — ${TIMESTAMP}

Synthetic issue created by \`smoke-test-product.sh\` to exercise the
deterministic \`/merge\` duplicate-close pipeline. This is the canonical
issue that a duplicate will be folded into.
EOF
)
CANONICAL_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [merge canonical] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$CANONICAL_BODY")
CANONICAL=$(echo "$CANONICAL_URL" | grep -oE '[0-9]+$')
echo "  Canonical issue: #$CANONICAL → $CANONICAL_URL"

DUPLICATE_BODY=$(cat <<EOF
# Merge smoke test (duplicate) — ${TIMESTAMP}

Synthetic issue created by \`smoke-test-product.sh\` — a deliberate
duplicate of #${CANONICAL}, closed via \`/merge #${CANONICAL}\` to exercise
the deterministic merge pipeline end-to-end.
EOF
)
DUPLICATE_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [merge duplicate] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$DUPLICATE_BODY")
DUPLICATE=$(echo "$DUPLICATE_URL" | grep -oE '[0-9]+$')
echo "  Duplicate issue: #$DUPLICATE → $DUPLICATE_URL"
echo ""

echo "[7/8] Triggering /merge #$CANONICAL on #$DUPLICATE..."
MERGE_COMMENT_URL=$(gh issue comment $DUPLICATE $REPO_ARG --body "/merge #${CANONICAL}")
MERGE_COMMENT_ID=$(echo "$MERGE_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Merge comment posted (id: ${MERGE_COMMENT_ID:-unknown})"

if [[ -z "${MERGE_COMMENT_ID:-}" ]]; then
  fail "cannot track merge run — missing MERGE_COMMENT_ID"
  exit 1
fi
MERGE_RC=0
wait_for_reaction "$MERGE_COMMENT_ID" 120 "product-agent (merge)" || MERGE_RC=$?
case $MERGE_RC in
  0) pass "merge run completed successfully" ;;
  1) fail "merge run failed (😕 reaction on /merge comment)"; exit 1 ;;
  2) fail "merge run did not complete within 2 min"; exit 1 ;;
esac
echo ""

echo "[8/8] Asserting duplicate-close state..."

DUP_STATE=$(gh issue view $DUPLICATE $REPO_ARG --json state --jq '.state')
if [[ "$DUP_STATE" == "CLOSED" ]]; then
  pass "Duplicate issue #$DUPLICATE is closed"
else
  fail "Duplicate issue #$DUPLICATE state=$DUP_STATE (expected CLOSED)"
fi

DUP_LABELS=$(gh issue view $DUPLICATE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$DUP_LABELS" | grep -q "Duplicate"; then
  pass "Label 'Duplicate' applied to #$DUPLICATE"
else
  fail "Label 'Duplicate' missing on #$DUPLICATE (labels: ${DUP_LABELS:-none})"
fi

DUP_COMMENTS=$(gh api "repos/$REPO/issues/$DUPLICATE/comments" --jq '[.[].body]' 2>/dev/null || echo "[]")
if echo "$DUP_COMMENTS" | jq -e --arg c "$CANONICAL" 'any(.[]; contains("Duplicate of #" + $c))' >/dev/null 2>&1; then
  pass "#$DUPLICATE has a close comment cross-referencing #$CANONICAL"
else
  fail "#$DUPLICATE is missing a close comment cross-referencing #$CANONICAL"
fi

CANONICAL_COMMENTS=$(gh api "repos/$REPO/issues/$CANONICAL/comments" --jq '[.[].body]' 2>/dev/null || echo "[]")
if echo "$CANONICAL_COMMENTS" | jq -e --arg d "$DUPLICATE" 'any(.[]; contains("Folding in #" + $d))' >/dev/null 2>&1; then
  pass "#$CANONICAL has a fold-in cross-reference comment for #$DUPLICATE"
else
  fail "#$CANONICAL is missing a fold-in cross-reference comment for #$DUPLICATE"
fi

# Sub-issue link — soft assertion (requires sub-issues API enabled). merge.sh
# links these best-effort (`|| true`), so a miss here is never fatal.
PROBE_STATUS=$(gh api "repos/$REPO/issues/$DUPLICATE/sub_issues" \
               --include 2>/dev/null | awk 'NR==1 { print $2 }' || echo "")
if [[ "$PROBE_STATUS" =~ ^2 ]]; then
  LINKED=$(gh api "repos/$REPO/issues/$DUPLICATE/sub_issues" --jq '[.[].number]' 2>/dev/null || echo "[]")
  if echo "$LINKED" | jq -e --argjson c "$CANONICAL" 'index($c) != null' >/dev/null 2>&1; then
    pass "#$CANONICAL linked as a sub-issue of #$DUPLICATE"
  else
    warn "#$CANONICAL not linked as a sub-issue of #$DUPLICATE (best-effort link, not fatal)"
  fi
else
  warn "Sub-issues API not available on this repository (HTTP ${PROBE_STATUS:-none}); skipping sub-issue assertion"
fi
echo ""

# --- Cleanup (unless --keep) ---
if [[ "$KEEP" == true ]]; then
  echo "Skipping cleanup (--keep)."
else
  echo "Cleaning up fixture issues..."
  gh issue close $PRIORITY_ISSUE $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  gh issue close $CANONICAL $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  # $DUPLICATE is already closed by /merge.
  echo "Cleanup complete."
fi
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Fail:    $FAIL"
echo "  Warn:    $WARN"

if [[ $FAIL -eq 0 ]]; then
  if [[ $WARN -eq 0 ]]; then
    echo "✅ Product-agent smoke test passed with no warnings."
  else
    echo "✅ Product-agent smoke test passed with $WARN soft warning(s)."
  fi
  exit 0
else
  echo "❌ Product-agent smoke test FAILED — $FAIL hard assertion(s) violated."
  exit 1
fi
