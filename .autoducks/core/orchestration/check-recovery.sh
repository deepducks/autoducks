#!/usr/bin/env bash
set -euo pipefail

# ── Missing-required-check recovery decision (#119c) ─────────────────────
# A child delivery PR whose statusCheckRollup is EMPTY is not waiting on a
# pending check — it has no check at all, because the event that should have
# produced the run was dropped. `--auto` can then never fire: autoducks#1121 sat
# MERGEABLE/BLOCKED for 53 minutes with zero runs until a human toggled
# draft→ready by hand.
#
# Split out from the poll loop so the escalation is testable on its own. Pure:
# no I/O, no globals.

# check_recovery::action ZERO_ROUNDS ALREADY_RETRIGGERED RECOVERY_ROUNDS
#   → wait      — still inside the grace window; keep polling
#   → retrigger — re-fire the required check via a draft→ready toggle
#   → fail      — the re-trigger did not help either; report instead of hanging
#                 to the delivery timeout
#
# ALREADY_RETRIGGERED is a non-empty string once the toggle has been applied.
# ZERO_ROUNDS is NOT reset by the toggle, so the post-re-trigger window is twice
# the pre-trigger one (a queued runner took 56s to report in the incident).
check_recovery::action() {
  local zero_rounds="${1:-0}" retriggered="${2:-}" recovery_rounds="${3:-2}"
  [[ "$zero_rounds" =~ ^[0-9]+$ ]] || zero_rounds=0
  [[ "$recovery_rounds" =~ ^[0-9]+$ ]] && (( recovery_rounds >= 1 )) || recovery_rounds=2

  if [[ -z "$retriggered" ]]; then
    (( zero_rounds >= recovery_rounds )) && { echo retrigger; return 0; }
  elif (( zero_rounds >= recovery_rounds * 3 )); then
    echo fail; return 0
  fi
  echo wait
}
