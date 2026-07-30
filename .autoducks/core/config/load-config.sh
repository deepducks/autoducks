#!/usr/bin/env bash
set -euo pipefail

# ── Locate .autoducks root ──────────────────────────────────────────
if [[ -n "${AUTODUCKS_ROOT:-}" ]]; then
  : # already set by caller
else
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Walk up until we find autoducks.json (max 10 levels)
  _depth=0
  while [[ "$_depth" -lt 10 ]]; do
    if [[ -f "$_dir/autoducks.json" ]]; then
      AUTODUCKS_ROOT="$_dir"
      break
    fi
    _dir="$(dirname "$_dir")"
    (( _depth++ )) || true
  done
  if [[ -z "${AUTODUCKS_ROOT:-}" ]]; then
    echo "load-config: could not find autoducks.json" >&2
    exit 1
  fi
fi
export AUTODUCKS_ROOT

# ── Read config ─────────────────────────────────────────────────────
_config="$AUTODUCKS_ROOT/autoducks.json"
if [[ ! -f "$_config" ]]; then
  echo "load-config: $_config not found" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "load-config: jq is required but not installed" >&2
  exit 1
fi

# ── Slash-command namespace (configurable; default none) ────────────
export AUTODUCKS_COMMAND
AUTODUCKS_COMMAND="$(jq -r '.command // ""' "$_config")"
[[ "$AUTODUCKS_COMMAND" =~ ^$|^/?[a-z0-9-]+$ ]] || AUTODUCKS_COMMAND=""

# ── Provider env vars ───────────────────────────────────────────────
export AUTODUCKS_ITS_PROVIDER
AUTODUCKS_ITS_PROVIDER="$(jq -r '.providers.its // empty' "$_config")"

export AUTODUCKS_GIT_PROVIDER
AUTODUCKS_GIT_PROVIDER="$(jq -r '.providers.git // empty' "$_config")"

export AUTODUCKS_LLM_PROVIDER
AUTODUCKS_LLM_PROVIDER="$(jq -r '.providers.llm // empty' "$_config")"

# ── Defaults (global + per-agent override) ─────────────────────────
_agent_defaults="{}"
if [[ -n "${AUTODUCKS_AGENT:-}" ]]; then
  _agent_config="$AUTODUCKS_ROOT/agents/$AUTODUCKS_AGENT/defaults.json"
  if [[ -f "$_agent_config" ]]; then
    _agent_defaults="$(cat "$_agent_config")"
  fi
fi

_merged="$(jq -s '.[0].defaults * .[1]' "$_config" <(echo "$_agent_defaults"))"

export AUTODUCKS_MODEL
AUTODUCKS_MODEL="$(echo "$_merged" | jq -r '.model // empty')"

export AUTODUCKS_EFFORT
AUTODUCKS_EFFORT="$(echo "$_merged" | jq -r '.effort // empty')"

# `// empty`, not `// 0`, so a deliberate `0` stays distinguishable from unset.
export AUTODUCKS_MAX_TURNS
AUTODUCKS_MAX_TURNS="$(echo "$_merged" | jq -r '.max_turns // empty')"

export AUTODUCKS_BASE_BRANCH
AUTODUCKS_BASE_BRANCH="$(echo "$_merged" | jq -r '.base_branch // empty')"

export AUTODUCKS_INTEGRATION_BRANCH
AUTODUCKS_INTEGRATION_BRANCH="$(echo "$_merged" | jq -r '.integration_branch // empty')"
if [[ -z "$AUTODUCKS_INTEGRATION_BRANCH" ]]; then
  AUTODUCKS_INTEGRATION_BRANCH="$AUTODUCKS_BASE_BRANCH"
fi

export AUTODUCKS_MERGE_METHOD
AUTODUCKS_MERGE_METHOD="$(echo "$_merged" | jq -r '.merge_method // "auto"')"

# ── Reviewer required-check name ─────────────────────────────────────
# Single source of truth shared by the reviewer (pre/post.sh) and
# scripts/setup.sh, so the emitted Check-run name and the ruleset that
# requires it can never drift apart.
export AUTODUCKS_REVIEW_CHECK_NAME
AUTODUCKS_REVIEW_CHECK_NAME="$(jq -r '.reviewer.check_name // "Autoducks: Reviewer"' "$_config")"

# ── Delivery-check name / timing ─────────────────────────────────────
# Single source of truth shared by the delivery poller and the ruleset
# registration, so the emitted Check-run name and the ruleset that
# requires it can never drift apart.
export AUTODUCKS_DELIVERY_CHECK_NAME
AUTODUCKS_DELIVERY_CHECK_NAME="$(jq -r '.metarepo.delivery_check.check_name // "Autoducks: Children delivered"' "$_config")"

