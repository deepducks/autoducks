#!/usr/bin/env bash
# Unit tests for .autoducks/agents/update/run.sh — the pure-orchestration
# updater (resolve target → decide → pre-flight → apply → migrate → drift →
# verify → deliver → report). No LLM step runs.
#
# Individual update::* functions are sourced (not run as the whole agent) via
# the same `bash -c 'source "$1"; fn args' _ "$SCRIPT"` technique as
# test/check-run.sh, run against a scratch AUTODUCKS_ROOT (symlinked
# core/providers/agents, custom autoducks.json — same technique as
# test/unit-update-config.sh) with `gh` shimmed on PATH per scenario, so
# every git::/its:: call and every direct `gh`/tag lookup stays offline.
# Run: bash test/unit-update-run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/.autoducks/agents/update/run.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT
ln -s "$REPO_ROOT/.autoducks/agents" "$SCRATCH_ROOT/agents"
ln -s "$REPO_ROOT/.autoducks/core" "$SCRATCH_ROOT/core"
ln -s "$REPO_ROOT/.autoducks/providers" "$SCRATCH_ROOT/providers"
ln -s "$REPO_ROOT/.autoducks/security-guidelines.md" "$SCRATCH_ROOT/security-guidelines.md"
cat > "$SCRATCH_ROOT/autoducks.json" <<'JSON'
{
  "providers": {"its": "github", "git": "github", "llm": "claude"},
  "defaults": {"model": "m", "effort": "high", "base_branch": "main", "merge_method": "auto"},
  "update": {"source_repo": "acme/upstream"}
}
JSON

