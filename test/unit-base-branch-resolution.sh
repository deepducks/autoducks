#!/usr/bin/env bash
# Guard for #1181: the base branch must come from defaults.base_branch or from
# the repository's own default branch — never from a hardcoded literal.
#
# Two halves. The static half greps the shipped workflow templates for a
# literal branch name where an expression belongs; a regression here is invisible
# at runtime (a push trigger that never fires looks exactly like one with nothing
# to report), so a text assertion is the only thing that catches it. The dynamic
# half drives load-config.sh's resolution chain against throwaway fixtures.
#
# Run: bash test/unit-base-branch-resolution.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.autoducks/runtimes/github-actions"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

echo "── no workflow pins a literal branch name ──"
# Two exemptions, both because their `main` names *this* repo's branch rather
# than a consumer's base branch:
#
#   - autoducks-install.yml fetches install.sh from deepducks/autoducks@main.
#   - Upstream-only workflows — those with no runtime template, autoducks-release.yml
#     being the one today (install.sh:282) — never ship to a consumer at all, so
#     their triggers only ever describe this repository.
#
# The upstream-only rule is derived, not a name list, so a new upstream-only
# workflow is exempt automatically and a template that loses its mirror gets
# caught by unit-workflow-mirror-parity.sh instead.
for dir in "$RUNTIME_DIR" "$WORKFLOW_DIR"; do
  label="$(basename "$(dirname "$dir")")/$(basename "$dir")"
  for wf in "$dir"/autoducks-*.yml; do
    base="$(basename "$wf")"
    [[ "$base" == "autoducks-install.yml" ]] && continue
    [[ -f "$RUNTIME_DIR/$base" ]] || continue

    # `on.push.branches: [main]` — an allow-list that silently excludes any repo
    # whose branch is named differently.
    if grep -qE "^\s+branches:\s*\[.*\bmain\b.*\]" "$wf"; then
      fail "$label/$base: push/PR trigger allow-lists a literal branch name"
    else
      pass "$label/$base: no literal branch allow-list"
    fi

    # `|| 'main'` / `default: 'main'` — a fallback that resolves to a ref the
    # repo may not have. Comments are stripped first so prose may say "main".
    if sed 's/#.*//' "$wf" | grep -qE "(default:\s*'main'|\|\|\s*'main')"; then
      fail "$label/$base: falls back to the literal 'main'"
    else
      pass "$label/$base: no literal 'main' fallback"
    fi
  done
done

echo ""
echo "── the default-branch decision moved into the job's if: ──"
CL="$WORKFLOW_DIR/autoducks-commit-lint.yml"
if grep -q "github.event.repository.default_branch" "$CL"; then
  pass "commit-lint gates on the repository default branch"
else
  fail "commit-lint no longer references default_branch — the push gate is gone"
fi
if grep -qE "^\s+branches-ignore:" "$CL"; then
  pass "commit-lint filters push noise by exclusion, not allow-list"
else
  fail "commit-lint lost its branches-ignore exclusion filter"
fi

echo ""
echo "── AUTODUCKS_BASE_BRANCH passes the config through verbatim ──"
# Deliberately NOT resolved here. load-config.sh exports what the config says,
# empty included, and callers that need a concrete branch ask the host — see
# sync-child-gitlinks.sh:42-49, which falls back to `gh api repos/$REPO --jq
# .default_branch` and warns when even that comes back empty.
#
# The host API is the authoritative answer; origin/HEAD is a local ref that can
# be stale or absent, and resolving it inside load-config.sh would silently
# preempt the better source. An earlier cut of #1181 did exactly that and broke
# unit-sync-child-gitlinks.sh, which asserts the API round trip happens.
FIXTURE_MACHINERY="$(mktemp -d)"
TMP_DIRS+=("$FIXTURE_MACHINERY")
cp -R "$REPO_ROOT/.autoducks" "$FIXTURE_MACHINERY/.autoducks"

new_fixture() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  cp -R "$FIXTURE_MACHINERY/.autoducks" "$d/.autoducks"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  printf '%s' "$d"
}

# set_base_branch FIXTURE JSON_VALUE — rewrite only defaults.base_branch, keeping
# the rest of the real config. load-config.sh requires provider keys (its, git)
# to be present, so a hand-written stub config cannot drive it.
set_base_branch() {
  local dir="$1" value="$2"
  jq ".defaults.base_branch = $value" "$REPO_ROOT/.autoducks/autoducks.json" \
    > "$dir/.autoducks/autoducks.json"
}

# resolve FIXTURE → the AUTODUCKS_BASE_BRANCH load-config.sh exports.
# GITHUB_ACTIONS=true keeps load-config.sh from sourcing providers/llm/interface.sh,
# which terminates the shell in a credential-less fixture. GITHUB_OUTPUT is
# required by the endpoint resolver; point it at scratch.
resolve() {
  local dir="$1"
  ( cd "$dir" \
    && GITHUB_ACTIONS=true \
       GITHUB_OUTPUT="$dir/gh_output" \
       AUTODUCKS_ROOT="$dir/.autoducks" \
       bash -c "source '$REPO_ROOT/.autoducks/core/config/load-config.sh' >/dev/null 2>&1; printf '%s' \"\$AUTODUCKS_BASE_BRANCH\"" ) || true
}

D="$(new_fixture)"
set_base_branch "$D" '"master"'
GOT="$(resolve "$D")"
if [[ "$GOT" == "master" ]]; then
  pass "a configured base_branch is exported verbatim"
else
  fail "configured value mangled: got '$GOT', expected 'master'"
fi

# The case that matters: an unset key must stay empty even when the working
# directory has an origin/HEAD that could have been guessed from.
D="$(new_fixture)"
set_base_branch "$D" 'null'
git -C "$D" commit -q --allow-empty -m init
git -C "$D" update-ref refs/remotes/origin/main HEAD
git -C "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
GOT="$(resolve "$D")"
if [[ -z "$GOT" ]]; then
  pass "an unset base_branch stays empty, leaving resolution to the caller"
else
  fail "load-config guessed '$GOT' instead of deferring to the caller"
fi

echo ""
echo "═══ base-branch-resolution: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
