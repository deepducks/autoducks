#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATOR_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$ORCHESTRATOR_MODE_DIR/../config/label-utils.sh"

# orchestrator_mode::resolve FEATURE_ISSUE → echoes "waves" | "sequential"
#
# Precedence: OVERRIDE_MODE (directive/input) > Mode:* label > config default.
# When an override is supplied, it is persisted as a Mode:* label on the issue
# so the Maestro's event-driven re-runs (which carry no directive) stay
# consistent for the whole feature lifecycle.
orchestrator_mode::resolve() {
  local issue="$1" chosen=""

  # 1. Per-command override → resolve AND persist.
  case "${OVERRIDE_MODE:-}" in
    waves|sequential)
      chosen="$OVERRIDE_MODE"
      orchestrator_mode::_persist "$issue" "$chosen"
      echo "$chosen"; return 0 ;;
  esac

  # 2. Persisted label.
  local labels
  labels=$(its::get_issue "$issue" | jq -r '.labels[] // empty' 2>/dev/null || true)
  if label::in_list "$labels" Mode:sequential; then echo "sequential"; return 0; fi
  if label::in_list "$labels" Mode:waves;      then echo "waves";      return 0; fi

  # 3. Config default (already validated by load-config).
  echo "${AUTODUCKS_ORCHESTRATOR_MODE:-waves}"
}

# Swap in the chosen Mode:* label, removing the other. Idempotent.
orchestrator_mode::_persist() {
  local issue="$1" mode="$2" other
  other=$([[ "$mode" == "waves" ]] && echo "Mode:sequential" || echo "Mode:waves")
  its::remove_label "$issue" "$other" 2>/dev/null || true
  its::add_label    "$issue" "Mode:$mode" 2>/dev/null || true
}
