#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/label-utils.sh
# Run: bash test/unit-label-utils.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL_UTILS="$REPO_ROOT/.autoducks/core/config/label-utils.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "── static checks ──"
bash -n "$LABEL_UTILS" && pass "bash -n" || fail "bash -n failed"
if command -v shellcheck &>/dev/null; then
  shellcheck "$LABEL_UTILS" && pass "shellcheck" || fail "shellcheck failed"
else
  echo "  (shellcheck not installed, skipping)"
fi

echo "── sourceable twice ──"
(
  # shellcheck source=/dev/null
  source "$LABEL_UTILS"
  # shellcheck source=/dev/null
  source "$LABEL_UTILS"
) && pass "double source is a no-op" || fail "double source errored"

echo "── sourceable with no \$REPO and no gh (pure helpers only) ──"
(
  unset REPO
  unset -f gh 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$LABEL_UTILS"
  label::in_list $'bug\nfeature' Bug
) && pass "sourceable + in_list usable with no REPO/gh" || fail "failed with no REPO/gh"

# ── the remaining tests exercise gh-calling paths, so run in a fresh subshell
# per scenario with a mocked gh that logs every invocation.
CALL_LOG_FILE="$(mktemp)"
trap 'rm -f "$CALL_LOG_FILE"' EXIT

GH_LABELS=""
GH_EDIT_FAIL=0
GH_CREATE_FAIL=0

gh() {
  echo "gh $*" >> "$CALL_LOG_FILE"
  case "$1 $2" in
    "label list")
      printf '%s\n' "$GH_LABELS"
      return 0
      ;;
    "label edit")
      if [[ "$GH_EDIT_FAIL" -eq 1 ]]; then
        echo "gh: label edit failed (mock)" >&2
        return 1
      fi
      return 0
      ;;
    "label create")
      if [[ "$GH_CREATE_FAIL" -eq 1 ]]; then
        echo "gh: label create failed (mock)" >&2
        return 1
      fi
      return 0
      ;;
  esac
  return 0
}
export -f gh

REPO="x/y"
# shellcheck source=/dev/null
source "$LABEL_UTILS"

reset_log() { : > "$CALL_LOG_FILE"; }
call_count() { grep -c -- "$1" "$CALL_LOG_FILE" || true; }

echo "── label::load caches after one call ──"
label::_invalidate
GH_LABELS="bug"
reset_log
label::load
label::load
n="$(call_count '^gh label list')"
[[ "$n" -eq 1 ]] && pass "label::load issues exactly one gh label list call" || fail "expected 1 gh label list call, got $n"

echo "── label::resolve ──"
label::_invalidate
GH_LABELS="bug"
[[ "$(label::resolve Bug)" == "bug" ]] \
  && pass "resolve Bug -> bug on lowercase-only repo" || fail "resolve Bug mismatch: $(label::resolve Bug)"
[[ -z "$(label::resolve Nonexistent)" ]] \
  && pass "resolve returns empty when no case-variant exists" || fail "resolve Nonexistent not empty"

echo "── label::exists ──"
label::_invalidate
GH_LABELS="bug"
label::exists Bug && pass "exists Bug true (case-insensitive)" || fail "exists Bug should be true"
rc=0; label::exists Nope || rc=$?
[[ "$rc" -ne 0 ]] && pass "exists Nope false" || fail "exists Nope should be false"

echo "── label::in_list whole-line match ──"
LIST=$'bug\nfeature'
label::in_list "$LIST" bug    && pass "in_list matches bug"    || fail "in_list bug failed"
label::in_list "$LIST" BUG    && pass "in_list matches BUG"    || fail "in_list BUG failed"
label::in_list "$LIST" Bug    && pass "in_list matches Bug"    || fail "in_list Bug failed"
if label::in_list "$LIST" bugfix; then fail "in_list should reject bugfix (substring, not whole line)"; else pass "in_list rejects bugfix"; fi

echo "── label::any_in_list ──"
label::any_in_list "$LIST" nope BUG && pass "any_in_list finds BUG among candidates" || fail "any_in_list failed"
if label::any_in_list "$LIST" nope nada; then fail "any_in_list should fail with no matches"; else pass "any_in_list correctly fails with no matches"; fi

