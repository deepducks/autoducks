#!/usr/bin/env bash
# Unit tests for .autoducks/core/security/authorize.sh
# Run: bash test/authorize.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHZ_SH="$REPO_ROOT/.autoducks/core/security/authorize.sh"
REAL_AUTODUCKS="$REPO_ROOT/.autoducks"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── Fixture: a self-contained AUTODUCKS_ROOT that mocks the ITS provider
# so we can inspect react/comment side effects without a real GitHub API.
build_fixture_root() {
  local root="$1"
  mkdir -p "$root/core/security"
  mkdir -p "$root/providers/its"
  mkdir -p "$root/providers/its/mock"

  # Link the real security module (so file paths inside authorize.sh
  # still resolve via SCRIPT_DIR).
  ln -sf "$REAL_AUTODUCKS/core/security/authorize.sh"        "$root/core/security/authorize.sh"
  ln -sf "$REAL_AUTODUCKS/core/security/parse-codeowners.sh" "$root/core/security/parse-codeowners.sh"
  ln -sf "$REAL_AUTODUCKS/core/security/resolve-team.sh"     "$root/core/security/resolve-team.sh"
  ln -sf "$REAL_AUTODUCKS/core/security/denial-message.md"   "$root/core/security/denial-message.md"

  # Link the real ITS interface (which sources $AUTODUCKS_ITS_PROVIDER/*.sh)
  ln -sf "$REAL_AUTODUCKS/providers/its/interface.sh" "$root/providers/its/interface.sh"

  # Mock ITS provider — stubs the required functions and records the
  # ones the authorization gate exercises.
  cat > "$root/providers/its/mock/mock.sh" <<'MOCK'
its::get_issue()               { :; }
its::create_issue()            { :; }
its::close_issue()             { :; }
its::update_issue_body()       { :; }
its::comment_issue()           { printf 'COMMENT:%s|%s\n' "$1" "$2" >> "${AUTHZ_TEST_LOG:-/dev/null}"; }
its::react_to_comment()        { printf 'REACT:%s|%s\n' "$1" "$2" >> "${AUTHZ_TEST_LOG:-/dev/null}"; }
its::add_label()               { :; }
its::remove_label()            { :; }
its::set_issue_type()          { :; }
its::link_sub_issue()          { :; }
its::sub_issues_available()    { :; }
its::list_comments()           { :; }
its::list_sub_issues()         { :; }
its::get_issue_edit_history()  { :; }
its::delete_comment()          { :; }
its::update_comment()          { printf 'UPDATE:%s|%s\n' "$1" "$2" >> "${AUTHZ_TEST_LOG:-/dev/null}"; }
its::assign_issue()            { :; }
MOCK
}

# Fixed AUTODUCKS_ROOT used by all tests.
AUTZ_ROOT="$SCRATCH/autoducks"
build_fixture_root "$AUTZ_ROOT"

# Per-test scratch (config, repo working tree, logs).
new_test_dir() {
  local d="$SCRATCH/test-$1"
  mkdir -p "$d/repo/.github"
  echo "$d"
}

# Write a config.
write_config() {
  local dir="$1"
  local security_json="${2:-null}"
  if [[ "$security_json" == "null" ]]; then
    cat > "$AUTZ_ROOT/autoducks.json" <<JSON
{
  "providers": { "its": "mock", "git": "github", "llm": "claude" },
  "defaults":  { "model": "test", "effort": "low", "base_branch": "main" }
}
JSON
  else
    cat > "$AUTZ_ROOT/autoducks.json" <<JSON
{
  "providers": { "its": "mock", "git": "github", "llm": "claude" },
  "defaults":  { "model": "test", "effort": "low", "base_branch": "main" },
  "security":  $security_json
}
JSON
  fi
}

# Run authorize.sh with a scoped env. Records:
#   $LAST_EXIT      — exit code
#   $LAST_LOG       — path to the its:: side-effect log
#   $LAST_SUMMARY   — path to the fake $GITHUB_STEP_SUMMARY
run_authz() {
  local dir="$1"; shift
  LAST_LOG="$dir/log.txt"
  LAST_SUMMARY="$dir/summary.md"
  : > "$LAST_LOG"
  : > "$LAST_SUMMARY"

  # Point the run at our fixture root & fake repo working tree.
  env -i HOME="$HOME" PATH="$dir/bin:$PATH" \
      AUTODUCKS_ROOT="$AUTZ_ROOT" \
      AUTODUCKS_REPO_ROOT="$dir/repo" \
      AUTHZ_TEST_LOG="$LAST_LOG" \
      GITHUB_STEP_SUMMARY="$LAST_SUMMARY" \
      RUNNER_TEMP="$dir/tmp" \
      "$@" \
      bash "$AUTHZ_SH"
  LAST_EXIT=$?
}

