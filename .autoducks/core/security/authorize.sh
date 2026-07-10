#!/usr/bin/env bash
# Authorization gate for autoducks agents. Invoked as a script (not sourced):
#
#   bash .autoducks/core/security/authorize.sh
#
# Required env: AUTODUCKS_AGENT, ACTOR, AUTHOR_ASSOC, EVENT_NAME, REPO, GH_TOKEN
# Optional env: ISSUE_NUM, COMMENT_ID, EVENT_ACTION
#
# Exit 0  = authorized (or bypassed).
# Exit 77 = denied — caller must skip remaining steps via
#           `if: steps.authz.outcome == 'success'`.
set -euo pipefail

# Own directory. Use a namespaced name because providers/its/interface.sh
# reuses the generic `SCRIPT_DIR` and would otherwise clobber ours when
# we source it below.
AUTHZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${AUTODUCKS_ROOT:-}" ]]; then
  AUTODUCKS_ROOT="$(cd "$AUTHZ_DIR/../.." && pwd)"
fi
export AUTODUCKS_ROOT

# Repo working tree (for CODEOWNERS lookup). Defaults to $PWD but can be
# overridden by tests via AUTODUCKS_REPO_ROOT.
AUTODUCKS_REPO_ROOT="${AUTODUCKS_REPO_ROOT:-$PWD}"

# shellcheck source=./parse-codeowners.sh
source "$AUTHZ_DIR/parse-codeowners.sh"
# shellcheck source=./resolve-team.sh
source "$AUTHZ_DIR/resolve-team.sh"

# ── Audit ───────────────────────────────────────────────────────────────
authz::audit() {
  local line="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$line" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# ── Config loader ───────────────────────────────────────────────────────
# Reads $AUTODUCKS_ROOT/autoducks.json, merges .security with
# .security.per_agent[<agent>] using the `jq -s '.[0] * .[1]'` pattern
# from load-config.sh. Exports:
#   AUTODUCKS_AUTHZ_TRUSTED     (space-separated)
#   AUTODUCKS_AUTHZ_ALLOW       (space-separated)
#   AUTODUCKS_AUTHZ_DENY        (space-separated)
#   AUTODUCKS_AUTHZ_CODEOWNERS  ("true"/"false")
#
# Backward-compatible baseline (applied when .security is absent or a key
# is missing): trusted=OWNER,MEMBER,COLLABORATOR; codeowners=false;
# revert/close default to trusted=OWNER,MEMBER.
authz::load_config() {
  local agent="$1"
  # The Maestro and Developer are both faces of the `execute` command — they
  # share its per_agent security policy.
  case "$agent" in
    maestro|developer) agent="execute" ;;
    reviewer)          agent="review"  ;;
    resolver)          agent="resolve" ;;
    triage)            agent="product" ;;
  esac
  local config="$AUTODUCKS_ROOT/autoducks.json"

  [[ -f "$config" ]] || { echo "authorize: config not found: $config" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "authorize: jq is required" >&2; return 1; }

  local baseline
  baseline='{
    "trusted_associations": ["OWNER", "MEMBER", "COLLABORATOR"],
    "allow": [],
    "deny": [],
    "codeowners": false,
    "per_agent": {
      "revert":  { "trusted_associations": ["OWNER", "MEMBER"] },
      "close":   { "trusted_associations": ["OWNER", "MEMBER"] },
      "product": { "trusted_associations": ["OWNER", "MEMBER", "COLLABORATOR"] },
      "merge":   { "trusted_associations": ["OWNER", "MEMBER"] }
    }
  }'

  local security_json
  security_json="$(jq -c '.security // {}' "$config" 2>/dev/null)" || return 1

  local merged_global
  merged_global="$(jq -sc '.[0] * .[1]' \
    <(printf '%s' "$baseline") \
    <(printf '%s' "$security_json") 2>/dev/null)" || return 1

  local per_agent
  per_agent="$(printf '%s' "$merged_global" \
    | jq -c --arg a "$agent" '.per_agent[$a] // {}' 2>/dev/null)" || return 1

  local effective
  effective="$(jq -sc '.[0] * .[1]' \
    <(printf '%s' "$merged_global") \
    <(printf '%s' "$per_agent") 2>/dev/null)" || return 1

  AUTODUCKS_AUTHZ_TRUSTED="$(printf '%s' "$effective" | jq -r '.trusted_associations // [] | join(" ")')"
  AUTODUCKS_AUTHZ_ALLOW="$(printf '%s' "$effective" | jq -r '.allow // [] | join(" ")')"
  AUTODUCKS_AUTHZ_DENY="$(printf '%s' "$effective" | jq -r '.deny // [] | join(" ")')"
  AUTODUCKS_AUTHZ_CODEOWNERS="$(printf '%s' "$effective" | jq -r '.codeowners // false')"
  export AUTODUCKS_AUTHZ_TRUSTED AUTODUCKS_AUTHZ_ALLOW AUTODUCKS_AUTHZ_DENY AUTODUCKS_AUTHZ_CODEOWNERS
}

