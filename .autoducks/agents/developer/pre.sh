#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="developer"

source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"

# Clear stale markers from a previous run on this runner before we could
# leave fresh ones behind (see trap below / post.sh's guard).
rm -f "$AUTODUCKS_PRE_FAILED_MARKER" "$AUTODUCKS_DOR_DELEGATED_MARKER" "$AUTODUCKS_NO_CODE_RESULT"
mkdir -p "$AUTODUCKS_MARKER_DIR"

source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/robustness/wait-for-branch.sh"
source "$AUTODUCKS_ROOT/core/robustness/verify-loop.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

# PR target — what the resulting PR merges into
PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
# Cut-point the task branch is branched from. An explicitly-passed
# BASE_BRANCH (Maestro dispatch) names the feature/fix branch and IS the
# cut-point; when absent, cut from the clean upstream base, not integration.
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

# If base branch is a pipeline branch (feature/ or fix/ — D10), extract the
# parent issue number and inherit the prefix for the task branch.
FEATURE_NUM=$(pipeline_branch_number "$BASE_BRANCH")
TASK_PREFIX=$(branch_prefix_of "$BASE_BRANCH")

# Catch-all: any uncaught non-zero exit below posts a categorized failure
# comment on the task issue (and the parent feature, if any), reacts
# confused, and aborts the progress label; the marker keeps post.sh from
# posting a duplicate comment on the same run.
trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

