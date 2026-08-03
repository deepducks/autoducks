#!/usr/bin/env bash
set -euo pipefail

# git::submodule_remote(path) — point a child submodule's `origin` at a
# tokenized push URL, mirroring push-branch.sh but scoped per child via
# git::resolve_token (never the global GH_TOKEN). Offline / non-GitHub remotes
# (file://, relative) have no slug and are left untouched so fixture runs work.
git::submodule_remote() {
  local path="$1"
  local slug token
  slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"

  if [[ -z "$slug" ]]; then
    # Non-GitHub remote (offline fixture) — keep whatever origin the clone has.
    return 0
  fi

  token="$(git::resolve_token "$slug")"
  if [[ -n "$token" ]]; then
    git -C "$path" remote set-url origin "https://x-access-token:${token}@github.com/${slug}.git"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_remote SUBMODULE_PATH"; echo "  Set a per-child tokenized push remote (metarepo mode)"; exit 0 ;;
  esac
fi
