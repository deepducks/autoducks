#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/sync-child-gitlinks.sh (#170).
# Run: bash test/unit-sync-child-gitlinks.sh
#
# The reconcile itself is covered by unit-metarepo-gitlink-pin.sh. What is new
# here — and what these assert — is the decision layer around it: staying inert
# outside metarepo mode, resolving which branch to reconcile, and collecting
# every declared submodule rather than one PR's delivered children.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_REL=".autoducks/core/orchestration/sync-child-gitlinks.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── A repo with the real machinery, and a gh that logs every call ──────────
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$*" in
  *"--jq .default_branch") echo "${MOCK_DEFAULT_BRANCH-main}" ;;
  *) return 0 ;;
esac
GH
chmod +x "$SCRATCH/bin/gh"

WORK="$SCRATCH/repo"
mkdir -p "$WORK"
cp -R "$REPO_ROOT/.autoducks" "$WORK/.autoducks"
git init -q "$WORK"

write_gitmodules() { # PATHS...
  : > "$WORK/.gitmodules"
  local p
  for p in "$@"; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = https://github.com/acme/%s.git\n' \
      "$p" "$p" "$p" >> "$WORK/.gitmodules"
  done
}

set_metarepo() { # true|false
  jq --argjson e "$1" '.metarepo.enabled = $e' \
    "$WORK/.autoducks/autoducks.json" > "$WORK/.autoducks/tmp.json"
  mv "$WORK/.autoducks/tmp.json" "$WORK/.autoducks/autoducks.json"
}

# run_sync [EXTRA_ENV=...] → stderr of the script; the reconcile itself will
# fail against a repo with no remote, which is fine: everything asserted here
# happens before it, and the reconcile has its own tests.
#
# GITHUB_ACTIONS/GITHUB_OUTPUT/GITHUB_ENV are runner-provided, and every caller
# of this script is a workflow step where all three exist. GITHUB_ACTIONS in
# particular is load-bearing: load-config.sh:283 only sources the LLM provider
# interface outside Actions, and that interface sources every *.sh in the
# provider dir — including resolve-endpoint.sh, which is written to be executed
# and ends in `exit 0`. Without this the harness dies silently mid-source.
run_sync() {
  : > "$SCRATCH/gh.log"
  ( cd "$WORK" && env PATH="$SCRATCH/bin:$PATH" GH_LOG="$SCRATCH/gh.log" \
      GITHUB_ACTIONS="true" GITHUB_OUTPUT="$SCRATCH/gh-output" GITHUB_ENV="$SCRATCH/gh-env" \
      REPO="acme/meta" "$@" bash "$SCRIPT_REL" ) 2>&1 || true
}

# ---------------------------------------------------------------------------
echo "── inert outside metarepo mode ──"

set_metarepo false
write_gitmodules child-a
out="$(run_sync)"
if [[ -z "$(cat "$SCRATCH/gh.log")" ]]; then
  pass "single-repo install makes no API call at all"
else
  fail "single-repo install called gh: $(cat "$SCRATCH/gh.log")"
fi
if [[ "$out" != *"reconciling"* ]]; then
  pass "single-repo install reconciles nothing"
else
  fail "single-repo install reached the reconcile: $out"
fi

# ---------------------------------------------------------------------------
echo "── nothing to do when no submodule is declared ──"

set_metarepo true
: > "$WORK/.gitmodules"
out="$(run_sync)"
if [[ "$out" == *"no submodules declared"* && "$out" != *"reconciling"* ]]; then
  pass "empty .gitmodules → notice, no reconcile"
else
  fail "empty .gitmodules produced: $out"
fi

rm -f "$WORK/.gitmodules"
out="$(run_sync)"
if [[ "$out" != *"reconciling"* ]]; then
  pass "absent .gitmodules → no reconcile"
else
  fail "absent .gitmodules reached the reconcile: $out"
fi

# ---------------------------------------------------------------------------
echo "── every declared submodule is reconciled, not just one PR's children ──"

set_metarepo true
write_gitmodules child-a child-b vendor/child-c
out="$(run_sync)"
for p in child-a child-b vendor/child-c; do
  if [[ "$out" == *"$p"* ]]; then
    pass "reconcile covers $p"
  else
    fail "reconcile skipped $p — got: $out"
  fi
done
if [[ "$out" == *"3 child(ren)"* ]]; then
  pass "reports the full child count"
else
  fail "wrong child count in: $out"
fi

# ---------------------------------------------------------------------------
echo "── branch resolution ──"

# The pipeline's own base_branch wins. Reconciling anything else would move a
# gitlink on a branch nobody builds on.
set_base_branch() { # BRANCH ("" clears it)
  jq --arg b "$1" \
    'if $b == "" then del(.defaults.base_branch) else .defaults.base_branch = $b end' \
    "$WORK/.autoducks/autoducks.json" > "$WORK/.autoducks/tmp.json"
  mv "$WORK/.autoducks/tmp.json" "$WORK/.autoducks/autoducks.json"
}

set_base_branch trunk
out="$(run_sync)"
if [[ "$out" == *"reconciling 'trunk'"* ]]; then
  pass "reconciles the configured base_branch"
else
  fail "wrong branch in: $out"
fi
if ! grep -q -- "--jq .default_branch" "$SCRATCH/gh.log"; then
  pass "a configured base_branch skips the API round trip entirely"
else
  fail "looked up the default branch despite a configured base_branch"
fi

set_base_branch ""
out="$(run_sync)"
if grep -q -- "--jq .default_branch" "$SCRATCH/gh.log"; then
  pass "falls back to asking the host when base_branch is unset"
else
  fail "never resolved the default branch: $(cat "$SCRATCH/gh.log")"
fi
if [[ "$out" == *"reconciling 'main'"* ]]; then
  pass "reconciles the host's default branch on fallback"
else
  fail "wrong fallback branch in: $out"
fi

# An unresolvable default branch must not be treated as a branch named "".
out="$(run_sync MOCK_DEFAULT_BRANCH=)"
if [[ "$out" == *"cannot resolve the default branch"* && "$out" != *"reconciling"* ]]; then
  pass "unresolvable default branch → warning, nothing reconciled"
else
  fail "unresolvable default branch produced: $out"
fi
set_base_branch main

# ---------------------------------------------------------------------------
echo "── REPO is required ──"

set_metarepo true
write_gitmodules child-a
rc=0
# -u REPO, not merely leaving it off the env line: env inherits the caller's
# environment, so an ambient REPO would make this assert nothing.
( cd "$WORK" && env -u REPO PATH="$SCRATCH/bin:$PATH" GH_LOG="$SCRATCH/gh.log" \
    GITHUB_ACTIONS="true" GITHUB_OUTPUT="$SCRATCH/gh-output" GITHUB_ENV="$SCRATCH/gh-env" \
    bash "$SCRIPT_REL" ) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "missing REPO fails loudly (rc=$rc)"
else
  fail "missing REPO exited 0"
fi

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
