#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="close-guard"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

N="${CLOSED_ISSUE:?CLOSED_ISSUE env var required}"

# Enumerate open PRs into the integration branch; find any whose delivery
# maps back to the just-closed issue #N.
OPEN_PRS=$(git::list_open_prs "$AUTODUCKS_INTEGRATION_BRANCH")

DELIVERY_PR=""
while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  head=$(jq -r '.headRefName' <<<"$pr")
  body=$(jq -r '.body // ""' <<<"$pr")
  num=$(jq -r '.number' <<<"$pr")
  resolved=$(resolve_feature_num_from_pr "$head" "$body")
  if [[ "$resolved" == "$N" ]]; then
    DELIVERY_PR="$num"
    break
  fi
done < <(jq -c '.[]' <<<"$OPEN_PRS")

if [[ -z "$DELIVERY_PR" ]]; then
  echo "::notice::#$N closed with no open delivery PR — legitimate close, no action."
  exit 0
fi

# Invariant violated: issue closed while its delivery PR is still open.
its::reopen_issue "$N"
its::comment_issue "$N" "Reopened automatically — this issue was closed while its delivery PR #${DELIVERY_PR} is still open. Autoducks closes a feature/task issue only when its delivery PR merges. If you intended to abandon it, close PR #${DELIVERY_PR} as well."
echo "::warning::Reopened #$N — closed prematurely while delivery PR #$DELIVERY_PR is still open."
