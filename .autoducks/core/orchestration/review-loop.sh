#!/usr/bin/env bash
set -euo pipefail

# Reviewer request-changes/approve round tracking — three pure functions
# over ITS state. No workflow-local state: the current round lives entirely
# in a single marker-anchored comment on the PR, so any runner on any run
# can recover it (stateless re-run contract, .autoducks/design/AGENTS.md
# §Re-run semantics). Mirrors the marker-scan pattern used by
# orchestrator_comment::upsert (core/feedback/status-comment.sh) and the
# verify-loop feedback comment (agents/developer/post.sh).
#
#   <!-- autoducks:review-loop: feature=<F> pr=<P> iteration=<N> max=<M> -->

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

# review_loop::record FEATURE_NUM PR_NUM N [MAX]
# Persists the new round marker: edits the existing marker comment in place
# when one is found, otherwise posts a fresh one. Idempotent — a re-run in
# the same round finds and edits the same comment rather than duplicating
# it. MAX defaults to the value already on the existing marker, or 3 when
# there is no prior marker to inherit from.
review_loop::record() {
  local feature_num="$1" pr_num="$2" iteration="$3" max="${4:-}"

  local found cid="" body="" prev_max=""
  found=$(_review_loop::find_marker_comment "$feature_num" "$pr_num")
  if [[ -n "$found" ]]; then
    cid=$(cut -f1 <<< "$found")
    body=$(cut -f2- <<< "$found")
    prev_max=$(grep -oE 'max=[0-9]+' <<< "$body" | head -1 | cut -d= -f2)
  fi
  [[ -z "$max" ]] && max="${prev_max:-3}"

  local marker
  marker="<!-- autoducks:review-loop: feature=${feature_num} pr=${pr_num} iteration=${iteration} max=${max} -->"

  if [[ -n "$cid" && "$cid" != "null" ]]; then
    its::update_comment "$cid" "$marker" 2>/dev/null || true
  else
    its::comment_issue "$pr_num" "$marker" >/dev/null 2>&1 || true
  fi
  return 0
}
