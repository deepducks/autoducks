#!/usr/bin/env bash
# Metarepo access pre-flight gate.
#
# Probes each child submodule with the credential git::resolve_token returns —
# the same one that will push — so an owner the token can't write to is caught
# *before* any branch is cut, and surfaced as an owner-specific escalation
# instead of a mid-run landmine. Two call sites:
#
#   • Installer doctor — probe every child in .gitmodules and print a table.
#   • Run start — probe only the feature's declared modules; on failure the
#     caller (developer/pre.sh) posts a status_comment::delegate escalation.
#
# Sourced form:  metarepo::access_gate [PATH...]   (default: all submodule paths)
#   → exit 0 if every probed child is writable
#   → exit 1 otherwise; the failing children are left in the global array
#     AUTODUCKS_GATE_FAILED_CHILDREN ("path\towner\tslug" per entry)
#
# Standalone:  bash metarepo-access-gate.sh [--table] [PATH...]
set -uo pipefail

# metarepo::_gate_probe_one PATH → echoes "path\towner\tslug\treachable\twritable\tprotected"
metarepo::_gate_probe_one() {
  local path="$1"
  local slug owner token reachable writable protected

  slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
  owner="${slug%%/*}"

  if [[ -z "$slug" ]]; then
    # Offline / non-GitHub remote — nothing the token gates; treat as writable.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "-" "(offline)" "yes" "yes" "no"
    return 0
  fi

  token="$(git::resolve_token "$slug")"
  local perms
  perms="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '{push: .permissions.push}' 2>/dev/null || true)"
  if [[ -z "$perms" ]]; then
    reachable="no"; writable="no"
  else
    reachable="yes"
    [[ "$(printf '%s' "$perms" | jq -r '.push')" == "true" ]] && writable="yes" || writable="no"
  fi
  protected="$(git::submodule_protection "$slug" 2>/dev/null || echo "false")"
  [[ "$protected" == "true" ]] && protected="yes" || protected="no"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$owner" "$slug" "$reachable" "$writable" "$protected"
}

# metarepo::access_gate [PATH...] — probe, populate AUTODUCKS_GATE_FAILED_CHILDREN,
# return 0/1. Emits per-child ::notice lines but no user-facing escalation (that
# is the caller's job, with issue context).
metarepo::access_gate() {
  AUTODUCKS_GATE_FAILED_CHILDREN=()
  local -a paths=()
  if [[ "$#" -gt 0 ]]; then
    paths=("$@")
  else
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < <(metarepo::submodule_paths)
  fi

  local row path owner slug reachable writable protected rc=0
  for path in "${paths[@]:-}"; do
    [[ -z "$path" ]] && continue
    row="$(metarepo::_gate_probe_one "$path")"
    IFS=$'\t' read -r path owner slug reachable writable protected <<< "$row"
    echo "::notice::metarepo gate: $slug reachable=$reachable writable=$writable protected=$protected" >&2
    if [[ "$writable" != "yes" ]]; then
      AUTODUCKS_GATE_FAILED_CHILDREN+=("${path}"$'\t'"${owner}"$'\t'"${slug}")
      rc=1
    fi
  done
  return "$rc"
}

# metarepo::gate_escalation_message — human-readable escalation body built from
# AUTODUCKS_GATE_FAILED_CHILDREN, naming each owner/child and the exact fix.
metarepo::gate_escalation_message() {
  local mode="${AUTODUCKS_METAREPO_AUTH_MODE:-single_pat}"
  local msg="🔒 **Metarepo access check failed.** The configured credential cannot **write** to one or more declared child repos, so the run stopped **before cutting any branch** — nothing was pushed anywhere."
  msg+=$'\n\n'
  local entry path owner slug
  for entry in "${AUTODUCKS_GATE_FAILED_CHILDREN[@]:-}"; do
    [[ -z "$entry" ]] && continue
    IFS=$'\t' read -r path owner slug <<< "$entry"
    msg+="- \`$slug\` (owner \`$owner\`, submodule \`$path\`)"$'\n'
  done
  msg+=$'\n'"**Fix:** "
  case "$mode" in
    per_owner_pat) msg+="add a secret \`AUTODUCKS_PAT_<OWNER>\` (uppercased owner) with \`contents:write\` + \`pull_requests:write\` on that owner." ;;
    github_app)    msg+="install/grant the GitHub App on the owner's organization so an installation token can be minted for it." ;;
    *)             msg+="grant \`AUTODUCKS_PAT\` write access to the owner above, or switch \`metarepo.auth.mode\` to \`per_owner_pat\` and add \`AUTODUCKS_PAT_<OWNER>\`." ;;
  esac
  printf '%s\n' "$msg"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Standalone doctor mode: load config + provider, print a table.
  _table=false
  if [[ "${1:-}" == "--table" ]]; then _table=true; shift; fi
  case "${1:-}" in
    --help)
      echo "Usage: metarepo-access-gate.sh [--table] [PATH...]"
      echo "  Probe child submodule write access with the resolved credential."
      exit 0 ;;
  esac
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Minimal bootstrap: the doctor runs on a user's machine (not just CI), so it
  # must not drag in the LLM provider that full load-config sources. Load only
  # the git provider + metarepo helpers and the two config values we need.
  AUTODUCKS_ROOT="$(cd "$_here/../.." && pwd)"
  export AUTODUCKS_ROOT
  _cfg="$AUTODUCKS_ROOT/autoducks.json"
  export AUTODUCKS_GIT_PROVIDER; AUTODUCKS_GIT_PROVIDER="$(jq -r '.providers.git // "github"' "$_cfg")"
  export AUTODUCKS_METAREPO; AUTODUCKS_METAREPO="$(jq -r 'if .metarepo.enabled == true then "true" else "false" end' "$_cfg")"
  export AUTODUCKS_METAREPO_AUTH_MODE; AUTODUCKS_METAREPO_AUTH_MODE="$(jq -r '.metarepo.auth.mode // "single_pat"' "$_cfg")"
  export AUTODUCKS_METAREPO_STRATEGY; AUTODUCKS_METAREPO_STRATEGY="$(jq -r '.metarepo.protected_submodule_strategy // "auto_merge"' "$_cfg")"
  source "$AUTODUCKS_ROOT/core/config/metarepo.sh"
  source "$AUTODUCKS_ROOT/providers/git/interface.sh"
  if ! metarepo::enabled; then
    echo "metarepo mode is disabled (metarepo.enabled=false) — nothing to probe." >&2
    exit 0
  fi
  printf 'PATH\tOWNER\tSLUG\tREACHABLE\tWRITABLE\tPROTECTED\n'
  _paths=("$@")
  if [[ "${#_paths[@]}" -eq 0 ]]; then
    while IFS= read -r p; do [[ -n "$p" ]] && _paths+=("$p"); done < <(metarepo::submodule_paths)
  fi
  _rc=0
  for _p in "${_paths[@]:-}"; do
    [[ -z "$_p" ]] && continue
    _row="$(metarepo::_gate_probe_one "$_p")"
    printf '%s\n' "$_row"
    IFS=$'\t' read -r _ _ _ _ _w _ <<< "$_row"
    [[ "$_w" != "yes" ]] && _rc=1
  done
  exit "$_rc"
fi
