#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Product Agent (Classification)
# =============================================================================
#
# PURPOSE
# -------
# Exercises the authoritative `Bug`/`Feature` classification apply path in
# the product agent (pre.sh's `already_classified`/`design_done` hints,
# post.sh's re-verify-then-apply loop via classify-label.sh), gated by the
# `product.provisional_classification` config key:
#
#   1. An unclassified, open, un-designed issue gets the bare `Bug` or
#      `Feature` label applied directly — never a native-type set.
#   2. An issue that already carries an authoritative classification (exact
#      `Bug`/`Feature` label) is skipped and keeps just that one label.
#   3. An issue that already carries `Design:done` is skipped the same way
#      — the Architect owns classification once a design exists.
#   4. Re-running `/triage` is idempotent: the classified fixture keeps
#      exactly one of `Bug`/`Feature`, and it's never flipped to the other.
#
# WARNING — REAL BACKLOG SIDE EFFECTS
# ------------------------------------
# Same caveat as scripts/smoke-test-product.sh: `/triage` always runs a
# **full backlog sweep**, so this run also re-proposes priorities/duplicates
# across your entire open backlog per the existing config. Prefer a
# disposable/staging repo.
#
# COST
# ----
# Two product-agent LLM calls (`sonnet high`) over the full open-issue
# backlog — one per `/triage` trigger (initial + idempotency re-run).
# Expected wall time: 2–10 min depending on backlog size.
#
# USAGE
# -----
#   ./scripts/smoke-test-product-classify.sh [OPTIONS]
#
# OPTIONS
#   --keep          Do not close the fixture issues at the end.
#   --no-wait       Create fixtures and trigger the first /triage, don't
#                   wait for completion or run the idempotency re-check.
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`).
#   -h, --help      Show this help.
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
      sed -n '2,45p' "$0"
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

echo "=== Smoke Test — Product Agent (Classification) ==="
echo "Repo: $REPO"
echo "Timestamp: $TIMESTAMP"
echo ""

FAIL=0
WARN=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

# Identical helper to smoke-test-product.sh: poll a comment's reactions for
# the terminal signal every product-agent workflow posts.
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

trigger_triage() {
  local issue="$1" label="$2"
  local comment_url comment_id rc=0
  comment_url=$(gh issue comment "$issue" $REPO_ARG --body "/triage")
  comment_id=$(echo "$comment_url" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
  if [[ -z "$comment_id" ]]; then
    fail "cannot track product-agent — missing comment id for $label"
    exit 1
  fi
  wait_for_reaction "$comment_id" 600 "$label" || rc=$?
  case $rc in
    0) pass "$label completed successfully" ;;
    1) fail "$label failed (😕 reaction on /triage comment)"; exit 1 ;;
    2) fail "$label did not complete within 10 min"; exit 1 ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONAL_CLASSIFICATION_CONFIGURED=$(jq -r 'if .product.provisional_classification == null then "true" else (.product.provisional_classification | tostring) end' "$SCRIPT_DIR/../.autoducks/autoducks.json" 2>/dev/null || echo "true")

# --- Ensure labels exist ---
echo "[1/6] Ensuring labels exist..."
gh label create "smoke-test"    --color "FFA500" --description "Smoke test" $REPO_ARG 2>/dev/null || true
gh label create "Bug"           --color "D73A4A" --description "Defective behavior in existing functionality" $REPO_ARG 2>/dev/null || true
gh label create "Feature"       --color "A2EEEF" --description "New capability or enhancement" $REPO_ARG 2>/dev/null || true
gh label create "Design:done"   --color "1F6FEB" --description "Design complete" $REPO_ARG 2>/dev/null || true
pass "Labels ensured"
echo ""

# --- Create fixtures ---
echo "[2/6] Creating fixture issues..."

UNCLASSIFIED_BODY=$(cat <<EOF
# Classification smoke test (unclassified) — ${TIMESTAMP}

Synthetic issue created by \`smoke-test-product-classify.sh\` to exercise the
authoritative \`Bug\`/\`Feature\` classification pipeline end-to-end. Users
report that the login form throws an unhandled exception and shows a blank
white screen whenever the password field contains a non-ASCII character —
this used to work correctly and is a clear regression in existing,
previously-working functionality.

This issue carries no classification label or native type yet.
EOF
)
UNCLASSIFIED_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [classify unclassified] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$UNCLASSIFIED_BODY")
UNCLASSIFIED=$(echo "$UNCLASSIFIED_URL" | grep -oE '[0-9]+$')
echo "  Unclassified fixture: #$UNCLASSIFIED → $UNCLASSIFIED_URL"

ALREADY_LABELED_BODY=$(cat <<EOF
# Classification smoke test (already labeled) — ${TIMESTAMP}

Synthetic issue created by \`smoke-test-product-classify.sh\`, pre-labeled
\`Bug\` to verify the classification apply loop skips issues that already
carry an authoritative classification label.
EOF
)
ALREADY_LABELED_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [classify already-labeled] ${TIMESTAMP}" \
  --label "smoke-test,Bug" \
  --body "$ALREADY_LABELED_BODY")
ALREADY_LABELED=$(echo "$ALREADY_LABELED_URL" | grep -oE '[0-9]+$')
echo "  Already-labeled fixture: #$ALREADY_LABELED → $ALREADY_LABELED_URL"

ALREADY_DESIGNED_BODY=$(cat <<EOF
# Classification smoke test (already designed) — ${TIMESTAMP}

Synthetic issue created by \`smoke-test-product-classify.sh\`, pre-labeled
\`Design:done\` to verify the classification apply loop skips issues the
Architect has already designed — classification is the Architect's call
once a design exists.
EOF
)
ALREADY_DESIGNED_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [classify already-designed] ${TIMESTAMP}" \
  --label "smoke-test,Design:done" \
  --body "$ALREADY_DESIGNED_BODY")
ALREADY_DESIGNED=$(echo "$ALREADY_DESIGNED_URL" | grep -oE '[0-9]+$')
echo "  Already-designed fixture: #$ALREADY_DESIGNED → $ALREADY_DESIGNED_URL"
echo ""

# --- Trigger /triage (always a full backlog sweep) ---
echo "[3/6] Triggering /triage on #$UNCLASSIFIED..."
if [[ "$WAIT" == false ]]; then
  gh issue comment "$UNCLASSIFIED" $REPO_ARG --body "/triage" >/dev/null
  echo ""
  echo "Skipping wait (--no-wait). Fixtures: $UNCLASSIFIED_URL $ALREADY_LABELED_URL $ALREADY_DESIGNED_URL"
  exit 0
fi
trigger_triage "$UNCLASSIFIED" "product-agent (classify, initial run)"
echo ""

echo "[4/6] Asserting classification apply..."
UNCLASSIFIED_LABELS=$(gh issue view "$UNCLASSIFIED" $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
ALREADY_LABELED_LABELS=$(gh issue view "$ALREADY_LABELED" $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
ALREADY_DESIGNED_LABELS=$(gh issue view "$ALREADY_DESIGNED" $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')

FIRST_KIND=""
if [[ "$PROVISIONAL_CLASSIFICATION_CONFIGURED" == "true" ]]; then
  if echo "$UNCLASSIFIED_LABELS" | grep -qE '(^|,)(Bug|Feature)(,|$)'; then
    FIRST_KIND=$(echo "$UNCLASSIFIED_LABELS" | tr ',' '\n' | grep -xE 'Bug|Feature' | head -1)
    pass "Bug/Feature label applied to #$UNCLASSIFIED (labels: $UNCLASSIFIED_LABELS)"
  else
    fail "No Bug/Feature label applied to #$UNCLASSIFIED after /triage (labels: ${UNCLASSIFIED_LABELS:-none})"
  fi
else
  if echo "$UNCLASSIFIED_LABELS" | grep -qE '(^|,)(Bug|Feature)(,|$)'; then
    fail "Bug/Feature label applied to #$UNCLASSIFIED despite product.provisional_classification=false (labels: $UNCLASSIFIED_LABELS)"
  else
    pass "No Bug/Feature label applied to #$UNCLASSIFIED — product.provisional_classification is false"
  fi
fi

if echo "$ALREADY_LABELED_LABELS" | grep -qx 'Bug' && ! echo "$ALREADY_LABELED_LABELS" | grep -qE '(^|,)Feature(,|$)'; then
  pass "#$ALREADY_LABELED (already classified) was skipped — still carries only Bug"
else
  fail "#$ALREADY_LABELED (already carries Bug label) label set changed unexpectedly (labels: $ALREADY_LABELED_LABELS)"
fi

if echo "$ALREADY_DESIGNED_LABELS" | grep -qE '(^|,)(Bug|Feature)(,|$)'; then
  fail "#$ALREADY_DESIGNED (already Design:done) unexpectedly got a Bug/Feature label (labels: $ALREADY_DESIGNED_LABELS)"
else
  pass "#$ALREADY_DESIGNED (already designed) was skipped — no Bug/Feature label"
fi
echo ""

# --- Idempotency: re-run /triage and confirm the label set doesn't change ---
echo "[5/6] Re-triggering /triage on #$UNCLASSIFIED to check idempotency..."
trigger_triage "$UNCLASSIFIED" "product-agent (classify, idempotency re-run)"

REPEAT_LABELS=$(gh issue view "$UNCLASSIFIED" $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if [[ "$PROVISIONAL_CLASSIFICATION_CONFIGURED" == "true" ]]; then
  CLASSIFICATION_COUNT=$(echo "$REPEAT_LABELS" | tr ',' '\n' | grep -cxE 'Bug|Feature' || true)
  REPEAT_KIND=$(echo "$REPEAT_LABELS" | tr ',' '\n' | grep -xE 'Bug|Feature' | head -1)
  if [[ "$CLASSIFICATION_COUNT" -eq 1 && "$REPEAT_KIND" == "$FIRST_KIND" ]]; then
    pass "Re-running /triage is idempotent — #$UNCLASSIFIED still carries exactly one \`$REPEAT_KIND\` label"
  else
    fail "Re-running /triage changed #$UNCLASSIFIED's classification (was: \`$FIRST_KIND\`, now: $CLASSIFICATION_COUNT label(s) — $REPEAT_LABELS)"
  fi
else
  if echo "$REPEAT_LABELS" | grep -qE '(^|,)(Bug|Feature)(,|$)'; then
    fail "Bug/Feature label appeared on #$UNCLASSIFIED after re-run despite product.provisional_classification=false"
  else
    pass "#$UNCLASSIFIED still carries no Bug/Feature label after re-run — config gate holds"
  fi
fi
echo ""

# --- Cleanup (unless --keep) ---
echo "[6/6] Cleanup..."
if [[ "$KEEP" == true ]]; then
  echo "Skipping cleanup (--keep)."
else
  gh issue close "$UNCLASSIFIED" $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  gh issue close "$ALREADY_LABELED" $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  gh issue close "$ALREADY_DESIGNED" $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  echo "Cleanup complete."
fi
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Fail:    $FAIL"
echo "  Warn:    $WARN"

if [[ $FAIL -eq 0 ]]; then
  if [[ $WARN -eq 0 ]]; then
    echo "✅ Product-agent classification smoke test passed with no warnings."
  else
    echo "✅ Product-agent classification smoke test passed with $WARN soft warning(s)."
  fi
  exit 0
else
  echo "❌ Product-agent classification smoke test FAILED — $FAIL hard assertion(s) violated."
  exit 1
fi
