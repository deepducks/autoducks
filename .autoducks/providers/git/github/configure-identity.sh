#!/usr/bin/env bash
set -euo pipefail

git::configure_identity() {
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::configure_identity "; echo "  Configure git user identity for bot commits"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
