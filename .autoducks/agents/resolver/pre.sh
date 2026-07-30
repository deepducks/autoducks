#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="resolver"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"
source "$AUTODUCKS_ROOT/core/config/label-utils.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Resolve:resolving" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Resolve:resolving" "Resolve:done"

# skip_resolve REASON — used by every non-fatal "nothing to resolve" exit
# below. Leaves the run green (no failure notification) while still
# clearing the in-progress label and short-circuiting post.sh via the
# shared marker.
skip_resolve() {
  local reason="$1"
  status_comment::finish "$ISSUE_NUM" "**Nothing to resolve.** $reason"
  react_to_comment "${COMMENT_ID:-}" "+1"
  progress_labels::abort "$ISSUE_NUM" "Resolve:resolving"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
}

# ── Child-scoped target (metarepo → child delivery PR) ──────────────────
# When the four child_* inputs are set, this run resolves conflicts on a
# CHILD repo's delivery PR under the child credential, instead of a PR in
# $REPO. Design/issue context still comes from the metarepo feature issue
# ($ISSUE_NUM against $REPO) so the reconciliation matches the intent behind
# the work — only the git/gh operations on the PR itself move to the child.
CHILD_SLUG="${CHILD_SLUG:-}"
CHILD_PR_NUMBER="${CHILD_PR_NUMBER:-}"
CHILD_BRANCH="${CHILD_BRANCH:-}"
CHILD_BASE="${CHILD_BASE:-}"

