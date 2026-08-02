#!/usr/bin/env bash
set -euo pipefail

# ── Bot-owned status comment ─────────────────────────────────────────
# Every agent run posts ONE status comment owned by the bot and edits it in
# place as the run progresses (Running… → ✅ / ⚠️). The user's triggering
# comment is never edited — reactions (eyes/+1/confused) stay there, and the
# revert agent's "delete bot comments, preserve human content" model survives.
#
# The comment id is persisted to a /tmp marker so pre.sh and post.sh (separate
# GHA steps on the same runner) share it. All functions are best-effort: a
# failed status update must never fail the run.
#
# Env: ISSUE_NUM (arg), REPO, RUN_ID, AUTODUCKS_AGENT

# One id file per target issue/PR, so a single run can own an independent
# status comment on several targets (e.g. the Reviewer mirrors to both the
# feature issue and its PR). Single-target callers are unaffected — they always
# pass the same issue_id, so start writes and finish reads the same file.
STATUS_COMMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./failure-reported.sh
source "$STATUS_COMMENT_DIR/failure-reported.sh"

_status_comment::_id_file() {
  echo "/tmp/autoducks-status-comment-id.${1}"
}

# Hosted in this repo (D3: no third-party hotlinking).
AUTODUCKS_STATUS_GIF="${AUTODUCKS_STATUS_GIF:-https://raw.githubusercontent.com/deepducks/autoducks/main/.autoducks/assets/loading.gif}"

status_comment::_label() {
  case "${AUTODUCKS_AGENT:-}" in
    architect) echo "Architect" ;;
    engineer)  echo "Engineer"  ;;
    maestro)   echo "Maestro"   ;;
    developer) echo "Developer" ;;
    fix)       echo "Fix"       ;;
    revert)    echo "Revert"    ;;
    close)     echo "Close"     ;;
    reviewer)  echo "Reviewer"  ;;
    rework)    echo "Rework"    ;;
    defer)     echo "Defer"     ;;
    merge)     echo "Merge"     ;;
    resolver)  echo "Resolver"  ;;
    *)         echo "${AUTODUCKS_AGENT:-agent}" ;;
  esac
}

status_comment::_run_link() {
  echo "[workflow #${RUN_ID:-?}](https://github.com/${REPO:-}/actions/runs/${RUN_ID:-0})"
}

