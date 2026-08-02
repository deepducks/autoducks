#!/usr/bin/env bash
# Unit tests for metarepo::pin_reachable and the delivery check's use of it (#178).
# Run: bash test/unit-metarepo-pin-reachability.sh
#
# The delivery check asked "did every child's delivery PR merge" and called that
# a green delivery. It is a different question from "can anyone clone this". On
# meta#165 the parent carried a gitlink no remote ref reached — the branch had
# been deleted out from under it — and the check reported SUCCESS the whole
# time, because it read the child PR's state and never the SHA.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METAREPO="$REPO_ROOT/.autoducks/core/config/metarepo.sh"
POLL="$REPO_ROOT/.autoducks/core/orchestration/poll-child-deliveries.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin"
export PATH="$SCRATCH/bin:$PATH"

# Fixture knobs, read by the stubs below through the environment.
#   TIP           — the child's default-branch tip
#   COMPARE_<sha> — what compare returns with that SHA as head
#   LS_REMOTE     — newline-separated SHAs the child's refs point at
#   OPEN_PR_HEADS — newline-separated open PR head SHAs
cat > "$SCRATCH/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh api repos/<slug>            -> {"default_branch": "main"}
# gh api repos/<slug>/commits/X  -> {"sha": "$TIP"}  (X = default branch)
# gh api repos/<slug>/compare/BASE...HEAD -> {"status": "$COMPARE_<HEAD>_<BASE>"}
# gh api repos/<slug>/pulls?...  -> open PR head SHAs
path=""
for a in "$@"; do case "$a" in repos/*) path="$a"; break ;; esac; done
case "$path" in
  */compare/*)
    spec="${path##*/compare/}"
    base="${spec%%...*}"; head="${spec##*...}"
    var="COMPARE_${head}_${base}"
    printf '%s\n' "${!var:-unrelated}"
    ;;
  */commits/*) printf '%s\n' "${TIP:-}" ;;
  */pulls*)    printf '%s\n' "${OPEN_PR_HEADS:-}" ;;
  repos/*)     printf 'main\n' ;;
  *)           exit 1 ;;
esac
STUB
chmod +x "$SCRATCH/bin/gh"

# Real git for everything except ls-remote, which must not touch the network.
REAL_GIT="$(command -v git)"
cat > "$SCRATCH/bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-remote" ]]; then
  while read -r s; do [[ -n "\$s" ]] && printf '%s\trefs/heads/x\n' "\$s"; done <<< "\${LS_REMOTE:-}"
  exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$SCRATCH/bin/git"

# shellcheck source=/dev/null
source "$METAREPO"
git::resolve_token() { printf 'tok'; }

TIP_SHA="1111111111111111111111111111111111111111"
ON_MAIN="2222222222222222222222222222222222222222"
PR_TIP="3333333333333333333333333333333333333333"
PR_MID="4444444444444444444444444444444444444444"
ORPHAN="5555555555555555555555555555555555555555"

export TIP="$TIP_SHA"

reachable() {
  local rc=0
  ( metarepo::pin_reachable "acme/child" "$1" ) || rc=$?
  printf '%s' "$rc"
}

echo "── a pin the default branch contains is reachable ──"

export COMPARE_${ON_MAIN}_${TIP_SHA}="behind"
export LS_REMOTE="" OPEN_PR_HEADS=""
[[ "$(reachable "$ON_MAIN")" == "0" ]] \
  && pass "contained in the default branch → reachable" \
  || fail "a pin inside the default branch was reported unreachable"

export COMPARE_${TIP_SHA}_${TIP_SHA}="identical"
[[ "$(reachable "$TIP_SHA")" == "0" ]] \
  && pass "the default-branch tip itself → reachable" \
  || fail "the tip was reported unreachable"

echo "── a pin ahead of the default branch falls through to the refs ──"

# Ahead of main, but it is a ref tip — an open delivery branch or PR head.
export COMPARE_${PR_TIP}_${TIP_SHA}="ahead"
export LS_REMOTE="$PR_TIP"
[[ "$(reachable "$PR_TIP")" == "0" ]] \
  && pass "ahead of the default branch but a live ref tip → reachable" \
  || fail "a live ref tip was reported unreachable"

# Ahead of main, not a ref tip, but an interior commit of an open PR.
export COMPARE_${PR_MID}_${TIP_SHA}="ahead"
export COMPARE_${PR_MID}_${PR_TIP}="behind"
export LS_REMOTE="" OPEN_PR_HEADS="$PR_TIP"
[[ "$(reachable "$PR_MID")" == "0" ]] \
  && pass "interior commit of an open PR → reachable" \
  || fail "an open PR's interior commit was reported unreachable"

echo "── the #176 state: nothing reaches it ──"

# This is meta#165's gitlink after the head branch was deleted: not on main,
# not a ref tip, not inside any open PR.
export COMPARE_${ORPHAN}_${TIP_SHA}="diverged"
export LS_REMOTE="$TIP_SHA
$PR_TIP"
export OPEN_PR_HEADS="$PR_TIP"
export COMPARE_${ORPHAN}_${PR_TIP}="diverged"
[[ "$(reachable "$ORPHAN")" == "1" ]] \
  && pass "no branch, tag or open PR head reaches it → unreachable (1)" \
  || fail "a stranded pin was NOT reported unreachable — this is the #178 hole"

echo "── an undetermined answer is not a failure ──"

# No slug, no SHA, or an API that says nothing: 2, never 1. A delivery check
# that goes red on a network blip is worse than the hole it closes.
[[ "$(reachable "")" == "2" ]] \
  && pass "empty SHA → undetermined (2), not a failure" \
  || fail "an empty SHA was treated as unreachable"

_saved_gh="$(cat "$SCRATCH/bin/gh")"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SCRATCH/bin/gh"
[[ "$(reachable "$ORPHAN")" == "2" ]] \
  && pass "unreadable API → undetermined (2), not a failure" \
  || fail "an unreadable API was treated as unreachable"
printf '%s\n' "$_saved_gh" > "$SCRATCH/bin/gh"

echo "── the delivery check routes both success exits through the gate ──"

# Both were plain `conclude_all success` before: the one where no child is
# protected, and the one where every child merged. A gate on only the second
# leaves the first reporting SUCCESS on a stranded pin.
if [[ "$(grep -c 'conclude_all success' "$POLL")" -eq 1 ]]; then
  pass "only conclude_success's own call reaches conclude_all success"
else
  fail "a success exit still bypasses the reachability gate"
fi

for _marker in 'conclude_success "No protected children to poll"' \
               'conclude_success "All children delivered"'; do
  if grep -qF "$_marker" "$POLL"; then
    pass "gated: ${_marker#conclude_success }"
  else
    fail "ungated success exit: ${_marker#conclude_success }"
  fi
done

# Only rc==1 may fail the check; rc==2 must fall through.
if grep -qE 'rc"? -eq 1' "$POLL"; then
  pass "the check fails on 1 (unreachable), not on 2 (undetermined)"
else
  fail "the check does not distinguish unreachable from undetermined"
fi

echo ""
echo "═══ metarepo pin reachability: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