# ---------------------------------------------------------------------------
# Test 1: Default trusted associations
# ---------------------------------------------------------------------------
echo "[1] Default trusted associations (OWNER/MEMBER/COLLABORATOR → 0)"
for assoc in OWNER MEMBER COLLABORATOR; do
  D=$(new_test_dir "t1-$assoc")
  write_config "$D" null
  run_authz "$D" \
    AUTODUCKS_AGENT=design \
    ACTOR=alice \
    AUTHOR_ASSOC="$assoc" \
    EVENT_NAME=issue_comment \
    REPO=x/y GH_TOKEN=t
  if [[ "$LAST_EXIT" -eq 0 ]]; then
    pass "AUTHOR_ASSOC=$assoc → exit 0"
  else
    fail "AUTHOR_ASSOC=$assoc → exit $LAST_EXIT (expected 0)"
  fi
done

echo "[1b] Default UNtrusted associations → 77"
for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE; do
  D=$(new_test_dir "t1b-$assoc")
  write_config "$D" null
  run_authz "$D" \
    AUTODUCKS_AGENT=design \
    ACTOR=alice \
    AUTHOR_ASSOC="$assoc" \
    EVENT_NAME=issue_comment \
    REPO=x/y GH_TOKEN=t
  if [[ "$LAST_EXIT" -eq 77 ]]; then
    pass "AUTHOR_ASSOC=$assoc → exit 77"
  else
    fail "AUTHOR_ASSOC=$assoc → exit $LAST_EXIT (expected 77)"
  fi
done

# ---------------------------------------------------------------------------
# Test 2: deny beats allow beats association
# ---------------------------------------------------------------------------
echo "[2a] deny beats OWNER"
D=$(new_test_dir "t2a")
write_config "$D" '{"deny":["alice"]}'
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=alice \
  AUTHOR_ASSOC=OWNER \
  EVENT_NAME=issue_comment \
  ISSUE_NUM=42 COMMENT_ID=100 \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then
  pass "deny list denies OWNER"
else
  fail "expected 77, got $LAST_EXIT"
fi
if grep -q '^REACT:100|-1$' "$LAST_LOG"; then
  pass "reacted 👎 to trigger comment"
else
  fail "missing 👎 reaction (log: $(cat "$LAST_LOG"))"
fi
if grep -q '^COMMENT:42|' "$LAST_LOG"; then
  pass "posted denial comment to issue"
else
  fail "missing denial comment (log: $(cat "$LAST_LOG"))"
fi
# Denial message must not echo AUTHOR_ASSOC or config
denial_body=$(grep '^COMMENT:42|' "$LAST_LOG" | head -n1 | cut -d'|' -f2-)
if echo "$denial_body" | grep -qi 'OWNER\|MEMBER\|COLLABORATOR\|trusted_associations\|deny\b'; then
  fail "denial message leaks config/association: $denial_body"
else
  pass "denial message hides config & AUTHOR_ASSOC"
fi

echo "[2b] deny beats allow"
D=$(new_test_dir "t2b")
write_config "$D" '{"allow":["alice"],"deny":["alice"]}'
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=alice \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "deny beats allow"; else fail "expected 77, got $LAST_EXIT"; fi

echo "[2c] allow overrides unfriendly association"
D=$(new_test_dir "t2c")
write_config "$D" '{"allow":["bob"]}'
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=bob \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "allow list overrides NONE"; else fail "expected 0, got $LAST_EXIT"; fi

# ---------------------------------------------------------------------------
# Test 3: CODEOWNERS expansion (user + team) + cache
# ---------------------------------------------------------------------------
echo "[3a] CODEOWNERS user match"
D=$(new_test_dir "t3a")
write_config "$D" '{"codeowners":true}'
cat > "$D/repo/.github/CODEOWNERS" <<EOF
# Root ownership
*   @carol   @acme/reviewers
EOF
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=carol \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "CODEOWNERS user allowed"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[3b] CODEOWNERS team match via mocked gh"
D=$(new_test_dir "t3b")
write_config "$D" '{"codeowners":true}'
cat > "$D/repo/.github/CODEOWNERS" <<EOF
*   @acme/reviewers
EOF
mkdir -p "$D/bin"
# Mock `gh` — records each invocation, prints team members on 'gh api'.
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$@" >> "$AUTHZ_GH_CALLS"
case "$1" in
  api)
    # Print two members
    printf 'dave\nerin\n'
    exit 0
    ;;
