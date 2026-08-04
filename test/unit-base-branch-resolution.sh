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
echo "── load-config.sh resolution order ──"
# Minimal fixture: a git repo with an .autoducks/autoducks.json, driven through
# load-config.sh with the event payload and origin/HEAD controlled per case.
# load-config.sh sources providers and helpers from $AUTODUCKS_ROOT, so the
# fixture needs a real machinery tree, not a bare autoducks.json. Copy it once
# and hand each case its own git repo with a symlinked .autoducks — the only
# per-case difference is the config file and the refs.
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

# resolve FIXTURE [EVENT_JSON] → the AUTODUCKS_BASE_BRANCH load-config.sh exports
resolve() {
  local dir="$1" event="${2:-}"
  local event_arg=""
  if [[ -n "$event" ]]; then
    printf '%s' "$event" > "$dir/event.json"
    event_arg="$dir/event.json"
  fi
  # GITHUB_ACTIONS=true is fixed for every case, including the "outside Actions"
  # one. It is not what that case is about: load-config.sh only sources
  # providers/llm/interface.sh when the variable is unset, and that interface
  # terminates the shell in a credential-less fixture, which would mask the value
  # under test. The resolution chain is driven entirely by GITHUB_EVENT_PATH and
  # origin/HEAD, both controlled per case below.
  #
  # GITHUB_OUTPUT is required by the LLM endpoint resolver; point it at scratch.
  # The `|| true` keeps an unrelated non-zero exit from taking the suite down
  # under `set -e` — the assertion is on the value, and empty is itself an
  # outcome this suite tests for.
  ( cd "$dir" \
    && GITHUB_ACTIONS=true \
       GITHUB_EVENT_PATH="$event_arg" \
       GITHUB_OUTPUT="$dir/gh_output" \
       AUTODUCKS_ROOT="$dir/.autoducks" \
       bash -c "source '$REPO_ROOT/.autoducks/core/config/load-config.sh' >/dev/null 2>&1; printf '%s' \"\$AUTODUCKS_BASE_BRANCH\"" ) || true
}

D="$(new_fixture)"
set_base_branch "$D" '"master"'
GOT="$(resolve "$D" '{"repository":{"default_branch":"trunk"}}')"
if [[ "$GOT" == "master" ]]; then
  pass "an explicit defaults.base_branch wins over the event payload"
else
  fail "explicit override ignored: got '$GOT', expected 'master'"
fi

D="$(new_fixture)"
set_base_branch "$D" 'null'
GOT="$(resolve "$D" '{"repository":{"default_branch":"trunk"}}')"
if [[ "$GOT" == "trunk" ]]; then
  pass "with no override, the Actions event payload answers"
else
  fail "event payload ignored: got '$GOT', expected 'trunk'"
fi

D="$(new_fixture)"
set_base_branch "$D" 'null'
git -C "$D" commit -q --allow-empty -m init
git -C "$D" branch -f release-2 HEAD
git -C "$D" update-ref refs/remotes/origin/release-2 HEAD
git -C "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release-2
GOT="$(resolve "$D")"
if [[ "$GOT" == "release-2" ]]; then
  pass "with no event payload, origin/HEAD answers"
else
  fail "origin/HEAD ignored: got '$GOT', expected 'release-2'"
fi

D="$(new_fixture)"
set_base_branch "$D" 'null'
GOT="$(resolve "$D")"
if [[ -z "$GOT" ]]; then
  pass "with no source at all it stays empty rather than guessing 'main'"
else
  fail "invented a branch name with nothing to go on: got '$GOT'"
fi

echo ""
echo "═══ base-branch-resolution: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
