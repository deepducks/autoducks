#!/usr/bin/env bash
set -euo pipefail

# Reviewer request-changes/approve round tracking — pure functions over ITS
# state. No workflow-local state: the current round lives entirely in a
# single marker-anchored comment on the PR, so any runner on any run can
# recover it (stateless re-run contract, .autoducks/design/AGENTS.md §Re-run
# semantics). Mirrors the marker-scan pattern used by
# orchestrator_comment::upsert (core/feedback/status-comment.sh) and the
# verify-loop feedback comment (agents/developer/post.sh).
#
#   <!-- autoducks:review-loop: feature=<F> pr=<P> iteration=<N> max=<M> sha=<S> -->
#
# `sha` (optional) is the PR head commit the marker's round was recorded
# against — it lets a caller tell a genuinely new round apart from a
# duplicate/re-triggered review of a commit already accounted for, without
# any state beyond this one comment (Idempotency constraint).

# _review_loop::marker_prefix FEATURE_NUM PR_NUM
# The feature+pr-scoped portion of the marker, used both to build the full
# marker and to grep for an existing one.
_review_loop::marker_prefix() {
  local feature_num="$1" pr_num="$2"
  echo "<!-- autoducks:review-loop: feature=${feature_num} pr=${pr_num} "
}

# _review_loop::find_marker_comment FEATURE_NUM PR_NUM
# Echoes "<comment_id>\t<body>" for the newest comment on the PR carrying
# this feature/PR's marker, or nothing if none exists.
_review_loop::find_marker_comment() {
  local feature_num="$1" pr_num="$2"
  local prefix
  prefix=$(_review_loop::marker_prefix "$feature_num" "$pr_num")

  local comments
  comments=$(its::list_comments "$pr_num" 2>/dev/null) || return 0
  [[ -z "$comments" ]] && return 0

  echo "$comments" | jq -r --arg prefix "$prefix" '
    [.[] | select((.body // "") | contains($prefix))]
    | sort_by(.updated_at // .created_at // "")
    | last
    | select(. != null)
    | [(.id | tostring), .body] | @tsv
  ' 2>/dev/null
}

# review_loop::iteration FEATURE_NUM PR_NUM → echoes current round N (0 if none)
review_loop::iteration() {
  local feature_num="$1" pr_num="$2"
  local found
  found=$(_review_loop::find_marker_comment "$feature_num" "$pr_num")
  if [[ -z "$found" ]]; then
    echo 0
    return 0
  fi

  local body n
  body=$(cut -f2- <<< "$found")
  n=$(grep -oE 'iteration=[0-9]+' <<< "$body" | head -1 | cut -d= -f2)
  echo "${n:-0}"
}

# review_loop::sha FEATURE_NUM PR_NUM → echoes the PR head SHA the current
# marker was recorded against (empty if there is no marker, or it predates
# sha tracking).
review_loop::sha() {
  local feature_num="$1" pr_num="$2"
  local found
  found=$(_review_loop::find_marker_comment "$feature_num" "$pr_num")
  [[ -z "$found" ]] && { echo ""; return 0; }

  local body s
  body=$(cut -f2- <<< "$found")
  s=$(grep -oE 'sha=[^ ]+' <<< "$body" | head -1 | cut -d= -f2)
  echo "${s:-}"
}

# review_loop::decide VERDICT ITERATION MAX → continue | stop-approved | stop-blocked-max
# request-changes with rounds left → continue; request-changes at/over the
# cap → stop-blocked-max; anything else (approve, comment, or a garbage
# verdict) is treated as non-blocking → stop-approved.
review_loop::decide() {
  local verdict="$1" iteration="$2" max="$3"

  if [[ "$verdict" == "request-changes" ]]; then
    if [[ "$iteration" -lt "$max" ]]; then
      echo "continue"
    else
      echo "stop-blocked-max"
    fi
  else
    echo "stop-approved"
  fi
}

# review_loop::record FEATURE_NUM PR_NUM N [MAX] [SHA]
# Persists the new round marker: edits the existing marker comment in place
# when one is found, otherwise posts a fresh one. Idempotent — a re-run in
# the same round finds and edits the same comment rather than duplicating
# it. MAX defaults to the value already on the existing marker, or 3 when
# there is no prior marker to inherit from. SHA (optional) is the PR head
# commit this round was recorded for; omitted/empty drops the `sha` field
# from the marker rather than writing it empty.
# review_loop::rework_inflight FEATURE_NUM — true (exit 0) if an open rework
# sub-issue already tracks FEATURE_NUM (mirrors the idempotency scan in
# agents/rework/pre.sh). Used as a SHA-less signal that a round has already
# been dispatched: the rework agent only files/updates this sub-issue once a
# round has actually kicked off.
review_loop::rework_inflight() {
  local feature_num="$1"
  local sub_issues num body
  sub_issues=$(its::list_sub_issues "$feature_num" 2>/dev/null) || return 1
  [[ -z "$sub_issues" ]] && return 1

  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    body=$(its::get_issue "$num" 2>/dev/null | jq -r '.body // ""')
    grep -qF "<!-- autoducks:rework: feature=${feature_num} " <<< "$body" && return 0
  done < <(echo "$sub_issues" | jq -r '.[] | select((.state | ascii_downcase) == "open") | .number')

  return 1
}

# review_loop::already_dispatched FEATURE_NUM PR_NUM ITERATION — true (exit 0)
# when there's no PR_HEAD_SHA to compare against (the sha-based guard in
# post.sh): falls back to two SHA-less signals for "this round is already
# dispatched" — a fresh re-read of the marker already at/past the round this
# call is about to record, or an in-flight open rework sub-issue.
review_loop::already_dispatched() {
  local feature_num="$1" pr_num="$2" iteration="$3"
  local fresh
  fresh=$(review_loop::iteration "$feature_num" "$pr_num")
  [[ "$fresh" -ge $((iteration + 1)) ]] && return 0
  review_loop::rework_inflight "$feature_num" && return 0
  return 1
}

review_loop::record() {
  local feature_num="$1" pr_num="$2" iteration="$3" max="${4:-}" sha="${5:-}"

  local found cid="" body="" prev_max=""
  found=$(_review_loop::find_marker_comment "$feature_num" "$pr_num")
  if [[ -n "$found" ]]; then
    cid=$(cut -f1 <<< "$found")
    body=$(cut -f2- <<< "$found")
    prev_max=$(grep -oE 'max=[0-9]+' <<< "$body" | head -1 | cut -d= -f2)
  fi
  [[ -z "$max" ]] && max="${prev_max:-3}"

  local sha_field=""
  [[ -n "$sha" ]] && sha_field=" sha=${sha}"

  local marker
  marker="<!-- autoducks:review-loop: feature=${feature_num} pr=${pr_num} iteration=${iteration} max=${max}${sha_field} -->"

  if [[ -n "$cid" && "$cid" != "null" ]]; then
    its::update_comment "$cid" "$marker" 2>/dev/null || true
  else
    its::comment_issue "$pr_num" "$marker" >/dev/null 2>&1 || true
  fi
  return 0
}