# ── Definition of Ready (D1): a task needs its pipeline context ──────
# Comment-triggered runs arrive with the default base branch. Resolve the
# parent (feature/bug) issue and its branch; if the branch does not exist
# yet, hand off to the Maestro on the parent — it owns branch + PR creation
# (D7) and will dispatch this task back in wave order.
if [[ -z "$FEATURE_NUM" ]]; then
  # its::get_parent separates "no parent" (exit 0, empty) from "could not ask"
  # (exit 1). Collapsing the two is what made every comment-triggered task run
  # refuse: the old inline `gh api … --jq '.parent.number'` read a field the REST
  # issue payload does not have, so it was unconditionally empty and every task
  # looked like an orphan.
  PARENT_LOOKUP_OK=true
  PARENT_NUM="$(its::get_parent "$ISSUE_NUM")" || PARENT_LOOKUP_OK=false

  if [[ "$PARENT_LOOKUP_OK" != true ]]; then
    status_comment::delegate "$ISSUE_NUM" "Could not determine whether this issue has a parent feature/bug — the issue-tracker query failed, so the run stopped rather than guess. This is **not** a statement about the issue: retry, or dispatch the Developer directly with an explicit \`base_branch\` if you know the parent branch."
    touch "$AUTODUCKS_DOR_DELEGATED_MARKER"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  if [[ -n "$PARENT_NUM" ]]; then
    PARENT_TITLE=$(its::get_issue "$PARENT_NUM" | jq -r '.title')
    PARENT_PREFIX=$(branch_prefix_for_issue "$PARENT_NUM")
    PARENT_BRANCH="$PARENT_PREFIX/$(git::generate_slug "$PARENT_NUM" "$PARENT_TITLE")"
    if git::branch_exists "$PARENT_BRANCH" 2>/dev/null; then
      BASE_BRANCH="$PARENT_BRANCH"
      PR_BASE_BRANCH="$PARENT_BRANCH"
      FEATURE_NUM="$PARENT_NUM"
      TASK_PREFIX="$PARENT_PREFIX"

      # Hand the resolution to post.sh. `export` cannot do this — pre and post
      # are separate GHA steps, hence post.sh's own "reconstruct state from git"
      # block. But that block rebuilds PR_BASE_BRANCH from $BASE_BRANCH, which
      # the workflow injects per-step from steps.ctx.outputs.base_branch: on the
      # comment path that is the default branch, so the task PR was opened
      # against the default branch instead of the feature branch.
      #
      # Writing BASE_BRANCH itself to $GITHUB_ENV would not help — a step-level
      # `env:` entry outranks the job environment, so the workflow's value would
      # win again. Hence a distinct name that no step declares, which post.sh
      # prefers when present.
      if [[ -n "${GITHUB_ENV:-}" ]]; then
        {
          echo "AUTODUCKS_RESOLVED_BASE_BRANCH=$BASE_BRANCH"
          echo "AUTODUCKS_RESOLVED_PR_BASE_BRANCH=$PR_BASE_BRANCH"
          echo "AUTODUCKS_RESOLVED_FEATURE_NUM=$FEATURE_NUM"
        } >> "$GITHUB_ENV"
      fi
    else
      git::dispatch_workflow "autoducks-maestro.yml" \
        -f "feature_issue=$PARENT_NUM" \
        ${COMMENTER:+-f "actor=$COMMENTER"} || true
      status_comment::delegate "$ISSUE_NUM" "The parent branch \`$PARENT_BRANCH\` does not exist yet, so the **Maestro** was dispatched on the parent issue #$PARENT_NUM. It creates the branch and dispatches this task back in wave order."
      touch "$AUTODUCKS_DOR_DELEGATED_MARKER"
      [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
      exit 0
    fi
  else
    # No parent at all: standalone tasks are no longer executed directly
    # (D1) — the pipeline guarantees design + plan first.
    status_comment::delegate "$ISSUE_NUM" "This issue has no parent feature/bug and standalone execution was retired: every issue now goes through the pipeline so a reviewed design and plan exist before code is written.

**Next:** comment \`$(autoducks_command_for execute)\` on the parent issue — or, if this issue *is* the whole work item, run \`$(autoducks_command_for architect) #auto:engineer+execute\` here to design, plan, and execute it."
    touch "$AUTODUCKS_DOR_DELEGATED_MARKER"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi

# Idempotency guard for duplicate dispatches: if any PR (open or merged) into
# this base branch already claims this task, skip quietly. The concurrency
# group serializes same-task runs so this check catches the race.
EXISTING_PR=$(jq -s 'add' \
    <(git::list_open_prs "$BASE_BRANCH") \
    <(git::list_merged_prs "$BASE_BRANCH") \
  | jq -r --arg t "$ISSUE_NUM" \
      '[.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))] | .[0].number // empty')
if [[ -n "$EXISTING_PR" ]]; then
  echo "::notice::Task #$ISSUE_NUM already has PR #$EXISTING_PR (open or merged) — skipping duplicate execution."
  status_comment::finish "$ISSUE_NUM" "Task already has PR #$EXISTING_PR (open or merged) — nothing to do."
  react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "duplicate_skip=true" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Work:coding" "Work:done"

# Wait for the base branch to be visible
if [[ "$BASE_BRANCH" != "$AUTODUCKS_BASE_BRANCH" ]]; then
  wait_for_branch "$BASE_BRANCH"
fi

# Resume an existing task branch (e.g. a max_turns cutoff pushed a `WIP:`
# commit with no PR) instead of orphaning it — task branches carry either
# pipeline prefix (feature/ or fix/, D10), so search both (mirrors
# fix/pre.sh's discovery).
EXISTING_BRANCH=$( { git::find_branches_matching "feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; \
                     git::find_branches_matching "fix/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; } \
                   | sort | tail -1 || true)

git::configure_identity

if [[ -n "$EXISTING_BRANCH" ]]; then
  TASK_BRANCH="$EXISTING_BRANCH"
  echo "::notice::Resuming preserved branch $TASK_BRANCH for task #$ISSUE_NUM instead of cutting a new one."
  status_comment::note "$ISSUE_NUM" "Resuming preserved branch \`$TASK_BRANCH\` from a previous run instead of cutting a new one."
  git checkout "$TASK_BRANCH" 2>/dev/null || git checkout -b "$TASK_BRANCH" "origin/$TASK_BRANCH"
else
  # Task branch name inherits the pipeline prefix (D10)
  TASK_BRANCH="${TASK_PREFIX}/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-$(date +%s)"

  # Create task branch from base
  git fetch origin "$BASE_BRANCH" 2>/dev/null || true
  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git checkout -b "$TASK_BRANCH"
fi

# ── Metarepo: access pre-flight gate + child submodule checkout ─────────
# Runs only in metarepo mode. Probes write access to the task's declared child
# repos with the *same* credential that will push, and — on failure — stops
# before any child branch is cut, escalating to the user (reusing the DoR
# delegate path). Then checks out each declared child onto the mirrored feature
# branch (off the pinned SHA), per HANDOFF, so post.sh can commit onto it.
if metarepo::enabled; then
  source "$AUTODUCKS_ROOT/core/security/metarepo-access-gate.sh"
  CHILD_BRANCH="$PR_BASE_BRANCH"

  ISSUE_BODY_FOR_MODULES="$(its::get_issue "$ISSUE_NUM" | jq -r '.body' 2>/dev/null || true)"
  DECLARED_MODULES=()
  while IFS= read -r _m; do [[ -n "$_m" ]] && DECLARED_MODULES+=("$_m"); done \
    < <(metarepo::modules_from_body "$ISSUE_BODY_FOR_MODULES")

  if ! metarepo::access_gate "${DECLARED_MODULES[@]}"; then
    status_comment::delegate "$ISSUE_NUM" "$(metarepo::gate_escalation_message)"
    touch "$AUTODUCKS_DOR_DELEGATED_MARKER"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "dor_skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
  for _m in "${DECLARED_MODULES[@]:-}"; do
    [[ -n "$_m" && -d "$_m" ]] || continue
    git::submodule_remote "$_m"
    git -C "$_m" fetch origin "$CHILD_BRANCH" 2>/dev/null || true

    # The recorded gitlink is *provisional*: submodule_deliver writes the child
    # feature-branch tip because an async auto-merge cannot report the SHA it
    # will produce, and reconcile_gitlinks only promotes it to the child's
    # default-branch tip later. Branching a new task off that pin is therefore
    # only correct while the pin is still the child's head.
    #
    # Once the child has been delivered and its feature branch deleted, the
    # fetch above finds nothing and `checkout -B` lands on the pin — a commit
    # that predates the delivery merge. New work is then built on a base
    # missing everything that merged with it, and the suite goes red on code
    # that is already correct upstream. Observed on the update-agent task: the
    # branch was recreated at the pre-delivery tip and arrived without two
    # already-merged fixes.
    #
    # So when the pinned SHA is already contained in the child's default branch,
    # start from that branch's tip instead. That is strictly forward — the pin
    # is an ancestor — and it is a no-op mid-feature, when the pin is the head
    # of a live child branch and therefore not yet merged anywhere.
    _base_ref=""
    if ! git -C "$_m" rev-parse --verify -q "origin/$CHILD_BRANCH" >/dev/null 2>&1; then
      _child_default="$(git -C "$_m" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      _child_default="${_child_default:-origin/main}"
      git -C "$_m" fetch -q origin "${_child_default#origin/}" 2>/dev/null || true
      _pinned="$(git -C "$_m" rev-parse HEAD 2>/dev/null || true)"
      if [[ -n "$_pinned" ]] && git -C "$_m" merge-base --is-ancestor "$_pinned" "$_child_default" 2>/dev/null; then
        _base_ref="$_child_default"
        echo "::notice::metarepo: '$_m' pin $(git -C "$_m" rev-parse --short HEAD) is already delivered — branching $CHILD_BRANCH from $_child_default instead of the stale pin." >&2
      fi
    fi

    if [[ -n "$_base_ref" ]]; then
      git -C "$_m" checkout -B "$CHILD_BRANCH" "$_base_ref"
    else
      git -C "$_m" checkout -B "$CHILD_BRANCH" 2>/dev/null \
        || git -C "$_m" checkout -B "$CHILD_BRANCH" HEAD
    fi
  done
  unset _base_ref _child_default _pinned
fi

# Prepare task spec for the LLM. resolve_context reads .context.developer.parts
# from autoducks.json (default manifest: issue_title, issue_description,
# prior_feedback) and writes /tmp/task-spec.md, including the marker-anchored
# check-failure append on a re-dispatched retry (ITERATION > 1, T2/T4) — the
# feedback comment survives the fresh runner post.sh's push dispatched us onto.
source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"
resolve_context "developer" "$ISSUE_NUM"
if metarepo::enabled; then metarepo::agent_context_block >> /tmp/task-spec.md; fi

# Export for post.sh
export TASK_BRANCH BASE_BRANCH PR_BASE_BRANCH FEATURE_NUM
