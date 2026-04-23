#!/usr/bin/env bash
set -euo pipefail

# Trigger the wave orchestrator to re-evaluate waves after a task merge
# Usage: trigger_loop_closure <feature_issue_number>
trigger_loop_closure() {
  local feature_issue="$1"

  [[ -z "$feature_issue" || "$feature_issue" == "0" ]] && return 0

  git::dispatch_workflow "autoducks-wave.yml" -f "feature_issue=$feature_issue"
}
