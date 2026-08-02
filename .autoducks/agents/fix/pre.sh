#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"

source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

react_to_comment "$COMMENT_ID" "eyes"
status_comment::start "$ISSUE_NUM"

PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

FEATURE_NUM=$(pipeline_branch_number "$BASE_BRANCH")
TASK_PREFIX=$(branch_prefix_of "$BASE_BRANCH")

# The fix workflow never passes BASE_BRANCH — it is comment-triggered, so both
# assignments above fall back to the configured base/integration branch. That
# left every `/fix` run believing its pipeline branch was the default branch:
# task-branch discovery searched `feature/0-issue-<n>-` and found nothing, and
# in metarepo mode CHILD_BRANCH became `main`, so the run's commits were pushed
# to the child's trunk (rejected by branch protection after a full agent run, or
# silently accepted without it — #182). The Developer resolves this from the
# parent issue; fix has to do the same or it is working on the wrong branch.
if [[ -z "$FEATURE_NUM" ]]; then
  PARENT_LOOKUP_OK=true
  PARENT_NUM="$(its::get_parent "$ISSUE_NUM")" || PARENT_LOOKUP_OK=false

  if [[ "$PARENT_LOOKUP_OK" == true && -n "${PARENT_NUM:-}" ]]; then
    PARENT_TITLE=$(its::get_issue "$PARENT_NUM" | jq -r '.title')
    PARENT_PREFIX=$(branch_prefix_for_issue "$PARENT_NUM")
    PARENT_BRANCH="$PARENT_PREFIX/$(git::generate_slug "$PARENT_NUM" "$PARENT_TITLE")"
    if git::branch_exists "$PARENT_BRANCH" 2>/dev/null; then
      BASE_BRANCH="$PARENT_BRANCH"
      PR_BASE_BRANCH="$PARENT_BRANCH"
      FEATURE_NUM="$PARENT_NUM"
      TASK_PREFIX="$PARENT_PREFIX"
      # pre and post are separate GHA steps and the workflow injects BASE_BRANCH
      # per-step, so a step-level env entry would outrank anything written here
      # under that name. Same distinct-name handoff the Developer uses.
      if [[ -n "${GITHUB_ENV:-}" ]]; then
        {
          echo "AUTODUCKS_RESOLVED_BASE_BRANCH=$BASE_BRANCH"
          echo "AUTODUCKS_RESOLVED_PR_BASE_BRANCH=$PR_BASE_BRANCH"
          echo "AUTODUCKS_RESOLVED_FEATURE_NUM=$FEATURE_NUM"
        } >> "$GITHUB_ENV"
      fi
    fi
  fi
fi

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

# Find the newest existing task branch for this issue — task branches carry
# either pipeline prefix (feature/ or fix/, D10), so search both.
EXISTING_BRANCH=$( { git::find_branches_matching "feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; \
                     git::find_branches_matching "fix/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; } \
                   | sort | tail -1 || true)

if [[ -n "$EXISTING_BRANCH" ]]; then
  TASK_BRANCH="$EXISTING_BRANCH"
  git checkout "$TASK_BRANCH" 2>/dev/null || git checkout -b "$TASK_BRANCH" "origin/$TASK_BRANCH"
else
  TASK_BRANCH="${TASK_PREFIX}/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-fix-$(date +%s)"
  git::configure_identity
  git checkout -b "$TASK_BRANCH"
fi

# ── Metarepo: access pre-flight gate + child submodule checkout ─────────
# Mirrors developer/pre.sh: probe write access to the task's declared children
# with the credential that will push, escalate + bail on failure, then check out
# each declared child onto the mirrored feature branch so fix/post.sh can commit.
if metarepo::enabled; then
  source "$AUTODUCKS_ROOT/core/security/metarepo-access-gate.sh"
  CHILD_BRANCH="$PR_BASE_BRANCH"
  DECLARED_MODULES=()
  while IFS= read -r _m; do [[ -n "$_m" ]] && DECLARED_MODULES+=("$_m"); done \
    < <(metarepo::modules_from_body "$(its::get_issue "$ISSUE_NUM" | jq -r '.body' 2>/dev/null || true)")
  if ! metarepo::access_gate "${DECLARED_MODULES[@]}"; then
    status_comment::delegate "$ISSUE_NUM" "$(metarepo::gate_escalation_message)"
    touch "$AUTODUCKS_PRE_FAILED_MARKER"   # fix/post.sh bails quietly on this marker
    exit 0
  fi
  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
  for _m in "${DECLARED_MODULES[@]:-}"; do
    [[ -n "$_m" && -d "$_m" ]] || continue
    git::submodule_remote "$_m"

    # Precondition, checked before a single token is spent: a run whose commits
    # could only land on the child's trunk cannot persist its output, and the
    # rejection would otherwise arrive at push time, after the full agent run,
    # with nothing checkpointed (#182).
    _default="$(metarepo::child_default_branch "$_m")"
    if [[ "$CHILD_BRANCH" == "$_default" ]]; then
      status_comment::fail "$ISSUE_NUM"
      its::comment_issue "$ISSUE_NUM" "❌ **Cannot start:** the mirrored child branch for this task resolved to \`$_default\`, which is the default branch of \`$_m\`. Committing there is never correct, so the run stopped before doing any work.

This means the task's pipeline branch could not be resolved — usually a task issue with no parent feature, or a feature branch that no longer exists. Re-dispatch the task from its feature, or run \`$(autoducks_command_for fix)\` with an explicit \`base_branch\`."
      react_to_comment "${COMMENT_ID:-}" "confused"
      touch "$AUTODUCKS_PRE_FAILED_MARKER"
      exit 1
    fi

    git -C "$_m" fetch origin "$CHILD_BRANCH" 2>/dev/null || true

    # Same delivered-pin case the Developer handles: once the child has been
    # delivered, its feature branch may be gone and the recorded gitlink points
    # at a commit that predates the delivery merge. Branching from the pin there
    # rebuilds on a base missing everything that merged with it. When the pin is
    # already contained in the child's default branch, start from that tip —
    # strictly forward, and a no-op mid-feature.
    _base_ref=""
    if ! git -C "$_m" rev-parse --verify -q "origin/$CHILD_BRANCH" >/dev/null 2>&1; then
      git -C "$_m" fetch -q origin "$_default" 2>/dev/null || true
      _pinned="$(git -C "$_m" rev-parse HEAD 2>/dev/null || true)"
      if [[ -n "$_pinned" ]] && git -C "$_m" merge-base --is-ancestor "$_pinned" "origin/$_default" 2>/dev/null; then
        _base_ref="origin/$_default"
        echo "::notice::metarepo: '$_m' pin $(git -C "$_m" rev-parse --short HEAD) is already delivered — branching $CHILD_BRANCH from origin/$_default instead of the stale pin." >&2
      fi
    fi

    if [[ -n "$_base_ref" ]]; then
      git -C "$_m" checkout -B "$CHILD_BRANCH" "$_base_ref"
    else
      git -C "$_m" checkout -B "$CHILD_BRANCH" 2>/dev/null || git -C "$_m" checkout -B "$CHILD_BRANCH" HEAD
    fi
  done
  unset _base_ref _default _pinned
fi

# Prepare task spec
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/task-spec.md

# Prepare failure context (recent comments)
its::list_comments "$ISSUE_NUM" 10 | jq -r '.[] | "## " + .author + "\n\n" + .body + "\n\n---\n"' > /tmp/failure-context.md

export TASK_BRANCH BASE_BRANCH PR_BASE_BRANCH FEATURE_NUM EXISTING_BRANCH