echo "── label::has_prefix_in_list ──"
PLIST=$'Priority:high\nPriority:low\nbug'
out="$(label::has_prefix_in_list "$PLIST" priority:)"
[[ "$out" == $'Priority:high\nPriority:low' ]] \
  && pass "has_prefix_in_list matches case-insensitively" || fail "has_prefix_in_list mismatch: $out"

echo "── label::ensure exact-casing hit is a no-op ──"
label::_invalidate
GH_LABELS="Bug"
reset_log
label::ensure Bug D73A4A "desc"
n_writes="$(grep -c -- '^gh label \(create\|edit\)' "$CALL_LOG_FILE" || true)"
[[ "$n_writes" -eq 0 ]] && pass "ensure exact-casing hit makes zero gh write calls" || fail "expected 0 writes, got $n_writes: $(cat "$CALL_LOG_FILE")"

echo "── label::ensure case-variant hit renames (name only) ──"
label::_invalidate
GH_LABELS="bug"
reset_log
label::ensure Bug D73A4A "desc"
grep -q '^gh label edit bug --repo x/y --name Bug$' "$CALL_LOG_FILE" \
  && pass "ensure issues gh label edit with name only, no color/description" || fail "unexpected edit call: $(cat "$CALL_LOG_FILE")"
n_edits="$(call_count '^gh label edit')"
[[ "$n_edits" -eq 1 ]] && pass "exactly one gh label edit call" || fail "expected 1 edit call, got $n_edits"
[[ "$(label::resolve Bug)" == "Bug" ]] && pass "cache updated in place after rename" || fail "cache not updated after rename"

echo "── label::ensure cache miss creates ──"
label::_invalidate
GH_LABELS=""
reset_log
label::ensure NewLabel ABCDEF "a new label"
grep -q '^gh label create NewLabel --repo x/y --color ABCDEF --description a new label$' "$CALL_LOG_FILE" \
  && pass "ensure creates with canonical color/description" || fail "unexpected create call: $(cat "$CALL_LOG_FILE")"

echo "── label::ensure forwards gh stderr on failed rename ──"
label::_invalidate
GH_LABELS="bug"
GH_EDIT_FAIL=1
err="$(label::ensure Bug 2>&1 >/dev/null)" && rc=0 || rc=$?
GH_EDIT_FAIL=0
[[ "$rc" -ne 0 ]] && pass "ensure returns non-zero on failed rename" || fail "ensure should have failed"
[[ "$err" == *"gh: label edit failed (mock)"* ]] \
  && pass "ensure forwards gh stderr on failed rename" || fail "stderr not forwarded: $err"

echo "── label::ensure forwards gh stderr on failed create ──"
label::_invalidate
GH_LABELS=""
GH_CREATE_FAIL=1
err="$(label::ensure BrandNew 2>&1 >/dev/null)" && rc=0 || rc=$?
GH_CREATE_FAIL=0
[[ "$rc" -ne 0 ]] && pass "ensure returns non-zero on failed create" || fail "ensure should have failed"
[[ "$err" == *"gh: label create failed (mock)"* ]] \
  && pass "ensure forwards gh stderr on failed create" || fail "stderr not forwarded: $err"

echo "── AUTODUCKS_LABEL_AUTORENAME=0 opts out of rename ──"
label::_invalidate
GH_LABELS="bug"
reset_log
AUTODUCKS_LABEL_AUTORENAME=0
err="$(label::ensure Bug 2>&1 >/dev/null)" && rc=0 || rc=$?
unset AUTODUCKS_LABEL_AUTORENAME
[[ "$rc" -ne 0 ]] && pass "ensure returns non-zero when autorename disabled" || fail "ensure should have failed"
n_edits="$(call_count '^gh label edit')"
[[ "$n_edits" -eq 0 ]] && pass "no gh label edit call when autorename disabled" || fail "expected 0 edit calls, got $n_edits"
[[ "$err" == *"bug"* && "$err" == *"Bug"* ]] \
  && pass "message names existing casing and canonical name" || fail "message missing casing info: $err"

echo ""
echo "═══ label-utils: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
