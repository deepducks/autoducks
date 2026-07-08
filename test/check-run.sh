#!/usr/bin/env bash
# Unit tests for .autoducks/providers/git/github/check-run.sh
# Run: bash test/check-run.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_RUN_SH="$REPO_ROOT/.autoducks/providers/git/github/check-run.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Capturing `gh` stub: records argv + stdin body, returns a check-run resource
# as JSON (the real Checks API response shape). CAP points at the capture dir.
mk_gh() {
  local dir="$1"; mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP/args.log"
cat > "$CAP/body.json"
echo '{"id":999}'
GH
  chmod +x "$dir/bin/gh"
}

# Failing `gh` stub: emulates the Checks-API PAT rejection — prints the 403
# error body to stdout and exits non-zero, like the real `gh api` does.
mk_gh_403() {
  local dir="$1"; mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP/args.log"
cat > "$CAP/body.json"
echo '{"message":"You must authenticate via a GitHub App.","status":"403"}'
exit 1
GH
  chmod +x "$dir/bin/gh"
}

# ---------------------------------------------------------------------------
echo "[a] start_check_run posts an in-progress payload and returns the id"
D="$SCRATCH/a"; mk_gh "$D"
OUT=$(env -i PATH="$D/bin:$PATH" REPO="acme/repo" CAP="$D" \
  bash -c 'source "$1"; git::start_check_run "Autoducks: Reviewer" "deadbeef"' _ "$CHECK_RUN_SH")
BODY="$(cat "$D/body.json")"
[[ "$OUT" == "999" ]] && pass "returns the check-run id" || fail "expected 999, got '$OUT'"
echo "$BODY" | jq -e '.status == "in_progress"' >/dev/null && pass "status=in_progress" || fail "status not in_progress: $BODY"
echo "$BODY" | jq -e '.name == "Autoducks: Reviewer"' >/dev/null && pass "name propagated" || fail "name missing: $BODY"
echo "$BODY" | jq -e '.head_sha == "deadbeef"' >/dev/null && pass "head_sha propagated" || fail "head_sha missing: $BODY"
grep -q 'check-runs --method POST' "$D/args.log" && pass "POST to check-runs" || fail "wrong endpoint/method: $(cat "$D/args.log")"

# ---------------------------------------------------------------------------
echo "[b] conclude_check_run patches a completed payload"
D="$SCRATCH/b"; mk_gh "$D"
env -i PATH="$D/bin:$PATH" REPO="acme/repo" CAP="$D" \
  bash -c 'source "$1"; git::conclude_check_run 42 failure "Reviewer: request changes" "blocked"' _ "$CHECK_RUN_SH"
BODY="$(cat "$D/body.json")"
echo "$BODY" | jq -e '.status == "completed"' >/dev/null && pass "status=completed" || fail "status not completed: $BODY"
echo "$BODY" | jq -e '.conclusion == "failure"' >/dev/null && pass "conclusion propagated" || fail "conclusion missing: $BODY"
echo "$BODY" | jq -e '.output.title == "Reviewer: request changes"' >/dev/null && pass "output.title propagated" || fail "title missing: $BODY"
echo "$BODY" | jq -e '.output.summary == "blocked"' >/dev/null && pass "output.summary propagated" || fail "summary missing: $BODY"
grep -q 'check-runs/42 --method PATCH' "$D/args.log" && pass "PATCH to check-runs/42" || fail "wrong endpoint/method: $(cat "$D/args.log")"

# ---------------------------------------------------------------------------
echo "[c] start_check_run returns empty + non-zero on API error (no garbage id)"
D="$SCRATCH/c"; mk_gh_403 "$D"
set +e
OUT=$(env -i PATH="$D/bin:$PATH" REPO="acme/repo" CAP="$D" \
  bash -c 'source "$1"; git::start_check_run "Autoducks: Reviewer" "deadbeef"' _ "$CHECK_RUN_SH")
RC=$?
set -e
[[ "$RC" -ne 0 ]] && pass "non-zero exit on error" || fail "expected non-zero, got $RC"
[[ -z "$OUT" ]] && pass "no id echoed on error" || fail "leaked error body as id: '$OUT'"

# ---------------------------------------------------------------------------
echo "[d] check-run calls prefer GITHUB_TOKEN (Checks API is GitHub-App-only)"
D="$SCRATCH/d"; mk_gh "$D"
# gh stub records the token it saw; assert the App token wins over the PAT.
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "${GH_TOKEN:-UNSET}" >> "$CAP/token.log"
cat > /dev/null
echo '{"id":999}'
GH
chmod +x "$D/bin/gh"
env -i PATH="$D/bin:$PATH" REPO="acme/repo" CAP="$D" \
  GH_TOKEN="pat-xxx" GITHUB_TOKEN="ghs-app-yyy" \
  bash -c 'source "$1"; git::start_check_run "Autoducks: Reviewer" "deadbeef" >/dev/null' _ "$CHECK_RUN_SH"
grep -qx 'ghs-app-yyy' "$D/token.log" && pass "used GITHUB_TOKEN over GH_TOKEN" || fail "wrong token: $(cat "$D/token.log")"

# ---------------------------------------------------------------------------
echo ""
echo "=== check-run.sh unit test summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
