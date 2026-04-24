#!/usr/bin/env bash
set -euo pipefail

git::push_branch() {
  local branch="$1"
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    git remote set-url origin "https://x-access-token:${token}@github.com/${REPO}.git"
  fi
  git push -u origin "$branch"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::push_branch BRANCH_NAME"; echo "  Push a local branch to origin"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