if [[ -n "$CHILD_SLUG" ]]; then
  PR_NUM="$CHILD_PR_NUMBER"
  PR_BASE="$CHILD_BASE"
  PR_HEAD="$CHILD_BRANCH"
  FEATURE_NUM="$ISSUE_NUM"
  CHILD_TOKEN="$(git::resolve_token "$CHILD_SLUG")"

  # ── Defence-in-depth loop guard (child PR, child credential) ───────────
  PR_HEAD_SHA=$(GH_TOKEN="$CHILD_TOKEN" gh pr view "$PR_NUM" --repo "$CHILD_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
  if [[ -n "$PR_HEAD_SHA" ]]; then
    TIP_COMMIT_JSON=$(GH_TOKEN="$CHILD_TOKEN" gh api "repos/$CHILD_SLUG/commits/$PR_HEAD_SHA" 2>/dev/null || echo '{}')
    TIP_AUTHOR_EMAIL=$(echo "$TIP_COMMIT_JSON" | jq -r '.commit.author.email // empty')
    TIP_MESSAGE=$(echo "$TIP_COMMIT_JSON" | jq -r '.commit.message // empty')
    if [[ "$TIP_AUTHOR_EMAIL" == "github-actions[bot]@users.noreply.github.com" ]] \
       && [[ "$TIP_MESSAGE" == "Resolve conflicts on PR #"*"(autoducks)"* ]]; then
      skip_resolve "$CHILD_SLUG PR #$PR_NUM's head commit was already produced by an automated conflict resolution."
    fi
  fi

  # ── Reproduce the conflict on the child, under the child credential ────
  git::configure_identity
  git remote set-url origin "https://x-access-token:${CHILD_TOKEN}@github.com/${CHILD_SLUG}.git"
  git fetch origin "$PR_BASE" "$PR_HEAD"
  git checkout "$PR_HEAD" 2>/dev/null || git checkout -b "$PR_HEAD" "origin/$PR_HEAD"

  if git merge --no-commit --no-ff "origin/$PR_BASE"; then
    git merge --abort 2>/dev/null || true
    skip_resolve "$CHILD_SLUG PR #$PR_NUM merges cleanly."
  fi

  # ── Gather context for the LLM ──────────────────────────────────────────
  git diff --name-only --diff-filter=U > /tmp/conflicted-files.txt

  rm -rf /tmp/conflicts
  mkdir -p /tmp/conflicts
  : > /tmp/conflict-context.md
  {
    echo "# Conflict context for $CHILD_SLUG PR #$PR_NUM"
    echo ""
    echo "## Tip commit messages"
    echo ""
    echo "### Ours — $PR_HEAD"
    echo ""
    git log -1 --format=%B HEAD
    echo ""
    echo "### Theirs — $PR_BASE"
    echo ""
    git log -1 --format=%B "origin/$PR_BASE"
    echo ""
    echo "## Conflicted files"
  } >> /tmp/conflict-context.md

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    mkdir -p "/tmp/conflicts/$(dirname "$f")"
    cp "$f" "/tmp/conflicts/$f"

    {
      echo ""
      echo "### $f"
      echo ""
      echo "**Ours (:2:)**"
      echo ""
      echo '```'
      git show ":2:$f" 2>/dev/null || echo "(deleted on our side)"
      echo '```'
      echo ""
      echo "**Theirs (:3:)**"
      echo ""
      echo '```'
      git show ":3:$f" 2>/dev/null || echo "(deleted on their side)"
      echo '```'
    } >> /tmp/conflict-context.md
  done < /tmp/conflicted-files.txt

  # Design context comes from the metarepo feature issue ($REPO, metarepo
  # token) — never the child — so the reconciliation matches the intent
  # behind the work that produced this delivery PR.
  its::get_issue "$FEATURE_NUM" | jq -r '.title,.body' > /tmp/design-plan.md

  : > /tmp/task-criteria.md
  FEATURE_BODY=$(its::get_issue "$FEATURE_NUM" | jq -r '.body')
  if PARSED=$(parse_waves "$FEATURE_BODY" 2>/dev/null); then
    TASK_NUMS=$(echo "$PARSED" | awk -F'|' '$1 == "TASK" {print $3}' | sort -un)
    for t in $TASK_NUMS; do
      its::get_issue "$t" 2>/dev/null \
        | jq -r --arg n "$t" '"## Task #" + $n + " — " + .title + "\n\n" + .body + "\n\n---\n"' \
        >> /tmp/task-criteria.md || true
    done
  fi

  {
    echo "# $CHILD_SLUG PR #$PR_NUM"
    echo ""
    echo "- Base: $PR_BASE"
    echo "- Head: $PR_HEAD"
    echo ""
    echo "## Conflicted files"
    echo ""
    sed 's/^/- /' /tmp/conflicted-files.txt
  } > /tmp/pr-meta.md

  # Share PR state with post.sh (separate GHA step — a fresh process). The
  # child credential is re-resolved there from CHILD_SLUG rather than passed
  # across steps.
  export PR_NUM PR_BASE PR_HEAD FEATURE_NUM
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
    echo "PR_BASE=$PR_BASE" >> "$GITHUB_ENV"
    echo "PR_HEAD=$PR_HEAD" >> "$GITHUB_ENV"
    echo "FEATURE_NUM=${FEATURE_NUM:-}" >> "$GITHUB_ENV"
  fi
else

# ── Resolve the target PR ──────────────────────────────────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  PR_NUM="$ISSUE_NUM"
else
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
  PREFIX=$(branch_prefix_for_issue "$ISSUE_NUM")
  PR_NUM=$(gh pr list --repo "$REPO" --head "$PREFIX/$SLUG" --base "$AUTODUCKS_INTEGRATION_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi

if [[ -z "$PR_NUM" ]]; then
  skip_resolve "No open pull request was found for this issue. Run \`$(autoducks_command_for execute)\` to implement it first."
fi

PR_META_JSON=$(git::get_pr "$PR_NUM")
PR_BASE=$(echo "$PR_META_JSON" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_META_JSON" | jq -r '.headRefName')
PR_TITLE=$(echo "$PR_META_JSON" | jq -r '.title')
PR_BODY=$(echo "$PR_META_JSON" | jq -r '.body')
PR_STATE=$(echo "$PR_META_JSON" | jq -r '.state')
PR_IS_DRAFT=$(echo "$PR_META_JSON" | jq -r '.isDraft')

# ── Defence-in-depth loop guard ─────────────────────────────────────────
# The resolver pushes its own commits to the PR head, which (on the
# automatic path) re-fires the `synchronize` event that triggered it in the
# first place. If the head tip is already an autoducks resolution commit,
# there is nothing new to resolve — stop here rather than looping.
PR_HEAD_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [[ -n "$PR_HEAD_SHA" ]]; then
  TIP_COMMIT_JSON=$(gh api "repos/$REPO/commits/$PR_HEAD_SHA" 2>/dev/null || echo '{}')
  TIP_AUTHOR_EMAIL=$(echo "$TIP_COMMIT_JSON" | jq -r '.commit.author.email // empty')
  TIP_MESSAGE=$(echo "$TIP_COMMIT_JSON" | jq -r '.commit.message // empty')
  if [[ "$TIP_AUTHOR_EMAIL" == "github-actions[bot]@users.noreply.github.com" ]] \
     && [[ "$TIP_MESSAGE" == "Resolve conflicts on PR #"*"(autoducks)"* ]]; then
    skip_resolve "PR #$PR_NUM's head commit was already produced by an automated conflict resolution."
  fi
fi

# ── Opt-out gates (automatic path only) ─────────────────────────────────
# `/resolve` is a deliberate human action and ignores both — only the
# `pull_request: synchronize` auto-trigger honors them.
IS_AUTOMATIC=false
if [[ "${EVENT_NAME:-}" == "pull_request" && "${ACTION:-}" == "synchronize" ]]; then
  IS_AUTOMATIC=true
fi

if [[ "$IS_AUTOMATIC" == "true" ]]; then
  RESOLVER_AUTO=$(jq -r 'if .resolver.auto == null then true else .resolver.auto end' "$AUTODUCKS_ROOT/autoducks.json")
  if [[ "$RESOLVER_AUTO" == "false" ]]; then
    skip_resolve "Automatic conflict resolution is disabled (\`resolver.auto\` is \`false\`)."
  fi

  OPT_OUT_LABEL=$(jq -r '.resolver.opt_out_label // "Resolve:off"' "$AUTODUCKS_ROOT/autoducks.json")
  pr_labels=$(gh pr view "$PR_NUM" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null)
  if label::in_list "$pr_labels" "$OPT_OUT_LABEL"; then
    skip_resolve "PR #$PR_NUM carries the \`$OPT_OUT_LABEL\` opt-out label."
  fi
fi

# ── Mergeability pre-check ───────────────────────────────────────────────
# GitHub computes `mergeable` asynchronously, so poll with backoff (à la
# core/robustness/wait-for-branch.sh) until it settles. A persistent
# `UNKNOWN` falls through to the actual `git merge` probe below rather than
# blocking the run.
resolver_wait_for_mergeable() {
  local pr_number="$1"
  local max_attempts="${2:-10}"
  local sleep_seconds="${3:-3}"
  local mergeable

  for ((i=1; i<=max_attempts; i++)); do
    mergeable=$(git::get_pr "$pr_number" | jq -r '.mergeable')
    case "$mergeable" in
      MERGEABLE|CONFLICTING) echo "$mergeable"; return 0 ;;
    esac
    echo "Waiting for PR #$pr_number mergeability to resolve (attempt $i/$max_attempts, currently ${mergeable:-UNKNOWN})..." >&2
    sleep "$sleep_seconds"
  done

  echo "UNKNOWN"
}

MERGEABLE_STATE=$(resolver_wait_for_mergeable "$PR_NUM")

if [[ "$IS_AUTOMATIC" == "true" ]]; then
  if [[ "$MERGEABLE_STATE" == "MERGEABLE" ]]; then
    skip_resolve "PR #$PR_NUM has no merge conflicts."
  fi
  if [[ "$PR_STATE" != "OPEN" ]]; then
    skip_resolve "PR #$PR_NUM is already \`$PR_STATE\`."
  fi
  if [[ "$PR_IS_DRAFT" == "true" ]]; then
    skip_resolve "PR #$PR_NUM is a draft."
  fi
fi

# ── Reproduce the conflict ──────────────────────────────────────────────
git::configure_identity
git fetch origin "$PR_BASE" "$PR_HEAD"
git checkout "$PR_HEAD" 2>/dev/null || git checkout -b "$PR_HEAD" "origin/$PR_HEAD"

if git merge --no-commit --no-ff "origin/$PR_BASE"; then
  git merge --abort 2>/dev/null || true
  skip_resolve "PR #$PR_NUM merges cleanly."
fi

# ── Resolve the feature/bug issue this PR implements ────────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  FEATURE_NUM=$(resolve_feature_num_from_pr "$PR_HEAD" "$PR_BODY")
else
  FEATURE_NUM="$ISSUE_NUM"
fi

# ── Gather context for the LLM ──────────────────────────────────────────
git diff --name-only --diff-filter=U > /tmp/conflicted-files.txt

rm -rf /tmp/conflicts
mkdir -p /tmp/conflicts
: > /tmp/conflict-context.md
{
  echo "# Conflict context for PR #$PR_NUM"
  echo ""
  echo "## Tip commit messages"
  echo ""
  echo "### Ours — $PR_HEAD"
  echo ""
  git log -1 --format=%B HEAD
  echo ""
  echo "### Theirs — $PR_BASE"
  echo ""
  git log -1 --format=%B "origin/$PR_BASE"
  echo ""
  echo "## Conflicted files"
} >> /tmp/conflict-context.md

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  mkdir -p "/tmp/conflicts/$(dirname "$f")"
  cp "$f" "/tmp/conflicts/$f"

  {
    echo ""
    echo "### $f"
    echo ""
    echo "**Ours (:2:)**"
    echo ""
    echo '```'
    git show ":2:$f" 2>/dev/null || echo "(deleted on our side)"
    echo '```'
    echo ""
    echo "**Theirs (:3:)**"
    echo ""
    echo '```'
    git show ":3:$f" 2>/dev/null || echo "(deleted on their side)"
    echo '```'
  } >> /tmp/conflict-context.md
done < /tmp/conflicted-files.txt

its::get_issue "$FEATURE_NUM" | jq -r '.title,.body' > /tmp/design-plan.md

# Task acceptance criteria: best-effort — a feature body without a `waves:`
# block (e.g. the single-task fast path) simply yields an empty file.
: > /tmp/task-criteria.md
FEATURE_BODY=$(its::get_issue "$FEATURE_NUM" | jq -r '.body')
if PARSED=$(parse_waves "$FEATURE_BODY" 2>/dev/null); then
  TASK_NUMS=$(echo "$PARSED" | awk -F'|' '$1 == "TASK" {print $3}' | sort -un)
  for t in $TASK_NUMS; do
    its::get_issue "$t" 2>/dev/null \
      | jq -r --arg n "$t" '"## Task #" + $n + " — " + .title + "\n\n" + .body + "\n\n---\n"' \
      >> /tmp/task-criteria.md || true
  done
fi

{
  echo "# PR #$PR_NUM: $PR_TITLE"
  echo ""
  echo "- Base: $PR_BASE"
  echo "- Head: $PR_HEAD"
  echo "- State: $PR_STATE"
  echo ""
  echo "## Conflicted files"
  echo ""
  sed 's/^/- /' /tmp/conflicted-files.txt
} > /tmp/pr-meta.md

# Share PR state with post.sh (separate GHA step — a fresh process).
export PR_NUM PR_BASE PR_HEAD FEATURE_NUM
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
  echo "PR_BASE=$PR_BASE" >> "$GITHUB_ENV"
  echo "PR_HEAD=$PR_HEAD" >> "$GITHUB_ENV"
  echo "FEATURE_NUM=${FEATURE_NUM:-}" >> "$GITHUB_ENV"
fi
fi
