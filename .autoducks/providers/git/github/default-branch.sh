#!/usr/bin/env bash
set -euo pipefail

# git::default_branch → the repository's default branch name, empty when the
# host cannot answer (offline, token refused, repo gone).
#
# Distinct from AUTODUCKS_BASE_BRANCH on purpose. That key says where the
# pipeline cuts branches from; this says which branch the host actually serves
# as HEAD — and therefore which copy of .github/workflows/ and .autoducks/ a
# scheduled or dispatched run executes. A repo can legitimately set them to
# different branches (see the update agent's delivery target).
git::default_branch() {
  gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::default_branch"; echo "  Print the repository's default branch (empty if unresolvable)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
