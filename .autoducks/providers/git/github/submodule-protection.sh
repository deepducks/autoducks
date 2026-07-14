#!/usr/bin/env bash
set -euo pipefail

# git::submodule_protection(slug) — print "true" when the child's default branch
# is protected (requires a PR to advance), "false" otherwise. Runs with the
# child's resolved credential. On any API error, prints "false" (treat as
# unprotected — the direct push will surface a real error if it is in fact
# protected) so a transient probe failure never blocks delivery silently.
git::submodule_protection() {
  local slug="$1"
  [[ -n "$slug" ]] || { echo "false"; return 0; }

  local token; token="$(git::resolve_token "$slug")"
  local default_branch
  default_branch="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || true)"
  [[ -n "$default_branch" ]] || { echo "false"; return 0; }

  local protected
  protected="$(GH_TOKEN="$token" gh api "repos/$slug/branches/$default_branch" --jq '.protected' 2>/dev/null || true)"
  [[ "$protected" == "true" ]] && echo "true" || echo "false"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_protection OWNER/REPO"; echo "  Print true/false whether the child default branch is protected (metarepo mode)"; exit 0 ;;
  esac
fi
