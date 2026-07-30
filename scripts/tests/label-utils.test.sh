#!/usr/bin/env bash
# Offline unit tests for .autoducks/core/config/label-utils.sh.
#
# Unlike test/unit-label-utils.sh (which mocks `gh` as an exported bash
# function for autoducks' own dev-time CI), this suite drives label-utils.sh
# through a real `gh` *executable* placed first on PATH, so it exercises the
# actual external-process contract (argv, exit code, stderr) and proves the
# module never needs network access or gh credentials. Run via
# scripts/tests/run.sh, or directly: bash scripts/tests/label-utils.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL_UTILS="$REPO_ROOT/.autoducks/core/config/label-utils.sh"

PASS=0
FAIL=0
pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

# -----------------------------------------------------------------------
# Fake gh: a real executable named `gh`, written to a temp dir prepended to
# PATH. Dispatches on "$1 $2", logs the full argv of every invocation (one
# line per call) to $GH_FAKE_LOG, and serves canned responses via env vars
# so each scenario below controls list/edit/create outcomes with no network.
# -----------------------------------------------------------------------
FAKE_BIN_DIR="$(mktemp -d)"
GH_FAKE_LOG="$(mktemp)"
cleanup() { rm -rf "$FAKE_BIN_DIR"; rm -f "$GH_FAKE_LOG"; }
trap cleanup EXIT

cat > "$FAKE_BIN_DIR/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake `gh` for offline label-utils tests. Never touches the network.
set -uo pipefail
echo "gh $*" >> "$GH_FAKE_LOG"
case "$1 $2" in
  "label list")
    printf '%s\n' "$GH_FAKE_LABELS"
    exit 0
    ;;
  "label edit")
    if [[ "${GH_FAKE_EDIT_EXIT:-0}" != 0 ]]; then
      [[ -n "${GH_FAKE_EDIT_STDERR:-}" ]] && echo "$GH_FAKE_EDIT_STDERR" >&2
      exit "$GH_FAKE_EDIT_EXIT"
    fi
    exit 0
    ;;
  "label create")
    if [[ "${GH_FAKE_CREATE_EXIT:-0}" != 0 ]]; then
      [[ -n "${GH_FAKE_CREATE_STDERR:-}" ]] && echo "$GH_FAKE_CREATE_STDERR" >&2
      exit "$GH_FAKE_CREATE_EXIT"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
chmod +x "$FAKE_BIN_DIR/gh"

export GH_FAKE_LOG
# Only the fake gh dir plus coreutils dirs: even though the real `gh` also
# lives in /usr/bin on most hosts, the fake dir comes first so it always
# wins the lookup and the real binary is never reached.
export PATH="$FAKE_BIN_DIR:/usr/bin:/bin"

reset_log() { : > "$GH_FAKE_LOG"; }
call_count() { grep -c -- "$1" "$GH_FAKE_LOG" || true; }

GH_FAKE_LABELS=""
GH_FAKE_EDIT_EXIT=0
GH_FAKE_EDIT_STDERR=""
GH_FAKE_CREATE_EXIT=0
GH_FAKE_CREATE_STDERR=""
export GH_FAKE_LABELS GH_FAKE_EDIT_EXIT GH_FAKE_EDIT_STDERR GH_FAKE_CREATE_EXIT GH_FAKE_CREATE_STDERR

# shellcheck disable=SC2034  # consumed by label-utils.sh below, not this file
REPO="x/y"
# shellcheck source=/dev/null
source "$LABEL_UTILS"

# -----------------------------------------------------------------------
# Fixture: 31+ labels so the reported regression (a real label sitting past
# a too-low pagination limit) has a concrete position to catch. The 31st
# entry is a real taxonomy label (`Mode:sequential`); a lowercase `bug`
# covers the case-variant assertions.
# -----------------------------------------------------------------------
FIXTURE_LABELS="$(for i in $(seq 1 30); do printf 'filler-label-%02d\n' "$i"; done)
Mode:sequential
bug
enhancement"

echo "1) label::load — exactly one gh label list call, --limit > 30"
label::_invalidate
GH_FAKE_LABELS="$FIXTURE_LABELS"
reset_log
label::load
label::load
n="$(call_count '^gh label list')"
if [[ "$n" -eq 1 ]]; then
  pass "assertion 1: label::load issues exactly one gh label list call (got $n)"
else
  fail "assertion 1: expected exactly one gh label list call, got $n"
fi
list_line="$(grep '^gh label list' "$GH_FAKE_LOG" | head -1)"
limit_val="$(printf '%s\n' "$list_line" | grep -oE -- '--limit [0-9]+' | awk '{print $2}')"
if [[ -n "$limit_val" && "$limit_val" -gt 30 ]]; then
  pass "assertion 1: gh label list carries --limit $limit_val (> 30)"
else
  fail "assertion 1: --limit not > 30 (got '$limit_val') in: $list_line"
fi

echo "2) 31st-position label resolves as present (the reported regression)"
label::_invalidate
GH_FAKE_LABELS="$FIXTURE_LABELS"
if label::exists "Mode:sequential"; then
  pass "assertion 2: 31st-position label 'Mode:sequential' resolves as present"
else
  fail "assertion 2: 31st-position label 'Mode:sequential' did not resolve"
fi

