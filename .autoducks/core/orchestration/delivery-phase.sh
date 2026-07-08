#!/usr/bin/env bash
[[ -n "${_DELIVERY_PHASE_SH_LOADED:-}" ]] && return 0
readonly _DELIVERY_PHASE_SH_LOADED=1

# delivery_phase::started ISSUE_NUM [ISSUE_LABELS]
#
# Returns 0 when the delivery/execution phase has begun for a feature/bug
# issue, 1 otherwise. "Started" means the Maestro has taken irreversible
# orchestration action that a design/plan re-run could corrupt.
#
# Two durable signals, OR-ed:
#   1. A Work:* stage label (orchestrating | coding | done) is present.
#   2. A pipeline branch feature/<N>-… or fix/<N>-… exists on the remote.
#      This survives a mid-run Maestro failure that aborts the Work:*
#      label off the issue (progress_labels::abort), so it is the
#      authoritative signal; the label check is the cheap fast path.
#
# ISSUE_LABELS (optional) is the newline-separated label list already in
# hand at the call site, to save a redundant its::get_issue round-trip.
delivery_phase::started() {
  local issue="$1"
  local labels="${2:-}"

  if [[ -n "$labels" ]] \
     && echo "$labels" | grep -qE '^Work:(orchestrating|coding|done)$'; then
    return 0
  fi

  local prefix
  for prefix in feature fix; do
    if [[ -n "$(git::find_branches_matching "${prefix}/${issue}-")" ]]; then
      return 0
    fi
  done

  return 1
}