# mk_gh DIR — writes a `gh` shim on $DIR/bin that dispatches canned
# responses for the handful of read-only calls run.sh's Step-0/2 functions
# make (tags/commits/default-branch/pr-list/pr-diff), and logs every
# invocation to $DIR/gh.log so tests can assert nothing else was called.
mk_gh() {
  local dir="$1"; mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$*" in
  "api repos/acme/upstream --jq .default_branch")
    echo "${MOCK_DEFAULT_BRANCH:-main}" ;;
  # The *consumer's* default branch — the update's delivery target, distinct
  # from the source repo's above. MOCK_CONSUMER_DEFAULT_BRANCH= (empty) drives
  # the unreachable-host fallback.
  "api repos/acme/consumer --jq .default_branch")
    echo "${MOCK_CONSUMER_DEFAULT_BRANCH-main}" ;;
  "api repos/acme/upstream/tags --paginate --jq .[].name")
    cat "${MOCK_TAGS_FILE:-/dev/null}" 2>/dev/null || true ;;
  api\ repos/acme/upstream/commits/*)
    echo "${MOCK_COMMIT_SHA:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}" ;;
  "pr list --repo acme/consumer --state open --json number,title,headRefName,body,mergeable,mergeStateStatus --limit 100 --base main")
    cat "${MOCK_OPEN_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
  pr\ diff\ *)
    cat "${MOCK_PR_DIFF_FILE:-/dev/null}" 2>/dev/null || true ;;
  *) echo "[]" ;;
esac
GH
  chmod +x "$dir/bin/gh"
}

# src FUNCTION_CALL... — runs one or more update::* calls in a subshell with
# the real run.sh sourced (functions only; the BASH_SOURCE guard keeps
# update::main from firing), scratch AUTODUCKS_ROOT, and the scenario's gh
# shim first on PATH.
src() {
  env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
    GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
    MOCK_DEFAULT_BRANCH="${MOCK_DEFAULT_BRANCH:-}" MOCK_TAGS_FILE="${MOCK_TAGS_FILE:-}" \
    MOCK_COMMIT_SHA="${MOCK_COMMIT_SHA:-}" MOCK_OPEN_PRS_FILE="${MOCK_OPEN_PRS_FILE:-}" \
    MOCK_PR_DIFF_FILE="${MOCK_PR_DIFF_FILE:-}" \
    MOCK_CONSUMER_DEFAULT_BRANCH="${MOCK_CONSUMER_DEFAULT_BRANCH-main}" \
    bash -c 'source "$1"; shift; "$@"' _ "$RUN_SH" "$@"
}

# =============================================================================
echo "── Step 0: target resolution ──"
D="$SCRATCH_ROOT/d0"; mk_gh "$D"; : > "$D/gh.log"

OUT="$(src update::resolve_target "v1.2.3" "stable")"
[[ "$OUT" == "v1.2.3" ]] && pass "pin non-null → REF=pin (no gh call needed)" || fail "expected v1.2.3, got '$OUT'"

MOCK_DEFAULT_BRANCH="edge-main"
OUT="$(src update::resolve_target "" "edge")"
[[ "$OUT" == "edge-main" ]] && pass "channel=edge → REF=default branch" || fail "expected edge-main, got '$OUT'"
unset MOCK_DEFAULT_BRANCH

MOCK_TAGS_FILE="$D/tags.json"
printf 'v1.0.0\nv1.2.0\nv1.10.0\nv1.9.0\nnot-a-tag\n' > "$MOCK_TAGS_FILE"
OUT="$(src update::resolve_target "" "stable")"
[[ "$OUT" == "v1.10.0" ]] && pass "channel=stable → highest tag, semver-sorted (v1.10.0 beats v1.9.0 and v1.2.0)" || fail "expected v1.10.0, got '$OUT'"
unset MOCK_TAGS_FILE

MOCK_TAGS_FILE="$D/empty-tags.json"; : > "$MOCK_TAGS_FILE"
MOCK_DEFAULT_BRANCH="main"
OUT="$(src update::resolve_target "" "stable" 2>"$D/stderr.log")"
[[ "$OUT" == "main" ]] && pass "no tags exist → REF=default branch" || fail "expected main, got '$OUT'"
grep -q "::warning::" "$D/stderr.log" && pass "no tags → loud bootstrap warning emitted" || fail "no ::warning:: emitted: $(cat "$D/stderr.log")"
unset MOCK_TAGS_FILE MOCK_DEFAULT_BRANCH

# =============================================================================
echo ""
echo "── Step 1: decide (up-to-date / downgrade / proceed) ──"
D="$SCRATCH_ROOT/d1"; mk_gh "$D"

OUT="$(src update::decide "deadbeef" "1.2.0" "deadbeef" "1.2.0" "")"
[[ "$OUT" == "up-to-date" ]] && pass "same SHA → up-to-date" || fail "expected up-to-date, got '$OUT'"

OUT="$(src update::decide "" "" "cafef00d" "1.2.0" "")"
[[ "$OUT" == "proceed" ]] && pass "no lockfile (unversioned pre-lockfile install) → proceed" || fail "expected proceed, got '$OUT'"

OUT="$(src update::decide "aaa111" "2.0.0" "bbb222" "1.9.0" "")"
[[ "$OUT" == "downgrade" ]] && pass "target older than installed, no pin → downgrade (refused)" || fail "expected downgrade, got '$OUT'"

OUT="$(src update::decide "aaa111" "2.0.0" "bbb222" "1.9.0" "v1.9.0")"
[[ "$OUT" == "proceed" ]] && pass "target older than installed, pin set → proceed (rollback path)" || fail "expected proceed, got '$OUT'"

OUT="$(src update::decide "aaa111" "1.2.0" "bbb222" "1.3.0" "")"
[[ "$OUT" == "proceed" ]] && pass "target newer than installed → proceed" || fail "expected proceed, got '$OUT'"

# =============================================================================
echo ""
echo "── Step 2: pre-flight aborts ──"
D="$SCRATCH_ROOT/d2"; mk_gh "$D"

OUT="$(src update::preflight "off" "true" "schedule")"
[[ "$OUT" == "mode-off"$'\t'* ]] && pass "mode=off → mode-off" || fail "expected mode-off, got '$OUT'"

OUT="$(src update::preflight "pr" "false" "schedule")"
[[ "$OUT" == "mode-off"$'\t'* ]] && pass "enabled=false + trigger=schedule → mode-off" || fail "expected mode-off, got '$OUT'"

OUT="$(src update::preflight "pr" "false" "issue_comment")"
[[ "$OUT" != "mode-off"$'\t'* ]] && pass "enabled=false + trigger=issue_comment → NOT mode-off (manual override honored)" || fail "unexpectedly mode-off: '$OUT'"

MOCK_OPEN_PRS_FILE="$D/existing-pr.json"
jq -n '[{number: 55, headRefName: "autoducks/update-v1.2.0"}]' > "$MOCK_OPEN_PRS_FILE"
OUT="$(src update::preflight "pr" "true" "schedule")"
[[ "$OUT" == "existing-pr"$'\t'"55" ]] && pass "open autoducks/update-* PR → existing-pr with its number" || fail "expected existing-pr\\t55, got '$OUT'"
unset MOCK_OPEN_PRS_FILE

MOCK_OPEN_PRS_FILE="$D/pipeline-prs.json"
jq -n '[{number: 77, headRefName: "feature/9-thing"}]' > "$MOCK_OPEN_PRS_FILE"
MOCK_PR_DIFF_FILE="$D/diff.txt"
printf 'diff --git a/.autoducks/core/foo.sh b/.autoducks/core/foo.sh\n+++ b/.autoducks/core/foo.sh\n' > "$MOCK_PR_DIFF_FILE"
OUT="$(src update::preflight "pr" "true" "schedule")"
[[ "$OUT" == "pipeline-conflict"$'\t'* ]] && pass "open pipeline PR touching .autoducks/ → pipeline-conflict" || fail "expected pipeline-conflict, got '$OUT'"
[[ "$OUT" == *"#77"* ]] && pass "pipeline-conflict reason names the PR" || fail "reason missing PR number: '$OUT'"
unset MOCK_OPEN_PRS_FILE MOCK_PR_DIFF_FILE

MOCK_OPEN_PRS_FILE="$D/pipeline-prs-clean.json"
jq -n '[{number: 78, headRefName: "feature/9-thing"}]' > "$MOCK_OPEN_PRS_FILE"
MOCK_PR_DIFF_FILE="$D/diff-clean.txt"
printf 'diff --git a/src/app.js b/src/app.js\n+++ b/src/app.js\n' > "$MOCK_PR_DIFF_FILE"
OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" MOCK_PR_DIFF_FILE="$MOCK_PR_DIFF_FILE" \
  bash -c 'source "$1"; update::preflight "pr" "true" "schedule"' _ "$RUN_SH")"
[[ "$OUT" == "no-identity"$'\t'* ]] && pass "no pipeline conflict + no AUTODUCKS_APP_TOKEN/AUTODUCKS_PAT → no-identity" || fail "expected no-identity, got '$OUT'"
[[ "$OUT" == *"AUTODUCKS_PAT"* ]] && pass "no-identity reason names the remedy (AUTODUCKS_PAT)" || fail "reason missing remedy: '$OUT'"

OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" MOCK_PR_DIFF_FILE="$MOCK_PR_DIFF_FILE" \
  AUTODUCKS_PAT="pat-xxx" \
  bash -c 'source "$1"; update::preflight "pr" "true" "schedule"' _ "$RUN_SH")"
[[ "$OUT" == "ok"$'\t'* ]] && pass "AUTODUCKS_PAT present, no conflicts → ok" || fail "expected ok, got '$OUT'"

OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  MOCK_OPEN_PRS_FILE="$MOCK_OPEN_PRS_FILE" MOCK_PR_DIFF_FILE="$MOCK_PR_DIFF_FILE" \
  AUTODUCKS_APP_TOKEN="ghs-app-yyy" \
  bash -c 'source "$1"; update::preflight "pr" "true" "schedule"' _ "$RUN_SH")"
[[ "$OUT" == "ok"$'\t'* ]] && pass "AUTODUCKS_APP_TOKEN (broker-minted) present, no conflicts → ok" || fail "expected ok, got '$OUT'"

# =============================================================================
echo ""
echo "── Delivery target: the default branch, not base_branch ──"
# The machinery executes from whatever branch the host serves as HEAD — that is
# what `actions/checkout@v4` with no `ref:` gives every lane. Installing it
# anywhere else is a no-op that reports success. deepducks/swanapse cut from
# `master` and was served from `ggondim`, so two consecutive releases landed on
# `master` while every run kept executing the version on `ggondim`.
#
# The scratch config pins base_branch to "main" throughout, so pointing the
# consumer's default branch elsewhere makes the two disagree the same way.
D="$SCRATCH_ROOT/dtarget"; mk_gh "$D"; : > "$D/gh.log"

# UPDATE_TARGET_BRANCH is resolved at source time, not inside a function, so
# these read it straight out of a sourced shell rather than going through src().
OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" MOCK_CONSUMER_DEFAULT_BRANCH="ggondim" \
  bash -c 'source "$1"; printf "%s" "$UPDATE_TARGET_BRANCH"' _ "$RUN_SH")"
if [[ "$OUT" == "ggondim" ]]; then
  pass "delivery target follows the repository default branch, not base_branch"
else
  fail "expected ggondim (default branch), got '$OUT' — base_branch is 'main' in this fixture"
fi

# Same shape, branches in agreement: the overwhelmingly common case must be
# unchanged by this.
OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" MOCK_CONSUMER_DEFAULT_BRANCH="main" \
  bash -c 'source "$1"; printf "%s" "$UPDATE_TARGET_BRANCH"' _ "$RUN_SH")"
[[ "$OUT" == "main" ]] && pass "default branch == base_branch → target unchanged" || fail "expected main, got '$OUT'"

# Unreachable host: keep the old behaviour rather than abort a cycle over a
# transient API failure, but say so.
OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" \
  GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" MOCK_CONSUMER_DEFAULT_BRANCH="" \
  bash -c 'source "$1"; printf "%s" "$UPDATE_TARGET_BRANCH"' _ "$RUN_SH" 2>"$D/warn.log")"
[[ "$OUT" == "main" ]] && pass "unresolvable default branch → falls back to base_branch" || fail "expected main fallback, got '$OUT'"
grep -q "::warning::" "$D/warn.log" && pass "the fallback warns instead of failing silently" || fail "no ::warning:: on fallback: $(cat "$D/warn.log")"
unset MOCK_CONSUMER_DEFAULT_BRANCH

# =============================================================================
echo ""
echo "── Step 4: migration ordering + abort-on-failure ──"
D="$SCRATCH_ROOT/d4"; mk_gh "$D"
MIG_ROOT="$D/migroot"
mkdir -p "$MIG_ROOT/migrations/0.1.0" "$MIG_ROOT/migrations/0.2.0" "$MIG_ROOT/migrations/0.3.0" "$MIG_ROOT/migrations/1.0.0"
for v in 0.1.0 0.2.0 0.3.0 1.0.0; do
  cat > "$MIG_ROOT/migrations/$v/migrate.sh" <<EOF
#!/usr/bin/env bash
echo "$v" >> "\$AUTODUCKS_MIGRATION_ORDER_LOG"
exit 0
EOF
  chmod +x "$MIG_ROOT/migrations/$v/migrate.sh"
done

ORDER_LOG="$D/order.log"; : > "$ORDER_LOG"
OUT="$(env AUTODUCKS_MIGRATION_ORDER_LOG="$ORDER_LOG" \
  PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  bash -c 'source "$1"; update::pending_migrations "0.1.0" "0.3.0" "$2"' _ "$RUN_SH" "$MIG_ROOT/migrations")"
EXPECTED=$'0.2.0\n0.3.0'
[[ "$OUT" == "$EXPECTED" ]] && pass "pending_migrations: (0.1.0, 0.3.0] → 0.2.0, 0.3.0 in ascending order (1.0.0 excluded)" || fail "expected '0.2.0 0.3.0', got '$OUT'"

REPORT="$D/report.md"; : > "$REPORT"
env AUTODUCKS_MIGRATION_ORDER_LOG="$ORDER_LOG" \
  PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  bash -c 'source "$1"; update::run_migrations "" "0.3.0" "$2" "$3"' _ "$RUN_SH" "$MIG_ROOT/migrations" "$REPORT"
[[ "$(cat "$ORDER_LOG")" == $'0.1.0\n0.2.0\n0.3.0' ]] && pass "run_migrations (no installed version): runs every migration up to target, ascending" || fail "wrong run order: $(cat "$ORDER_LOG")"

# Failure case: 0.2.0 exits non-zero, must abort before reaching 0.3.0.
mkdir -p "$MIG_ROOT/migrations/0.2.0-fail"
cat > "$MIG_ROOT/migrations/0.2.0/migrate.sh" <<'EOF'
#!/usr/bin/env bash
echo "0.2.0" >> "$AUTODUCKS_MIGRATION_ORDER_LOG"
exit 1
EOF
chmod +x "$MIG_ROOT/migrations/0.2.0/migrate.sh"
: > "$ORDER_LOG"; : > "$REPORT"
RC=0
env AUTODUCKS_MIGRATION_ORDER_LOG="$ORDER_LOG" \
  PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  bash -c 'source "$1"; update::run_migrations "0.1.0" "1.0.0" "$2" "$3"' _ "$RUN_SH" "$MIG_ROOT/migrations" "$REPORT" || RC=$?
[[ "$RC" -ne 0 ]] && pass "run_migrations returns non-zero when a migration fails" || fail "expected non-zero exit"
[[ "$(cat "$ORDER_LOG")" == "0.2.0" ]] && pass "abort before 0.3.0/1.0.0 run (only 0.2.0 executed)" || fail "later migrations ran after failure: $(cat "$ORDER_LOG")"
grep -qi "0.2.0" "$REPORT" && pass "report names the failing migration" || fail "report doesn't name failing version: $(cat "$REPORT")"

# =============================================================================
echo ""
echo "── Step 5: drift detection with/without consumer-owned exclusions ──"
D="$SCRATCH_ROOT/d5"; mk_gh "$D"
PRE="$D/pre/.autoducks"
SNAP="$D/snap"
mkdir -p "$PRE/core" "$PRE/providers/llm/claude/compiled" "$SNAP/core" "$SNAP/providers/llm/claude/compiled"
echo "autoducks.json content A" > "$PRE/autoducks.json"
echo "autoducks.json content B" > "$SNAP/autoducks.json"
echo "machinery A" > "$PRE/core/foo.sh"
echo "machinery B (drifted)" > "$SNAP/core/foo.sh"
echo "compiled A" > "$PRE/providers/llm/claude/compiled/x.json"
echo "compiled B" > "$SNAP/providers/llm/claude/compiled/x.json"
echo '{"sha":"aaa"}' > "$PRE/.installed.json"
echo '{"sha":"bbb"}' > "$SNAP/.installed.json"

OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  bash -c 'source "$1"; update::drift_diff "$2" "$3"' _ "$RUN_SH" "$PRE" "$SNAP")"
[[ "$OUT" == "core/foo.sh" ]] && pass "drift_diff: only genuine machinery diff (core/foo.sh) reported" || fail "expected only core/foo.sh, got: '$OUT'"
[[ "$OUT" != *"autoducks.json"* ]] && pass "autoducks.json (consumer-owned) excluded from drift" || fail "consumer-owned autoducks.json leaked into drift: '$OUT'"
[[ "$OUT" != *"compiled"* ]] && pass "providers/llm/claude/compiled/ (generated) excluded from drift" || fail "generated compiled/ leaked into drift: '$OUT'"
[[ "$OUT" != *".installed.json"* ]] && pass ".installed.json (generated) excluded from drift" || fail ".installed.json leaked into drift: '$OUT'"

echo "machinery A" > "$SNAP/core/foo.sh"
OUT="$(env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
  bash -c 'source "$1"; update::drift_diff "$2" "$3"' _ "$RUN_SH" "$PRE" "$SNAP")"
[[ -z "$OUT" ]] && pass "no genuine machinery diff → drift_diff reports nothing" || fail "expected empty, got: '$OUT'"

# =============================================================================
echo ""
echo "── Step 7: auto-merge eligibility matrix ──"
D="$SCRATCH_ROOT/d7"; mk_gh "$D"
# The signature dropped its CHECKS_OK argument: a verify-machinery failure
# discards the branch and exits, so the value was provably 1 at the only call
# site. Machinery verification is Step 6's job; the consumer's own required
# checks are GitHub's, held by auto-merge.
check_auto_merge() { # label cfg bump breaking drift expect(0=eligible,1=not)
  local label="$1" cfg="$2" bump="$3" breaking="$4" drift="$5" expect="$6"
  local rc=0
  env PATH="$D/bin:$PATH" AUTODUCKS_ROOT="$SCRATCH_ROOT" REPO="acme/consumer" GITHUB_ACTIONS=true GH_TOKEN=t GH_LOG="$D/gh.log" \
    bash -c 'source "$1"; update::auto_merge_eligible "$2" "$3" "$4" "$5"' _ "$RUN_SH" "$cfg" "$bump" "$breaking" "$drift" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then pass "$label"; else fail "$label (rc=$rc, expected $expect)"; fi
}

check_auto_merge "off: never eligible even for a clean patch" "off" "patch" "0" "0" 1
check_auto_merge "patch cfg + patch bump, clean → eligible" "patch" "patch" "0" "0" 0
check_auto_merge "patch cfg + minor bump → not eligible" "patch" "minor" "0" "0" 1
check_auto_merge "minor cfg + patch bump, clean → eligible" "minor" "patch" "0" "0" 0
check_auto_merge "minor cfg + minor bump, clean → eligible" "minor" "minor" "0" "0" 0
check_auto_merge "minor cfg + major bump → NEVER eligible" "minor" "major" "0" "0" 1
check_auto_merge "minor cfg + minor bump but breaking notes → not eligible" "minor" "minor" "1" "0" 1
check_auto_merge "minor cfg + minor bump but drift present → not eligible" "minor" "minor" "0" "1" 1
check_auto_merge "major cfg is not a valid setting → never eligible" "major" "patch" "0" "0" 1
check_auto_merge "unknown cfg value → never eligible" "banana" "patch" "0" "0" 1

echo ""
echo "═══ update-run: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