# status_comment::start ISSUE_NUM
# Posts the Running… status comment and stashes its id for later edits.
status_comment::start() {
  local issue_id="$1"
  local f; f=$(_status_comment::_id_file "$1")
  rm -f "$f"
  local label link body out cid
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  body="<img src=\"${AUTODUCKS_STATUS_GIF}\" height=\"32\" valign=\"middle\" alt=\"Running...\" /> **\`${label}\`**: running on ${link}"
  # Posts directly rather than through its::comment_issue because it needs the
  # returned URL to recover the comment id, so it stamps the marker itself
  # (#183).
  if declare -F comment_marker::stamp >/dev/null 2>&1; then
    body="$(comment_marker::stamp "$body")"
  fi
  out=$(gh issue comment "$issue_id" --repo "$REPO" --body "$body" 2>/dev/null) || return 0
  # gh prints the comment URL: …/issues/N#issuecomment-<id>
  cid=$(echo "$out" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [[ -n "$cid" ]] && echo "$cid" > "$f"
  return 0
}

# status_comment::note ISSUE_NUM DETAILS
# Appends a note to the still-running status comment without changing its
# headline (e.g. resuming a preserved branch instead of cutting a new one).
status_comment::note() {
  local issue_id="$1" details="$2"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "<img src=\"${AUTODUCKS_STATUS_GIF}\" height=\"32\" valign=\"middle\" alt=\"Running...\" /> **\`${label}\`**: running on ${link}" "$details"
}

# status_comment::_edit ISSUE_NUM HEADLINE [DETAILS]
status_comment::_edit() {
  local issue_id="$1" headline="$2" details="${3:-}"
  local body="$headline"
  [[ -n "$details" ]] && body+=$'\n\n'"$details"
  local f; f=$(_status_comment::_id_file "$issue_id")
  if [[ -s "$f" ]]; then
    local cid
    cid=$(cat "$f")
    if its::update_comment "$cid" "$body" 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: no status comment to edit (e.g. event-driven run) — post fresh.
  its::comment_issue "$issue_id" "$body" || true
  return 0
}

# status_comment::finish ISSUE_NUM [DETAILS]
status_comment::finish() {
  local issue_id="$1" details="${2:-}"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "✅ **\`${label}\`**: finished working on ${link}" "$details"
}

# status_comment::fail ISSUE_NUM [DETAILS]
# Reaching here means the run told the issue it failed, on purpose — every
# deliberate-failure path in every post.sh calls this before its `exit 1`. So it
# is also the broadest place to set the "already reported" mark that keeps the
# YAML watchdog quiet (#117).
status_comment::fail() {
  local issue_id="$1" details="${2:-See the failure report below for diagnosis and next steps.}"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "⚠️ **\`${label}\`**: failed on ${link}" "$details"
  feedback::mark_reported
}

# status_comment::cancel ISSUE_NUM [DETAILS]
# Neutral terminal state for a run cancelled mid-flight — no ⚠️/😕, since
# cancellation isn't a failure of the agent's work.
status_comment::cancel() {
  local issue_id="$1" details="${2:-The run was cancelled before it finished.}"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "🚫 **\`${label}\`**: cancelled on ${link}" "$details"
}

# status_comment::delegate ISSUE_NUM [DETAILS]
# Used when a Definition-of-Ready guard hands the run off to a prerequisite
# agent (auto-dispatch cascade) — the run itself did no agent work.
status_comment::delegate() {
  local issue_id="$1" details="${2:-}"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "🔁 **\`${label}\`**: not ready — delegated on ${link}" "$details"

  # Terminal reaction here rather than at the call site, breaking this file's
  # usual separation from reactions on purpose (#180).
  #
  # Every delegation path exits immediately afterwards without doing agent work,
  # so nothing else ever posts one: the trigger comment stays on the 👀 set at
  # dispatch, and everything honouring the documented 👀 → 👍/😕 contract reads
  # the run as still going. On autoducks-staging#12 the Engineer delegated,
  # the Architect ran, the Engineer re-ran and finished — and the watcher was
  # still waiting eight minutes later, because the reaction never moved.
  #
  # There were seven call sites and all seven had forgotten it. Putting it in
  # the one function they share means the eighth cannot.
  #
  # `rocket`, deliberately NOT `+1`.
  #
  # The first version of this fix used `+1` on the reasoning that the 🔁 status
  # comment already says a handoff happened. That was wrong in a way worth
  # recording: whoever reads the reaction is not reading the comment. `+1` means
  # "the agent finished its work", and on this path it has not — the Architect is
  # still running and the Engineer will re-run afterwards. smoke-test-plan.sh
  # immediately proved it, reporting `Feature body unchanged — engineer-agent did
  # not write the plan` against an issue still sitting at `Design:draft`.
  #
  # That traded a hang for a false green, which is the worse failure: a hang gets
  # investigated, a green does not. A handoff is genuinely a third terminal state
  # for this comment — the run is over, the work is not — and it needs its own
  # symbol rather than borrowing one that already means something else.
  if declare -F react_to_comment >/dev/null 2>&1; then
    react_to_comment "${COMMENT_ID:-}" "rocket" 2>/dev/null || true
  fi
}

# ── Persistent orchestrator status comment (survives fresh runners) ─
# The maestro orchestrator dispatches each wave as its own GHA run, so
# there's no shared /tmp across waves the way pre.sh/post.sh share one
# runner above. orchestrator_comment::upsert instead anchors on a hidden
# marker embedded in the comment body itself: any run, on any runner,
# can re-find "the" status comment for a feature by scanning comments
# for that marker. The /tmp cache below is just a same-run optimization
# to skip the re-scan when this run already knows the id.

_MAESTRO_COMMENT_ID_FILE="/tmp/autoducks-maestro-comment-id"

# orchestrator_comment::upsert ISSUE_NUM BODY
#   1. If /tmp cache already holds this run's id, PATCH it.
#   2. Else scan its::list_comments for a bot-authored comment containing the
#      per-feature marker; if found, cache its id and PATCH it.
#   3. Else its::comment_issue a new comment whose body ENDS with the marker;
#      capture the returned comment id into the /tmp cache.
#   All steps best-effort: a failed status update must never fail the run.
orchestrator_comment::upsert() {
  local issue_id="$1" body="$2"
  # Hidden marker embedded in the comment body so future runs (on fresh
  # runners) can find and edit the same comment. Scoped per feature to
  # avoid cross-feature collisions when one issue is reused.
  local marker="<!-- autoducks:maestro-status:${FEATURE:-$issue_id} -->"
  local full_body="${body}"$'\n'"${marker}"
  local cid=""

  if [[ -s "$_MAESTRO_COMMENT_ID_FILE" ]]; then
    cid=$(cat "$_MAESTRO_COMMENT_ID_FILE" 2>/dev/null || true)
    its::update_comment "$cid" "$full_body" 2>/dev/null || true
    return 0
  fi

  local comments=""
  comments=$(its::list_comments "$issue_id" 2>/dev/null) || comments=""

  if [[ -n "$comments" ]]; then
    cid=$(echo "$comments" | jq -r --arg marker "$marker" '
      [.[] | select((.author == "github-actions[bot]" or .author == "github-actions")
                    and ((.body // "") | contains($marker)))]
      | sort_by(.updated_at // .created_at // "")
      | last
      | .id // empty
    ' 2>/dev/null) || cid=""
  fi

  if [[ -n "$cid" && "$cid" != "null" ]]; then
    echo "$cid" > "$_MAESTRO_COMMENT_ID_FILE"
    its::update_comment "$cid" "$full_body" 2>/dev/null || true
    return 0
  fi

  local out="" new_id=""
  out=$(its::comment_issue "$issue_id" "$full_body" 2>/dev/null) || return 0
  # its::comment_issue prints the comment URL: …/issues/N#issuecomment-<id>
  new_id=$(echo "$out" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [[ -n "$new_id" ]] && echo "$new_id" > "$_MAESTRO_COMMENT_ID_FILE"
  return 0
}
