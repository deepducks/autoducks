#!/usr/bin/env bash
set -euo pipefail

# git::mark_pr_ready PR_NUMBER [SLUG] [TOKEN]
#   SLUG defaults to $REPO and TOKEN to the ambient GH_TOKEN (unchanged
#   behaviour), so existing single-repo callers are byte-identical. Passing a
#   child SLUG + TOKEN (from git::resolve_token) lets the metarepo delivery
#   path toggle a child delivery PR's draft state under the child credential.
git::mark_pr_ready() {
  local pr_number="$1" slug="${2:-$REPO}" token="${3:-${GH_TOKEN:-}}"
  GH_TOKEN="$token" gh pr ready "$pr_number" --repo "$slug"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::mark_pr_ready PR_NUMBER [SLUG] [TOKEN]"; echo "  Promote a draft pull request to ready-for-review"; echo "  SLUG defaults to \$REPO, TOKEN defaults to the ambient GH_TOKEN"; echo "  Requires: REPO env var (when SLUG omitted)"; exit 0 ;;
  esac
fi