echo "3) exact-casing hit makes no write call"
label::_invalidate
GH_FAKE_LABELS="Bug"
reset_log
label::ensure Bug D73A4A "desc"
n_writes="$(grep -cE '^gh label (create|edit)' "$GH_FAKE_LOG" || true)"
if [[ "$n_writes" -eq 0 ]]; then
  pass "assertion 3: exact-casing hit makes zero gh write calls"
else
  fail "assertion 3: expected 0 writes, got $n_writes: $(cat "$GH_FAKE_LOG")"
fi

echo "4) case-variant hit renames via gh label edit only"
label::_invalidate
GH_FAKE_LABELS="bug"
reset_log
label::ensure Bug D73A4A "desc"
n_edits="$(call_count '^gh label edit')"
edit_line="$(grep '^gh label edit' "$GH_FAKE_LOG" || true)"
if [[ "$n_edits" -eq 1 ]]; then
  pass "assertion 4: exactly one gh label edit call"
else
  fail "assertion 4: expected 1 edit call, got $n_edits"
fi
if [[ "$edit_line" == "gh label edit bug --repo x/y --name Bug" ]]; then
  pass "assertion 4: edit call targets existing casing with canonical --name only"
else
  fail "assertion 4: unexpected edit call: $edit_line"
fi
if [[ "$edit_line" == *"--color"* || "$edit_line" == *"--description"* ]]; then
  fail "assertion 4: edit call should not carry --color/--description: $edit_line"
else
  pass "assertion 4: edit call carries no --color/--description flags"
fi

echo "5) cache miss creates with canonical color/description"
label::_invalidate
GH_FAKE_LABELS=""
reset_log
label::ensure NewLabel ABCDEF "a new label"
create_line="$(grep '^gh label create' "$GH_FAKE_LOG" || true)"
if [[ "$create_line" == "gh label create NewLabel --repo x/y --color ABCDEF --description a new label" ]]; then
  pass "assertion 5: miss creates label with canonical color/description"
else
  fail "assertion 5: unexpected create call: $create_line"
fi

echo "6) create failure surfaces gh stderr and a non-zero return"
label::_invalidate
GH_FAKE_LABELS=""
GH_FAKE_CREATE_EXIT=1
GH_FAKE_CREATE_STDERR="gh: label create failed (mock)"
err="$(label::ensure BrandNew ABCDEF "desc" 2>&1 >/dev/null)"
rc=$?
GH_FAKE_CREATE_EXIT=0
GH_FAKE_CREATE_STDERR=""
if [[ "$rc" -ne 0 ]]; then
  pass "assertion 6: create failure returns non-zero"
else
  fail "assertion 6: expected non-zero return on create failure"
fi
if [[ "$err" == *"gh: label create failed (mock)"* ]]; then
  pass "assertion 6: gh's stderr text reaches the caller"
else
  fail "assertion 6: stderr not forwarded: $err"
fi

echo "7) AUTODUCKS_LABEL_AUTORENAME=0 disables rename"
label::_invalidate
GH_FAKE_LABELS="bug"
reset_log
# shellcheck disable=SC2034  # consumed by label::ensure below, not this file
AUTODUCKS_LABEL_AUTORENAME=0
err="$(label::ensure Bug 2>&1 >/dev/null)"
rc=$?
unset AUTODUCKS_LABEL_AUTORENAME
if [[ "$rc" -ne 0 ]]; then
  pass "assertion 7: non-zero return when autorename disabled"
else
  fail "assertion 7: expected non-zero return"
fi
n_edits="$(call_count '^gh label edit')"
if [[ "$n_edits" -eq 0 ]]; then
  pass "assertion 7: no gh label edit call when autorename disabled"
else
  fail "assertion 7: expected 0 edit calls, got $n_edits"
fi
if [[ -n "$err" ]]; then
  pass "assertion 7: an explanatory message was returned"
else
  fail "assertion 7: expected an explanatory message, got none"
fi

echo "8) label::in_list whole-line, case-insensitive match"
LIST=$'bug\nfeature'
ok=1
label::in_list "$LIST" bug || ok=0
label::in_list "$LIST" BUG || ok=0
label::in_list "$LIST" Bug || ok=0
if label::in_list "$LIST" bugfix; then ok=0; fi
if [[ "$ok" -eq 1 ]]; then
  pass "assertion 8: in_list matches bug/BUG/Bug and rejects bugfix (whole-line, not substring)"
else
  fail "assertion 8: in_list case-insensitive/whole-line matching is broken"
fi

echo "9) second full pass over the same LABELS array performs zero writes"
label::_invalidate
GH_FAKE_LABELS="$FIXTURE_LABELS"
LABELS=(
  "Mode:sequential|5319E7|Sequential execution mode"
  "Bug|D73A4A|Something isn't working"
  "NewFeature|A2EEEF|New feature or request"
)
apply_labels() {
  local entry name color desc
  for entry in "${LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    label::ensure "$name" "$color" "$desc"
  done
}
reset_log
apply_labels
first_pass_writes="$(grep -cE '^gh label (create|edit)' "$GH_FAKE_LOG" || true)"
reset_log
apply_labels
second_pass_writes="$(grep -cE '^gh label (create|edit)' "$GH_FAKE_LOG" || true)"
if [[ "$first_pass_writes" -gt 0 && "$second_pass_writes" -eq 0 ]]; then
  pass "assertion 9: idempotent — first pass wrote $first_pass_writes, second pass wrote 0"
else
  fail "assertion 9: expected writes on pass 1 and none on pass 2 (got $first_pass_writes then $second_pass_writes)"
fi

echo ""
echo "=== label-utils (offline): $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
