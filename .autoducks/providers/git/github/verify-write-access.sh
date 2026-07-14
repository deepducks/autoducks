#!/usr/bin/env bash
set -euo pipefail

# git::verify_write_access(slug) — read-only probe: does the credential that
# git::resolve_token(slug) returns (the same one that will push) have write
# access to the child? Exit 0 = writable. Exit 1 = not writable / not reachable.
# A 404 or 403 (token not scoped to that owner/repo) counts as no write access,
# exactly like push=false — the whole point of the pre-flight gate is to catch
# an owner the token can't reach before any branch is cut.
git::verify_write_access() {
  local slug="$1"
  [[ -n "$slug" ]] || return 0   # offline/non-GitHub child — nothing to probe

  local token; token="$(git::resolve_token "$slug")"
  local push
  push="$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.permissions.push' 2>/dev/null || echo "__error__")"

  [[ "$push" == "true" ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::verify_write_access OWNER/REPO"; echo "  Exit 0 if the resolved child credential can push (metarepo pre-flight gate)"; exit 0 ;;
  esac
fi
