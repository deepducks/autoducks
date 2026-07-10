#!/usr/bin/env bash
set -euo pipefail

# ── #auto: chain dispatch ────────────────────────────────────────────
# A chain is a `+`-separated list of canonical verbs (architect, engineer,
# execute) queued to run after the current agent finishes. Chains originate
# from a `#auto:` directive token (parse-directive.sh) or from a
# Definition-of-Ready guard delegating to a prerequisite agent.
#
# Loop protection: parse-directive dedupes verbs inside a chain, and
# chain::dispatch_prerequisite refuses to prepend an agent that already
# appears in current+chain. Chains are capped at 5 verbs at parse time.
#
# Env: REPO (gh); OVERRIDE_MODEL/OVERRIDE_EFFORT/OVERRIDE_MAX_TURNS/
#      OVERRIDE_MODE forwarded only when the USER explicitly set them in the
#      directive (never the current agent's own defaults — each agent
#      resolves its own); COMMENTER forwarded as `actor` so the
#      done-assignee (D15) stays the human who issued the original command.

_CHAIN_MAX_LEN=5

# chain::_workflow_for VERB → workflow file + issue input name
chain::_workflow_for() {
  case "$1" in
    architect) echo "autoducks-architect.yml issue_number" ;;
    engineer)  echo "autoducks-engineer.yml issue_number" ;;
    # A chained `execute` always follows planning on a feature/bug issue, so
    # it targets the Maestro (orchestration); the Maestro dispatches Developer
    # workers itself.
    execute)   echo "autoducks-maestro.yml feature_issue" ;;
    review)    echo "autoducks-reviewer.yml issue_number" ;;
    *) return 1 ;;
  esac
}

# chain::_dispatch VERB ISSUE_NUM REMAINING_CHAIN
chain::_dispatch() {
  local verb="$1" issue="$2" rest="${3:-}"
  local mapping workflow input_name
  mapping=$(chain::_workflow_for "$verb") || {
    echo "::warning::chain: unknown verb '$verb' — chain dropped" >&2
    return 1
  }
  workflow="${mapping%% *}"
  input_name="${mapping##* }"

  local -a args=(-f "${input_name}=${issue}")
  [[ -n "$rest" ]]                   && args+=(-f "auto_chain=$rest")
  [[ -n "${COMMENTER:-}" ]]          && args+=(-f "actor=$COMMENTER")
  [[ -n "${OVERRIDE_MODEL:-}" ]]     && args+=(-f "model=$OVERRIDE_MODEL")
  [[ -n "${OVERRIDE_EFFORT:-}" ]]    && args+=(-f "effort=$OVERRIDE_EFFORT")
  [[ -n "${OVERRIDE_MAX_TURNS:-}" ]] && args+=(-f "max_turns=$OVERRIDE_MAX_TURNS")
  [[ -n "${OVERRIDE_MODE:-}" ]]      && args+=(-f "mode=$OVERRIDE_MODE")

  git::dispatch_workflow "$workflow" "${args[@]}"
}

# chain::dispatch_next CHAIN ISSUE_NUM
# Pops the first verb off CHAIN and dispatches it with the remainder.
# No-op on an empty chain. Non-fatal on dispatch errors (the pipeline can
# always be resumed by hand).
chain::dispatch_next() {
  local chain="${1:-}" issue="$2"
  [[ -z "$chain" ]] && return 0

  local head rest
  head="${chain%%+*}"
  if [[ "$chain" == *"+"* ]]; then
    rest="${chain#*+}"
  else
    rest=""
  fi

  if chain::_dispatch "$head" "$issue" "$rest"; then
    echo "::notice::chain: dispatched '$head' on #$issue (remaining: ${rest:-none})"
    return 0
  fi
  echo "::warning::chain: failed to dispatch '$head' on #$issue — chain stopped" >&2
  return 0
}

# chain::dispatch_prerequisite PREREQ CURRENT_VERB CHAIN ISSUE_NUM
# Definition-of-Ready delegation: the current agent is not ready, so run the
# prerequisite first and re-queue the current agent (plus any existing chain)
# after it. Returns 1 (without dispatching) when doing so would loop.
chain::dispatch_prerequisite() {
  local prereq="$1" current="$2" chain="${3:-}" issue="$4"

  # Loop protection: prerequisite must not already be queued or running.
  case "+${current}+${chain}+" in
    *"+${prereq}+"*)
      echo "::warning::chain: refusing to dispatch prerequisite '$prereq' — already in chain (+${current}+${chain}+)" >&2
      return 1 ;;
  esac

  local new_chain="${current}${chain:++$chain}"

  # Depth cap (parse caps user chains; delegation adds at most one level per hop).
  local n
  n=$(awk -F'+' '{print NF}' <<< "$new_chain")
  if (( n > _CHAIN_MAX_LEN )); then
    echo "::warning::chain: refusing to dispatch prerequisite '$prereq' — chain too long ($new_chain)" >&2
    return 1
  fi

  chain::_dispatch "$prereq" "$issue" "$new_chain"
}