esac
exit 0
GH
chmod +x "$D/bin/gh"
export AUTHZ_GH_CALLS="$D/gh-calls.txt"
: > "$AUTHZ_GH_CALLS"

run_authz "$D" \
  AUTHZ_GH_CALLS="$AUTHZ_GH_CALLS" \
  AUTODUCKS_AGENT=design \
  ACTOR=dave \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "CODEOWNERS team member allowed"; else fail "expected 0, got $LAST_EXIT"; fi

# Team-member call is cached in RUNNER_TEMP/autoducks-team-cache
cache_file="$D/tmp/autoducks-team-cache/acme-reviewers.txt"
if [[ -f "$cache_file" ]] && grep -q '^dave$' "$cache_file"; then
  pass "team members cached in RUNNER_TEMP"
else
  fail "cache file missing/empty: $cache_file"
fi

# Second run with a different actor from the same team must NOT re-invoke gh.
: > "$AUTHZ_GH_CALLS"
run_authz "$D" \
  AUTHZ_GH_CALLS="$AUTHZ_GH_CALLS" \
  AUTODUCKS_AGENT=design \
  ACTOR=erin \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "second team member allowed via cache"; else fail "expected 0, got $LAST_EXIT"; fi
if [[ ! -s "$AUTHZ_GH_CALLS" ]]; then
  pass "cache hit — gh not re-invoked"
else
  fail "gh invoked again — cache miss: $(cat "$AUTHZ_GH_CALLS")"
fi

echo "[3c] CODEOWNERS fallback order (docs/CODEOWNERS)"
D=$(new_test_dir "t3c")
write_config "$D" '{"codeowners":true}'
mkdir -p "$D/repo/docs"
cat > "$D/repo/docs/CODEOWNERS" <<EOF
*   @frank
EOF
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=frank \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "docs/CODEOWNERS fallback works"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[3d] CODEOWNERS fallback order (root CODEOWNERS)"
D=$(new_test_dir "t3d")
write_config "$D" '{"codeowners":true}'
cat > "$D/repo/CODEOWNERS" <<EOF
*   @grace
EOF
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=grace \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "root CODEOWNERS fallback works"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[3e] CODEOWNERS team unresolvable (read:org/403) → fail-closed default-deny"
D=$(new_test_dir "t3e")
write_config "$D" '{"codeowners":true}'
cat > "$D/repo/.github/CODEOWNERS" <<EOF
*   @acme/reviewers
EOF
mkdir -p "$D/bin"
# Mock `gh` — simulates a missing `read:org` scope: the team members
# lookup fails with a 403 on stderr and a non-zero exit.
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  api)
    echo "gh: HTTP 403: Resource not accessible by integration (required scopes: read:org)" >&2
    exit 1
    ;;
esac
exit 0
GH
chmod +x "$D/bin/gh"

run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=zach \
  AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then
  pass "unresolved @org/team CODEOWNERS ref denies (fail-closed for authz)"
else
  fail "expected 77, got $LAST_EXIT"
fi
if grep -qi 'read:org\|required scopes\|HTTP 403' "$LAST_SUMMARY"; then
  pass "scope-specific warning recorded for unresolvable team"
else
  fail "missing scope-specific warning: $(cat "$LAST_SUMMARY")"
fi

# ---------------------------------------------------------------------------
# Test 4: Event bypasses
# ---------------------------------------------------------------------------
echo "[4a] workflow_dispatch bypass (empty ACTOR + ASSOC)"
D=$(new_test_dir "t4a")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR="" AUTHOR_ASSOC="" \
  EVENT_NAME=workflow_dispatch \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "workflow_dispatch bypasses"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[4b] pull_request bypass"
D=$(new_test_dir "t4b")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=maestro \
  ACTOR="" AUTHOR_ASSOC="" \
  EVENT_NAME=pull_request \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "pull_request bypasses"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[4c] schedule bypass (no ACTOR/AUTHOR_ASSOC required)"
D=$(new_test_dir "t4c")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=maestro \
  ACTOR="" AUTHOR_ASSOC="" \
  EVENT_NAME=schedule \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "schedule bypasses"; else fail "expected 0, got $LAST_EXIT"; fi

# ---------------------------------------------------------------------------
# Test 5: Fail-closed cases
# ---------------------------------------------------------------------------
echo "[5a] Missing env vars → 77"
D=$(new_test_dir "t5a")
write_config "$D" null
run_authz "$D" \
  AUTHOR_ASSOC=OWNER \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "missing AUTODUCKS_AGENT/ACTOR → 77"; else fail "expected 77, got $LAST_EXIT"; fi