export AUTODUCKS_DELIVERY_TIMEOUT_MINUTES
AUTODUCKS_DELIVERY_TIMEOUT_MINUTES="$(jq -r '.metarepo.delivery_check.timeout_minutes // 45' "$_config")"
[[ "$AUTODUCKS_DELIVERY_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || AUTODUCKS_DELIVERY_TIMEOUT_MINUTES=45

export AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS
AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS="$(jq -r '.metarepo.delivery_check.poll_interval_seconds // 30' "$_config")"
[[ "$AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS=30
(( AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS < 30 )) && AUTODUCKS_DELIVERY_POLL_INTERVAL_SECONDS=30

# ── Missing-required-check recovery (#119c) ──────────────────────────────
# A child delivery PR with an empty statusCheckRollup is waiting on a check that
# was never produced, so `--auto` can never fire. These bound how patient the
# recovery is: how many attempts submodule_deliver makes right after arming
# auto-merge, and how many poll rounds the delivery poller tolerates before it
# re-fires the check (and, a second window later, fails with that diagnosis).
export AUTODUCKS_CHECK_ASSERT_ATTEMPTS
AUTODUCKS_CHECK_ASSERT_ATTEMPTS="$(jq -r '.metarepo.check_recovery.assert_attempts // 3' "$_config")"
[[ "$AUTODUCKS_CHECK_ASSERT_ATTEMPTS" =~ ^[0-9]+$ ]] && (( AUTODUCKS_CHECK_ASSERT_ATTEMPTS >= 1 )) || AUTODUCKS_CHECK_ASSERT_ATTEMPTS=3

export AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS
AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS="$(jq -r '.metarepo.check_recovery.assert_interval_seconds // 5' "$_config")"
[[ "$AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && (( AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS >= 1 )) || AUTODUCKS_CHECK_ASSERT_INTERVAL_SECONDS=5

export AUTODUCKS_CHECK_RECOVERY_ROUNDS
AUTODUCKS_CHECK_RECOVERY_ROUNDS="$(jq -r '.metarepo.check_recovery.poll_rounds // 2' "$_config")"
[[ "$AUTODUCKS_CHECK_RECOVERY_ROUNDS" =~ ^[0-9]+$ ]] && (( AUTODUCKS_CHECK_RECOVERY_ROUNDS >= 1 )) || AUTODUCKS_CHECK_RECOVERY_ROUNDS=2

# ── Orchestrator mode ─────────────────────────────────────────────────
export AUTODUCKS_ORCHESTRATOR_MODE
AUTODUCKS_ORCHESTRATOR_MODE="$(jq -r '.orchestrator.mode // "waves"' "$_config")"
case "$AUTODUCKS_ORCHESTRATOR_MODE" in
  waves|sequential) ;;
  *) AUTODUCKS_ORCHESTRATOR_MODE="waves" ;;   # tolerate garbage
esac

# ── Metarepo mode ────────────────────────────────────────────────────
# When enabled, autoducks drives a private aggregating "metarepo" whose child
# repos are git submodules. Everything gated on AUTODUCKS_METAREPO; when it is
# false (the default) single-repo behaviour is byte-identical.
export AUTODUCKS_METAREPO
AUTODUCKS_METAREPO="$(jq -r 'if .metarepo.enabled == true then "true" else "false" end' "$_config")"

export AUTODUCKS_METAREPO_STRATEGY
AUTODUCKS_METAREPO_STRATEGY="$(jq -r '.metarepo.protected_submodule_strategy // "auto_merge"' "$_config")"
case "$AUTODUCKS_METAREPO_STRATEGY" in
  auto_merge|required_check) ;;
  *) AUTODUCKS_METAREPO_STRATEGY="auto_merge" ;;
esac

export AUTODUCKS_METAREPO_AUTH_MODE
AUTODUCKS_METAREPO_AUTH_MODE="$(jq -r '.metarepo.auth.mode // "single_pat"' "$_config")"
case "$AUTODUCKS_METAREPO_AUTH_MODE" in
  single_pat|per_owner_pat|github_app) ;;
  *) AUTODUCKS_METAREPO_AUTH_MODE="single_pat" ;;
esac

# Body marker stamped on metarepo-managed child PRs so the child's own
# reviewer / rework / commit-lint guards skip them (the child pipeline stays
# dormant). General capability — ships to every install, honored by the child
# workflow `if:` guards regardless of whether that child is itself a metarepo.
export AUTODUCKS_METAREPO_MARKER="<!-- autoducks:metarepo-managed -->"

