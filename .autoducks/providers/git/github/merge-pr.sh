#!/usr/bin/env bash
set -euo pipefail

git::merge_pr() {
  local pr_number="$1"
  if ! gh pr merge "$pr_number" --repo "$REPO" --merge 2>/dev/null; then
    gh api "repos/$REPO/pulls/$pr_number/merge" \
      -X PUT -f merge_method=merge --silent
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::merge_pr PR_NUMBER"; echo "  Merge a pull request"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
