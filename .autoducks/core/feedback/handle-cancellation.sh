#!/usr/bin/env bash
# Shared cancellation choke point for every agent's post.sh. A workflow-level
# cancellation (user cancels the run, or a newer run supersedes it) is not a
# failure: no notify_failure, no failure comment, no 😕 reaction — just a
# neutral status and clean teardown of in-flight state.
#
# Assumes the caller has already sourced status-comment.sh, progress-labels.sh,
# and the git provider (for git::conclude_check_run) — not re-sourced here to
# match the existing feedback-module convention.

# cancellation::handle ISSUE_NUM IN_PROGRESS_LABEL [CHECK_RUN_ID]
# No-ops (returns 0) unless JOB_STATUS=="cancelled". On the cancelled path:
# neutral status comment, in-progress label cleared (skipped when
# IN_PROGRESS_LABEL is empty), Check-run concluded `cancelled` (only when
# CHECK_RUN_ID is non-empty), then exit 0 — the job's only conclusion is
# `cancelled`.
cancellation::handle() {
  local issue_id="$1" in_progress_label="$2" check_run_id="${3:-}"

  [[ "${JOB_STATUS:-}" == "cancelled" ]] || return 0

  status_comment::cancel "$issue_id" 2>/dev/null || true

  [[ -n "$in_progress_label" ]] && { progress_labels::abort "$issue_id" "$in_progress_label" 2>/dev/null || true; }

  if [[ -n "$check_run_id" ]]; then
    git::conclude_check_run "$check_run_id" cancelled "Run cancelled" "The run was cancelled before it finished." 2>/dev/null || true
  fi

  exit 0
}
