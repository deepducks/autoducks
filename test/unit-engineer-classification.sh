#!/usr/bin/env bash
# Regression test: the Engineer's post.sh no longer performs any
# classification (D10 was removed — classification is now exclusively the
# Architect's job, gated by the Engineer's DoR guard in pre.sh, see
# test/unit-engineer-dor.sh).
#
# Runs the real post.sh as a subprocess (gh shimmed out, same technique as
# test/unit-idempotency.sh) through a single-task tactical plan, asserting
# that regardless of the mocked issue's native `.type` or labels, post.sh
# never calls `its::set_issue_type` or `its::add_label Feature`/`Bug`.
#
# Run: bash test/unit-engineer-classification.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

MARKER_RUN_ID="engineer-classification"
REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
MOCK_ISSUE_DIR="$SCRATCH/issues"
mkdir -p "$MOCK_ISSUE_DIR" "$SCRATCH/bin"

# ── gh shim ───────────────────────────────────────────────────────────
# its::get_issue combines a `gh issue view --jq '{title, body, labels,
# author}'` call with a `gh api repos/.../issues/N --jq '.type.name // ""'`
# call — both already end in the post-jq shape the real gh CLI would
# produce, so the shim can just emit that shape directly. MOCK_NATIVE_TYPE
# controls what the native-type lookup returns (empty = untyped).
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"

case "$1" in
  issue)
    case "$2" in
      view)
        id="$3"
        if [[ -f "$MOCK_ISSUE_DIR/$id.json" ]]; then
          cat "$MOCK_ISSUE_DIR/$id.json"
        else
          echo '{}'
        fi
        ;;
      comment)
        echo "https://github.com/x/y/issues/$3#issuecomment-777"
        ;;
      *) : ;;
    esac
    ;;
  label) : ;;
  api)
    method="GET"; path=""; has_jq=false; prevflag=""
    for arg in "${@:2}"; do
      if [[ "$prevflag" == "--method" ]]; then method="$arg"; prevflag=""; continue; fi
      if [[ "$prevflag" == "--jq" ]]; then has_jq=true; prevflag=""; continue; fi
      if [[ "$prevflag" == "-f" ]]; then prevflag=""; continue; fi
      case "$arg" in
        --method) prevflag="--method"; continue ;;
        --jq)     prevflag="--jq"; continue ;;
        -f)       prevflag="-f"; continue ;;
        --*)      continue ;;
        *)        [[ -z "$path" ]] && path="$arg" ;;
      esac
    done
    if [[ "$method" == "GET" && "$path" == repos/*/issues/[0-9]* && "$has_jq" == true ]]; then
      echo "${MOCK_NATIVE_TYPE:-}"
    fi
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

ENGINEER_POST="$REPO_ROOT/.autoducks/agents/engineer/post.sh"

# run_classification_case <issue_num> <labels_json> <native_type>
run_classification_case() {
  local issue="$1" labels_json="$2" native_type="$3"

  jq -n --argjson labels "$labels_json" \
    '{title: "Add search", body: "designed body", labels: $labels, author: "alice"}' \
    > "$MOCK_ISSUE_DIR/$issue.json"

  rm -rf "$SCRATCH/autoducks-$MARKER_RUN_ID"
  rm -f /tmp/tactical-body.md /tmp/tasks.jsonl /tmp/parse-error.md /tmp/link-outcomes.tsv \
        /tmp/autoducks-status-comment-id."$issue"
  : > /tmp/design-zone.md
  rm -f /tmp/issue-body-raw.md

  cat > /tmp/tactical-body.md <<'EOF'
## Tasks

### 201 — Task A

**Summary:** Do the thing.

**Tasks:**
- [ ] step one

**Acceptance Criteria:**
- [ ] criterion one
EOF

  : > "$GH_LOG"
  RC=0
  env \
    PATH="$SCRATCH/bin:$PATH" \
    RUNNER_TEMP="$SCRATCH" \
    GITHUB_RUN_ID="$MARKER_RUN_ID" \
    GH_LOG="$GH_LOG" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    MOCK_NATIVE_TYPE="$native_type" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    ISSUE_NUM="$issue" RUN_ID=1 COMMENT_ID=1 COMMENTER=alice COMMAND=engineer \
    bash "$ENGINEER_POST" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || RC=$?

  [[ "$RC" -eq 0 ]] || fail "post.sh exited $RC for #$issue: $(tail -5 "$SCRATCH/stderr.log")"
}

assert_no_classification() {
  local desc="$1"
  if grep -q -- '--method PATCH' "$GH_LOG" && grep -q 'type=' "$GH_LOG"; then
    fail "its::set_issue_type was called ($desc): $(grep -- '--method PATCH' "$GH_LOG")"
  else
    pass "its::set_issue_type never called ($desc)"
  fi
  if grep -qE -- '--add-label (Feature|Bug)' "$GH_LOG"; then
    fail "its::add_label Feature/Bug was called ($desc): $(grep -- '--add-label' "$GH_LOG")"
  else
    pass "its::add_label Feature/Bug never called ($desc)"
  fi
}

echo "── native type Bug, no Bug label: post.sh never classifies ──"
run_classification_case 301 '[]' "Bug"
assert_no_classification "native Bug"

echo ""
echo "── Bug label present (no native type): post.sh never classifies ──"
run_classification_case 302 '["Bug"]' ""
assert_no_classification "Bug-labeled"

echo ""
echo "── no bug signal (native type Feature, no Bug label): post.sh never classifies ──"
run_classification_case 303 '[]' "Feature"
assert_no_classification "native Feature"

echo ""
echo "── no bug signal (untyped, no Bug label): post.sh never classifies ──"
run_classification_case 304 '[]' ""
assert_no_classification "untyped"

rm -f /tmp/design-zone.md /tmp/issue-body-raw.md /tmp/tactical-body.md /tmp/tasks.jsonl \
      /tmp/parse-error.md /tmp/link-outcomes.tsv \
      /tmp/autoducks-status-comment-id.301 /tmp/autoducks-status-comment-id.302 \
      /tmp/autoducks-status-comment-id.303 /tmp/autoducks-status-comment-id.304

echo ""
echo "═══ engineer-classification: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