echo "[5b] Unparseable config → 77"
D=$(new_test_dir "t5b")
echo "{ not json" > "$AUTZ_ROOT/autoducks.json"
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=alice AUTHOR_ASSOC=OWNER \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "unparseable config → 77"; else fail "expected 77, got $LAST_EXIT"; fi

echo "[5c] Unrecognized AUTHOR_ASSOC → 77"
D=$(new_test_dir "t5c")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=alice AUTHOR_ASSOC=WEIRD_GARBAGE_VALUE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "unrecognized AUTHOR_ASSOC → 77"; else fail "expected 77, got $LAST_EXIT"; fi

# ---------------------------------------------------------------------------
# Test 6: Per-agent overrides (revert / close narrow the trusted set)
# ---------------------------------------------------------------------------
echo "[6] per_agent override: revert denies COLLABORATOR (default trusted for design)"
D=$(new_test_dir "t6")
write_config "$D" null
# design → allow, revert → deny
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "design allows COLLABORATOR"; else fail "expected 0, got $LAST_EXIT"; fi

run_authz "$D" \
  AUTODUCKS_AGENT=revert \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "revert denies COLLABORATOR"; else fail "expected 77, got $LAST_EXIT"; fi

echo "[6b] per_agent key mapping: maestro/developer resolve to the execute policy"
D=$(new_test_dir "t6b")
write_config "$D" '{"per_agent":{"execute":{"trusted_associations":["OWNER"]}}}'
run_authz "$D" \
  AUTODUCKS_AGENT=developer \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "developer inherits execute policy (COLLABORATOR denied)"; else fail "expected 77, got $LAST_EXIT"; fi

run_authz "$D" \
  AUTODUCKS_AGENT=maestro \
  ACTOR=alice AUTHOR_ASSOC=OWNER \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "maestro inherits execute policy (OWNER allowed)"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[6c] per_agent key mapping: triage resolves to the product policy (baseline defaults)"
D=$(new_test_dir "t6c")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=triage \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "triage (→product) allows COLLABORATOR"; else fail "expected 0, got $LAST_EXIT"; fi

run_authz "$D" \
  AUTODUCKS_AGENT=product \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "product allows COLLABORATOR"; else fail "expected 0, got $LAST_EXIT"; fi

echo "[6d] merge stays on its own destructive policy (COLLABORATOR denied)"
D=$(new_test_dir "t6d")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=merge \
  ACTOR=alice AUTHOR_ASSOC=COLLABORATOR \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 77 ]]; then pass "merge denies COLLABORATOR"; else fail "expected 77, got $LAST_EXIT"; fi

run_authz "$D" \
  AUTODUCKS_AGENT=merge \
  ACTOR=alice AUTHOR_ASSOC=MEMBER \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if [[ "$LAST_EXIT" -eq 0 ]]; then pass "merge allows MEMBER"; else fail "expected 0, got $LAST_EXIT"; fi

# ---------------------------------------------------------------------------
# Test 7: Audit trail (denials, allowlist, CODEOWNERS)
# ---------------------------------------------------------------------------
echo "[7a] Audit line on denial"
D=$(new_test_dir "t7a")
write_config "$D" null
run_authz "$D" \
  AUTODUCKS_AGENT=design \
  ACTOR=mallory AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if grep -q 'authz: DENY' "$LAST_SUMMARY" \
   && grep -q 'actor=mallory' "$LAST_SUMMARY" \
   && grep -q 'agent=design' "$LAST_SUMMARY" \
   && grep -q 'rule=' "$LAST_SUMMARY"; then
  pass "denial audit line present with all fields"
else
  fail "denial audit incomplete: $(cat "$LAST_SUMMARY")"
fi

echo "[7b] Audit line on allowlist allow"
D=$(new_test_dir "t7b")
write_config "$D" '{"allow":["bob"]}'
run_authz "$D" \
  AUTODUCKS_AGENT=execution \
  ACTOR=bob AUTHOR_ASSOC=NONE \
  EVENT_NAME=issue_comment \
  REPO=x/y GH_TOKEN=t
if grep -q 'authz: ALLOW' "$LAST_SUMMARY" \
   && grep -q 'rule=allow_list' "$LAST_SUMMARY"; then
  pass "allowlist audit line present"
else
  fail "allow_list audit missing: $(cat "$LAST_SUMMARY")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== authorize.sh unit test summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
