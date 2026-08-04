#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="agent"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Agent:running" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (a refusal, or a genuine
# failure), reacted, and aborted the progress label via its ERR trap or an
# explicit exit — skip all checks so we don't double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

cancellation::handle "$ISSUE_NUM" "Agent:running"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Agent:running"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Agent:running"
  exit 1
fi

# Custom agent finished without honoring its one output contract.
if [[ ! -s /tmp/agent-response.md ]] || [[ -z "$(tr -d '[:space:]' < /tmp/agent-response.md)" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Agent:running"
  exit 1
fi

# ── Attribution: read from the descriptor pre.sh resolved, not env vars —
# pre.sh and post.sh are separate GHA steps/processes, and /tmp/agent-*
# artifacts (unlike $GITHUB_ENV) are guaranteed to reflect exactly what pre.sh
# saw for this run. Env fallbacks only cover a descriptor read failure. ────
DESCRIPTOR_JSON="$(cat /tmp/agent-descriptor.json 2>/dev/null || echo '{}')"
NAME="$(jq -r '.name // empty' <<<"$DESCRIPTOR_JSON")"
[[ -n "$NAME" ]] || NAME="${AUTODUCKS_AGENT_NAME:-agent}"
SOURCE="$(jq -r '.source // empty' <<<"$DESCRIPTOR_JSON")"
[[ -n "$SOURCE" ]] || SOURCE="${AUTODUCKS_AGENT_SOURCE:-unknown}"
TOOLS_SUMMARY="$(jq -r '.tools_effective // [] | join(", ")' <<<"$DESCRIPTOR_JSON")"
[[ -n "$TOOLS_SUMMARY" ]] || TOOLS_SUMMARY="lane defaults"

# ── Delivery: only when the agent actually changed the working tree. A
# custom agent's PR is not a pipeline deliverable, so it references the
# triggering issue (`Ref #N`) and never closes it. A clean tree means the
# agent only produced its response text — no branch, no empty PR. ──────
PR_URL=""
DELIVERY_NOTE=""

# The resolved prompt must never survive into the agent's commit — belt and
# suspenders alongside the repo-root .gitignore entry, since `git add -A`
# below would otherwise pick it up in the degenerate no-snapshot case.
rm -f "$AUTODUCKS_PINNED_ROOT/.autoducks/agents/agent/resolved-prompt.md"

if [[ -n "$(git status --porcelain)" ]]; then
  git::configure_identity

  ISSUE_TITLE="$(its::get_issue "$ISSUE_NUM" | jq -r '.title')"
  AGENT_BRANCH="agent/${NAME}/$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")"
  DEFAULT_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

  # Branch from the base, not from HEAD. On a PR surface HEAD is
  # refs/pull/N/head, so cutting from it would produce an `agent/…` PR against
  # the default branch carrying the contributor's entire unmerged branch on top
  # of the agent's own edits — a diff nobody can review and a merge nobody
  # intended. Carry the working tree across with `checkout --no-overlay`-style
  # semantics: stash the agent's edits, land on the base, restore them.
  #
  # `git stash -u` then `stash pop` is what preserves untracked files the agent
  # created; a plain `checkout -b` from base would leave modified tracked files
  # conflicting with the base version.
  # Replaying the stash onto a different base is a three-way merge, so a
  # conflict is the *expected* case on the very surface this exists for: an
  # agent editing files the PR itself also changed. Every step below is
  # therefore checked. Swallowing them would publish a PR containing conflict
  # markers, or strand the agent's work in a stash that dies with the runner.
  if git::branch_exists "$DEFAULT_BRANCH" 2>/dev/null || git rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
    if ! git stash push -u -m "autoducks-agent-${NAME}" >/dev/null; then
      # Never fall through to `stash pop` here: it would pop whatever unrelated
      # entry happens to sit at stash@{0}.
      echo "::warning::agent post.sh: could not stash the agent's edits; cutting ${AGENT_BRANCH} from HEAD instead." >&2
      DELIVERY_NOTE=$'\n\n'"⚠️ Could not rebase the agent's edits onto \`${DEFAULT_BRANCH}\`, so this branch was cut from the run's HEAD — the pull request may carry unrelated commits."
      git checkout -b "$AGENT_BRANCH"
    else
      git checkout -B "$AGENT_BRANCH" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1 \
        || git checkout -B "$AGENT_BRANCH" "$DEFAULT_BRANCH"
      if ! git stash pop >/dev/null 2>&1; then
        # Refused or conflicted. Either way the tree is not what the agent
        # wrote, so stop before committing anything: discard the half-merged
        # tree and the stash entry, and tell the user plainly that the code
        # changes are gone. Keeping the stash would be pointless — it dies
        # with the runner either way, and naming it in the comment would only
        # promise a recovery that is not possible.
        #
        # The run still exits 0: the agent did answer, and that answer is
        # posted. Only the code delivery failed, and the comment says so.
        git checkout -- . 2>/dev/null || true
        git stash drop >/dev/null 2>&1 || true
        DELIVERY_NOTE=$'\n\n'"⚠️ The agent's edits conflict with \`${DEFAULT_BRANCH}\` and could not be replayed onto it, so no branch or pull request was created. The response above still stands; the code changes were discarded."
        AGENT_BRANCH=""
      fi
    fi
  else
    echo "::warning::agent post.sh: could not resolve base '$DEFAULT_BRANCH'; cutting ${AGENT_BRANCH} from HEAD." >&2
    DELIVERY_NOTE=$'\n\n'"⚠️ Could not resolve base \`${DEFAULT_BRANCH}\`; this branch was cut from the run's HEAD, so the pull request may contain unrelated commits."
    git checkout -b "$AGENT_BRANCH"
  fi
fi

# Deliver only when the rebase above left a usable branch.
if [[ -n "${AGENT_BRANCH:-}" && -n "$(git status --porcelain)" ]]; then
  # A conflicted pop resolves nothing into the index; refuse to commit markers.
  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    # Belt-and-braces: the pop check above should already have caught this.
    # No AUTODUCKS_FAIL_CATEGORY here — nothing downstream reads it on the
    # success path, and the run does succeed: the response is still posted.
    echo "::error::agent post.sh: unmerged paths remain; refusing to commit conflict markers." >&2
    DELIVERY_NOTE=$'\n\n'"⚠️ Unmerged paths remained after replaying the agent's edits; no branch or pull request was created."
    AGENT_BRANCH=""
  fi
fi

if [[ -n "${AGENT_BRANCH:-}" && -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -m "Agent ${NAME}: issue #${ISSUE_NUM}"

  if git::push_branch "$AGENT_BRANCH"; then
    PR_TITLE="Agent ${NAME}: ${ISSUE_TITLE}"
    PR_BODY="Ref #${ISSUE_NUM}

Opened by the custom agent \`${NAME}\` (\`${SOURCE}\`) — not a pipeline deliverable, so this PR is left open for review rather than auto-closing the triggering issue."
    if PR_NUM="$(git::create_pr "$AGENT_BRANCH" "$DEFAULT_BRANCH" "$PR_TITLE" "$PR_BODY")"; then
      PR_URL="https://github.com/${REPO}/pull/${PR_NUM}"
    else
      DELIVERY_NOTE=$'\n\n'"⚠️ Pushed branch \`${AGENT_BRANCH}\`, but opening a pull request against \`${DEFAULT_BRANCH}\` failed — open one manually."
    fi
  else
    DELIVERY_NOTE=$'\n\n'"⚠️ The agent's changes were committed to \`${AGENT_BRANCH}\` locally but could not be pushed — see the run log for details."
  fi
fi

# ── Post the response, prefixed with an attribution header, the PR link
# appended when delivery produced one. GitHub caps a comment body at 65,536
# characters; truncate at 60,000 with an explicit notice and stash the full
# text in the run's step summary so nothing is actually lost. ──────────
RESPONSE="$(cat /tmp/agent-response.md)"
BODY="🤖 **Custom agent \`${NAME}\`** — \`${SOURCE}\`

${RESPONSE}"
[[ -n "$PR_URL" ]] && BODY+=$'\n\n'"**Pull request:** ${PR_URL}"
BODY+="$DELIVERY_NOTE"

if [[ "${#BODY}" -gt 60000 ]]; then
  FULL_BODY="$BODY"
  BODY="${BODY:0:60000}"$'\n\n'"_…truncated at 60,000 characters (GitHub's comment limit is 65,536) — the full response is in this run's step summary._"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Full response from custom agent \`${NAME}\` (truncated in the issue comment)"
      echo
      echo "$FULL_BODY"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

its::comment_issue "$ISSUE_NUM" "$BODY"

react_to_comment "$COMMENT_ID" "+1"
progress_labels::finish "$ISSUE_NUM" "Agent:running" "Agent:done"

status_comment::finish "$ISSUE_NUM" "**\`${NAME}\`** finished — response posted above.

_Ran \`${NAME}\` with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\` · tools: \`${TOOLS_SUMMARY}\`._"