# ── Helpers ─────────────────────────────────────────────────────────────
authz::in_list() {
  local needle="$1"
  local list="$2"
  [[ -z "$needle" || -z "$list" ]] && return 1
  local item
  for item in $list; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

authz::find_codeowners() {
  for path in .github/CODEOWNERS docs/CODEOWNERS CODEOWNERS; do
    if [[ -f "$AUTODUCKS_REPO_ROOT/$path" ]]; then
      printf '%s\n' "$AUTODUCKS_REPO_ROOT/$path"
      return 0
    fi
  done
  return 1
}

authz::codeowners_match() {
  local actor="$1"
  local co_file
  co_file="$(authz::find_codeowners)" || return 1

  local owner
  while IFS= read -r owner; do
    [[ -z "$owner" ]] && continue
    # @username
    if [[ "$owner" == "@$actor" ]]; then
      return 0
    fi
    # @org/team-slug
    if [[ "$owner" == @*/* ]]; then
      local team="${owner#@}"
      local org="${team%%/*}"
      local slug="${team#*/}"
      if resolve_team_contains "$org" "$slug" "$actor"; then
        return 0
      fi
    fi
  done < <(parse_codeowners "$co_file")
  return 1
}

# ── Side effects on denial ──────────────────────────────────────────────
authz::send_denial_feedback() {
  # React 👎 to the trigger comment, if any.
  if [[ -n "${COMMENT_ID:-}" && "${COMMENT_ID}" != "0" ]]; then
    if declare -F its::react_to_comment >/dev/null 2>&1; then
      its::react_to_comment "$COMMENT_ID" "-1" || true
    fi
  fi

  # Post the denial comment, if we know the issue.
  if [[ -n "${ISSUE_NUM:-}" ]]; then
    if declare -F its::comment_issue >/dev/null 2>&1; then
      local tmpl="$AUTHZ_DIR/denial-message.md"
      if [[ -f "$tmpl" ]]; then
        local body
        body="$(cat "$tmpl")"
        body="${body//\{actor\}/$ACTOR}"
        body="${body//\{command\}/$AUTODUCKS_AGENT}"
        its::comment_issue "$ISSUE_NUM" "$body" || true
      fi
    fi
  fi
}

authz::deny() {
  local rule="$1"
  authz::audit "authz: DENY actor=${ACTOR:-} assoc=${AUTHOR_ASSOC:-} agent=${AUTODUCKS_AGENT:-} rule=${rule}"
  authz::send_denial_feedback
  exit 77
}

# Auditable allow (non-ladder — i.e., not the standard trusted-association
# path). Emits an audit line and exits 0.
authz::allow_audited() {
  local rule="$1"
  authz::audit "authz: ALLOW actor=${ACTOR:-} assoc=${AUTHOR_ASSOC:-} agent=${AUTODUCKS_AGENT:-} rule=${rule}"
  exit 0
}

authz::allow_silent() {
  exit 0
}

# ── Main ────────────────────────────────────────────────────────────────
authz::main() {
  # 1 & 2 — event-level bypasses (checked BEFORE env-var validation because
  # workflow_dispatch, PR-closure, and schedule events legitimately have
  # empty AUTHOR_ASSOC / ACTOR — a schedule event has no actor and is
  # write-access-gated by construction). `issues` is bypassed for the
  # `opened` and `closed` actions (EVENT_ACTION, passed alongside
  # EVENT_NAME): an externally-opened issue still gets its single-issue
  # priority pass instead of being denied on AUTHOR_ASSOC and silently
  # falling back to the next daily sweep, and a `closed` action must reach
  # the close-guard agent even when the closer is untrusted — otherwise the
  # guard's own invariant (an issue is never closed while its delivery PR
  # is open) could be defeated by denying the very check meant to catch an
  # untrusted premature close. This mirrors the workflows' job-level `if:`
  # but isn't relying on it as the sole backstop — any other `issues`
  # action (e.g. `edited`, `labeled`) falls through to the normal
  # authorization ladder below.
  case "${EVENT_NAME:-}" in
    workflow_dispatch) authz::allow_silent ;;
    pull_request)      authz::allow_silent ;;
    schedule)          authz::allow_silent ;;
    issues)
      [[ "${EVENT_ACTION:-}" == "opened" || "${EVENT_ACTION:-}" == "closed" ]] && authz::allow_silent
      ;;
  esac

  # Fail-closed on missing env for the actual authorization path.
  local var
  for var in AUTODUCKS_AGENT ACTOR EVENT_NAME; do
    if [[ -z "${!var:-}" ]]; then
      authz::audit "authz: DENY reason=missing_env_var:${var}"
      exit 77
    fi
  done

  # Load ITS provider so denials can react / comment. If the provider
  # can't be loaded we still enforce the ladder; the audit trail alone
  # will explain the outcome.
  if [[ -z "${AUTODUCKS_ITS_PROVIDER:-}" && -f "$AUTODUCKS_ROOT/autoducks.json" ]]; then
    AUTODUCKS_ITS_PROVIDER="$(jq -r '.providers.its // empty' "$AUTODUCKS_ROOT/autoducks.json" 2>/dev/null || true)"
    export AUTODUCKS_ITS_PROVIDER
  fi
  if [[ -n "${AUTODUCKS_ITS_PROVIDER:-}" \
     && -f "$AUTODUCKS_ROOT/providers/its/interface.sh" ]]; then
    # shellcheck source=/dev/null
    source "$AUTODUCKS_ROOT/providers/its/interface.sh" 2>/dev/null || true
  fi

  # Fail-closed on unparseable config.
  if ! authz::load_config "$AUTODUCKS_AGENT"; then
    authz::audit "authz: DENY actor=${ACTOR} assoc=${AUTHOR_ASSOC:-} agent=${AUTODUCKS_AGENT} rule=unparseable_config"
    authz::send_denial_feedback
    exit 77
  fi

  # 3 — deny list beats everything (including OWNER).
  if authz::in_list "$ACTOR" "$AUTODUCKS_AUTHZ_DENY"; then
    authz::deny "deny_list"
  fi

  # 4 — explicit allow list.
  if authz::in_list "$ACTOR" "$AUTODUCKS_AUTHZ_ALLOW"; then
    authz::allow_audited "allow_list"
  fi

  # 5 — trusted GitHub author_association. Only match on the recognized
  # enum; anything else falls through and eventually denies.
  local known_assoc="OWNER MEMBER COLLABORATOR CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE"
  if [[ -n "${AUTHOR_ASSOC:-}" ]] \
     && authz::in_list "$AUTHOR_ASSOC" "$known_assoc" \
     && authz::in_list "$AUTHOR_ASSOC" "$AUTODUCKS_AUTHZ_TRUSTED"; then
    exit 0
  fi

  # 6 — CODEOWNERS fallback (user or team).
  if [[ "$AUTODUCKS_AUTHZ_CODEOWNERS" == "true" ]]; then
    if authz::codeowners_match "$ACTOR"; then
      authz::allow_audited "codeowners"
    fi
  fi

  # 7 — default deny.
  authz::deny "default_deny"
}

authz::main "$@"
