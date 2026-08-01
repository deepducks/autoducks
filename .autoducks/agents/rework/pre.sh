#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="rework"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

progress_labels::ensure

# skip_rework REASON — used by every non-fatal "nothing to rework" exit
# below. Leaves the run green (no failure notification) while still
# short-circuiting post.sh via the shared marker. Mirrors the reviewer's
# skip_review.
skip_rework() {
  local reason="$1"
  status_comment::finish "$ISSUE_NUM" "**Nothing to rework.** $reason"
  react_to_comment "${COMMENT_ID:-}" "+1"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
}

# ── Resolve the target PR (same resolution the reviewer uses) ──────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  PR_NUM="$ISSUE_NUM"
else
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
  PREFIX=$(branch_prefix_for_issue "$ISSUE_NUM")
  PR_NUM=$(gh pr list --repo "$REPO" --head "$PREFIX/$SLUG" --base "$AUTODUCKS_INTEGRATION_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi

# DoR: a feature PR/branch must exist. No review is required — rework can
# run against raw PR comments/reviews even if `/review` never ran.
if [[ -z "$PR_NUM" ]]; then
  skip_rework "No open pull request was found for this issue. Run \`$(autoducks_command_for execute)\` to implement it first, then re-run \`$(autoducks_command_for rework)\`."
fi

PR_META_JSON=$(git::get_pr "$PR_NUM")
PR_HEAD=$(echo "$PR_META_JSON" | jq -r '.headRefName')
PR_BODY=$(echo "$PR_META_JSON" | jq -r '.body')
PR_STATE=$(echo "$PR_META_JSON" | jq -r '.state')

if [[ "$PR_STATE" != "OPEN" ]]; then
  skip_rework "PR #$PR_NUM is already \`$PR_STATE\`."
fi

# ── Resolve the feature/bug issue this PR implements ───────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  FEATURE_NUM=$(resolve_feature_num_from_pr "$PR_HEAD" "$PR_BODY")
else
  FEATURE_NUM="$ISSUE_NUM"
fi

if [[ -z "$FEATURE_NUM" ]]; then
  skip_rework "Could not resolve the feature/bug issue that PR #$PR_NUM implements."
fi

# ── Idempotency guard: an open rework sub-issue already exists? ────────
# Scan the feature's open sub-issues for one carrying our marker. If found,
# post.sh updates it in place instead of minting a second one.
REWORK_TASK_NUM=""
SUB_ISSUES_JSON=$(its::list_sub_issues "$FEATURE_NUM" 2>/dev/null || echo '[]')
while IFS= read -r num; do
  [[ -z "$num" ]] && continue
  SUB_BODY=$(its::get_issue "$num" 2>/dev/null | jq -r '.body // ""')
  if grep -qF "<!-- autoducks:rework: feature=${FEATURE_NUM} " <<< "$SUB_BODY"; then
    REWORK_TASK_NUM="$num"
    break
  fi
done < <(echo "$SUB_ISSUES_JSON" | jq -r '.[] | select((.state | ascii_downcase) == "open") | .number')

# ── Gather context for the LLM ──────────────────────────────────────────
its::get_issue "$FEATURE_NUM" | jq -r '.title,.body' > /tmp/design-plan.md

REVIEWS_JSON=$(git::list_pr_reviews "$PR_NUM")
PR_COMMENTS_JSON=$(its::list_comments "$PR_NUM")
FEATURE_COMMENTS_JSON=$(its::list_comments "$FEATURE_NUM")

# Through files, never argv. Linux caps a single argument at 128 KiB
# (MAX_ARG_STRLEN), and review bodies are the one input here with no ceiling:
# PR #143 accumulated eight rounds averaging ~20 KiB, ~160 KiB in one argument.
# execve refuses that with `Argument list too long` before jq sees it — and the
# more review rounds a PR needs, the more certain the rework agent is to die on
# it, which is exactly backwards. Same defect as #175 in product/pre.sh.
REVIEWS_FILE="$(mktemp)"; printf '%s' "$REVIEWS_JSON" > "$REVIEWS_FILE"
PR_COMMENTS_FILE="$(mktemp)"; printf '%s' "$PR_COMMENTS_JSON" > "$PR_COMMENTS_FILE"
FEATURE_COMMENTS_FILE="$(mktemp)"; printf '%s' "$FEATURE_COMMENTS_JSON" > "$FEATURE_COMMENTS_FILE"

{
  echo "# Rework context — PR #$PR_NUM / Feature #$FEATURE_NUM"
  echo ""
  jq -n -r \
    --slurpfile reviews_w "$REVIEWS_FILE" \
    --slurpfile prc_w "$PR_COMMENTS_FILE" \
    --slurpfile fc_w "$FEATURE_COMMENTS_FILE" \
    '
    ($reviews_w[0]) as $reviews
    | ($prc_w[0]) as $prc
    | ($fc_w[0]) as $fc
    | ( [ $reviews[] | {
          author, body,
          when: (.submittedAt // .createdAt // ""),
          kind: (if (.state // "") != "" then "PR review" else "PR inline comment" end),
          path: (.path // null), line: (.line // null), state: (.state // null)
        } ]
    + [ $prc[] | { author, body, when: (.created_at // ""), kind: "PR comment", path: null, line: null, state: null } ]
    + [ $fc[]  | { author, body, when: (.created_at // ""), kind: "Feature comment", path: null, line: null, state: null } ]
    )
    | map(select((.body // "") != ""))
    | sort_by(.when) | reverse
    | .[]
    | "## " + .kind + " — " + .author + (if .when != "" then " (" + .when + ")" else "" end) + "\n\n"
      + (if (.state // "") != "" then "**State:** " + .state + "\n\n" else "" end)
      + (if .path != null then "**File:** " + .path + (if .line != null then ":" + (.line|tostring) else "" end) + "\n\n" else "" end)
      + .body + "\n\n---\n"
    '
} > /tmp/rework-context.md

# Metarepo runtime signal. Without it the agent has no way to know it must
# declare the task's `**Modules:**`, and in a metarepo every real code change
# lives in a child — so an untagged rework task is guaranteed to trip the
# developer's drift guard on its first commit (#181). Removed first so a stale
# file from an earlier run on a reused workspace can't fake metarepo mode.
rm -f /tmp/metarepo-context.md
if metarepo::enabled; then
  metarepo::agent_context_block > /tmp/metarepo-context.md
fi

# Decode the steering prompt (free-text prose from the triggering comment,
# base64-encoded by parse-directive.sh) to a stable file. Advisory only —
# never interpolated into a shell command. Same convention as architect/pre.sh.
rm -f /tmp/steering-prompt.md
if [[ -n "${STEERING_PROMPT:-}" ]]; then
  printf '%s' "$STEERING_PROMPT" | base64 -d > /tmp/steering-prompt.md
fi

# Share state with post.sh (separate GHA step — a fresh process).
export PR_NUM PR_HEAD FEATURE_NUM REWORK_TASK_NUM
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
  echo "PR_HEAD=$PR_HEAD" >> "$GITHUB_ENV"
  echo "FEATURE_NUM=$FEATURE_NUM" >> "$GITHUB_ENV"
  echo "REWORK_TASK_NUM=$REWORK_TASK_NUM" >> "$GITHUB_ENV"
fi
