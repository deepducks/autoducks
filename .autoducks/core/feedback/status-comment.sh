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

_STATUS_ID_FILE="/tmp/autoducks-status-comment-id"

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
    merge)     echo "Merge"     ;;
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
  rm -f "$_STATUS_ID_FILE"
  local label link body out cid
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  body="<img src=\"${AUTODUCKS_STATUS_GIF}\" height=\"32\" valign=\"middle\" alt=\"Running...\" /> **\`${label}\`**: running on ${link}"
  out=$(gh issue comment "$issue_id" --repo "$REPO" --body "$body" 2>/dev/null) || return 0
  # gh prints the comment URL: …/issues/N#issuecomment-<id>
  cid=$(echo "$out" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [[ -n "$cid" ]] && echo "$cid" > "$_STATUS_ID_FILE"
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
  status_comment::_edit "$issue_id" "<img src=\"${AUTODUCKS_STATUS_GIF}\" width=\"24\" alt=\"Running...\" /> **\`${label}\`**: running on ${link}" "$details"
}

# status_comment::_edit ISSUE_NUM HEADLINE [DETAILS]
status_comment::_edit() {
  local issue_id="$1" headline="$2" details="${3:-}"
  local body="$headline"
  [[ -n "$details" ]] && body+=$'\n\n'"$details"
  if [[ -s "$_STATUS_ID_FILE" ]]; then
    local cid
    cid=$(cat "$_STATUS_ID_FILE")
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
status_comment::fail() {
  local issue_id="$1" details="${2:-See the failure report below for diagnosis and next steps.}"
  local label link
  label=$(status_comment::_label)
  link=$(status_comment::_run_link)
  status_comment::_edit "$issue_id" "⚠️ **\`${label}\`**: failed on ${link}" "$details"
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
}
