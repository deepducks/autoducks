#!/usr/bin/env bash
set -euo pipefail

git::push_branch() {
  local branch="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
  fi
  git push -u origin "$branch"
}
