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
      # #1106's OIDC token broker is the natural home for minting an installation
      # token per owner. Until it lands, fall back to the default PAT so
      # single-owner setups still work; cross-org will fail the pre-flight gate
      # with an actionable message rather than here.
      if [[ -z "${_AUTODUCKS_GITHUB_APP_WARNED:-}" ]]; then
        echo "::warning::metarepo.auth.mode=github_app is not wired yet (see #1106); falling back to AUTODUCKS_PAT." >&2
        _AUTODUCKS_GITHUB_APP_WARNED=1
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