# Modules depend on one another, so execution must be backpressured: a task
# branches off the *merged* result of the previous one. Force sequential
# orchestration whenever metarepo mode is on (config cannot contradict it).
if [[ "$AUTODUCKS_METAREPO" == "true" ]]; then
  AUTODUCKS_ORCHESTRATOR_MODE="sequential"
fi

# ── Coordination-marker paths ────────────────────────────────────────
# Coordination markers live in the runner's private temp dir (never the agent's
# /tmp working area) and are scoped per run, so agent Bash activity and the
# repo's own unit tests cannot collide with the pre/post protocol.
AUTODUCKS_MARKER_DIR="${RUNNER_TEMP:-/tmp}/autoducks-${GITHUB_RUN_ID:-local}"
export AUTODUCKS_MARKER_DIR
export AUTODUCKS_PRE_FAILED_MARKER="$AUTODUCKS_MARKER_DIR/pre-failed"
export AUTODUCKS_DOR_DELEGATED_MARKER="$AUTODUCKS_MARKER_DIR/dor-delegated"

# The no-code-result artifact is written by the LLM sandbox, whose only
# writable working area is /tmp (not RUNNER_TEMP/AUTODUCKS_MARKER_DIR), so
# this must be a fixed, sandbox-writable /tmp path rather than living
# alongside the runner-private markers above.
export AUTODUCKS_NO_CODE_RESULT="/tmp/no-code-result.md"

# ── Review settings ─────────────────────────────────────────────────
export AUTODUCKS_REVIEW_SECURITY_GUIDELINES
AUTODUCKS_REVIEW_SECURITY_GUIDELINES="$(jq -r '.review.security_guidelines // ".autoducks/security-guidelines.md"' "$_config")"

export AUTODUCKS_REVIEW_AUTO_REWORK
AUTODUCKS_REVIEW_AUTO_REWORK="$(jq -r 'if .review.auto_rework == null then true else .review.auto_rework end' "$_config")"

export AUTODUCKS_REVIEW_MAX_ITERATIONS
AUTODUCKS_REVIEW_MAX_ITERATIONS="$(jq -r '.review.max_iterations // 3' "$_config")"
[[ "$AUTODUCKS_REVIEW_MAX_ITERATIONS" =~ ^[0-9]+$ ]] || AUTODUCKS_REVIEW_MAX_ITERATIONS=3
(( AUTODUCKS_REVIEW_MAX_ITERATIONS < 1 ))  && AUTODUCKS_REVIEW_MAX_ITERATIONS=1
(( AUTODUCKS_REVIEW_MAX_ITERATIONS > 10 )) && AUTODUCKS_REVIEW_MAX_ITERATIONS=10

# ── Checks (verification loop) settings ──────────────────────────────
export AUTODUCKS_CHECKS_ENABLED
AUTODUCKS_CHECKS_ENABLED="$(jq -r '.checks.enabled // false' "$_config")"

export AUTODUCKS_CHECKS_SETUP
AUTODUCKS_CHECKS_SETUP="$(jq -r '.checks.setup // ""' "$_config")"

export AUTODUCKS_CHECKS_GIT_HOOKS
AUTODUCKS_CHECKS_GIT_HOOKS="$(jq -r '.checks.git_hooks // false' "$_config")"

export AUTODUCKS_CHECKS_MAX_ITERATIONS
AUTODUCKS_CHECKS_MAX_ITERATIONS="$(jq -r '.checks.max_iterations // 3' "$_config")"
# Clamp to 1–10 (bounded cost); non-numeric / out-of-range → default 3.
[[ "$AUTODUCKS_CHECKS_MAX_ITERATIONS" =~ ^[0-9]+$ ]] || AUTODUCKS_CHECKS_MAX_ITERATIONS=3
(( AUTODUCKS_CHECKS_MAX_ITERATIONS < 1 ))  && AUTODUCKS_CHECKS_MAX_ITERATIONS=1
(( AUTODUCKS_CHECKS_MAX_ITERATIONS > 10 )) && AUTODUCKS_CHECKS_MAX_ITERATIONS=10

# ── Source provider interfaces ──────────────────────────────────────
source "$AUTODUCKS_ROOT/providers/its/interface.sh"
source "$AUTODUCKS_ROOT/providers/git/interface.sh"

# ── Command-string helper (must be available in every runtime) ──────
source "$AUTODUCKS_ROOT/core/config/command-string.sh"

# ── Metarepo (submodule) helpers (inert unless AUTODUCKS_METAREPO=true) ─
source "$AUTODUCKS_ROOT/core/config/metarepo.sh"

# Only source LLM interface outside GitHub Actions runtime
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  source "$AUTODUCKS_ROOT/providers/llm/interface.sh"
fi
