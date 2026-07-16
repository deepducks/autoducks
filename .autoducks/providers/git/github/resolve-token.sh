#!/usr/bin/env bash
set -euo pipefail

# git::resolve_token(repo_or_owner) — the single seam every cross-repo git/gh
# operation uses to obtain the credential for a given child. A fine-grained PAT
# is bound to one resource owner, so the metarepo cannot assume one token fits
# every child; `metarepo.auth.mode` selects how the owner maps to a credential.
#
#   single_pat    (default) — every child uses AUTODUCKS_PAT (single-owner metarepos)
#   per_owner_pat           — owner → AUTODUCKS_PAT_<OWNER> secret, else default PAT
#   github_app              — installation token per owner (rides on #1106's broker);
#                             not wired yet, falls back to the default PAT with a warning
#
# Prints the token on stdout (empty string if none resolvable). The default PAT
# is AUTODUCKS_PAT, falling back to GH_TOKEN / GITHUB_TOKEN so single-repo mode
# and offline fixtures keep working unchanged.
git::_default_token() {
  printf '%s' "${AUTODUCKS_PAT:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
}

# Normalise an owner into an env-var suffix: uppercase, non-alnum → underscore.
git::_owner_var_suffix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//'
}

# Central broker endpoint. Hardcoded (not config) so no repo variable or app
# permission is needed to point at it; if it ever moves, sync autoducks.
readonly _AUTODUCKS_BROKER_URL="https://autoducks-api.gustavospgondim.workers.dev"

# Mint a broker installation token scoped to TARGET (owner/repo) for a
# same-owner sibling. Requests a fresh OIDC token and exchanges it at the
# broker; the broker refuses cross-owner targets and repos the app isn't
# installed on. Only meaningful under metarepo.auth.mode=github_app (an explicit
# opt-in). Prints the token, or nothing on any failure (caller falls back).
git::_mint_app_token() {
  local target="$1"
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || return 1
  local oidc
  oidc="$(curl -sf -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=autoducks-broker" 2>/dev/null | jq -r .value)" || return 1
  [[ -n "$oidc" && "$oidc" != "null" ]] || return 1
  local tok
  tok="$(curl -sf -X POST -H "Authorization: Bearer $oidc" \
    -H "Content-Type: application/json" -d "{\"repository\":\"$target\"}" \
    "${_AUTODUCKS_BROKER_URL}/token" 2>/dev/null | jq -r .token)" || return 1
  [[ -n "$tok" && "$tok" != "null" ]] || return 1
  printf '%s' "$tok"
}

git::resolve_token() {
  local repo="${1:-}"
  local owner="${repo%%/*}"
  local mode="${AUTODUCKS_METAREPO_AUTH_MODE:-single_pat}"

  case "$mode" in
    per_owner_pat)
      if [[ -n "$owner" ]]; then
        local var="AUTODUCKS_PAT_$(git::_owner_var_suffix "$owner")"
        local tok="${!var:-}"
        if [[ -n "$tok" ]]; then
          printf '%s' "$tok"
          return 0
        fi
      fi
      git::_default_token
      ;;
    github_app)
      # Current repo: reuse the token an early workflow step already minted and
      # exported as AUTODUCKS_APP_TOKEN.
      local current="${GITHUB_REPOSITORY:-}"
      if [[ -n "${AUTODUCKS_APP_TOKEN:-}" && ( -z "$repo" || "$repo" == "$current" ) ]]; then
        printf '%s' "$AUTODUCKS_APP_TOKEN"
        return 0
      fi
      # Same-owner sibling (metarepo child): mint a target-scoped token via the
      # broker. The broker enforces same-owner + app-installed; cross-owner and
      # no-broker cases fall through to the PAT.
      if [[ -n "$repo" ]]; then
        local tok; tok="$(git::_mint_app_token "$repo")" && [[ -n "$tok" ]] && {
          printf '%s' "$tok"; return 0
        }
      fi
      git::_default_token
      ;;
    *) # single_pat
      git::_default_token
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::resolve_token OWNER_OR_SLUG"; echo "  Resolve the push credential for a child repo per metarepo.auth.mode"; exit 0 ;;
  esac
fi
