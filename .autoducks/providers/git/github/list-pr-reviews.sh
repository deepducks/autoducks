#!/usr/bin/env bash
set -euo pipefail

# List all review feedback for a pull request as a single combined JSON array:
#   - formal reviews:              {author, state, body, submittedAt}
#   - inline review-thread comments: {author, path, line, body, createdAt}
# Degrades gracefully: any failure to fetch either half yields an empty
# array for that half rather than aborting (never fails the caller).
git::list_pr_reviews() {
  local pr_number="$1"

  local reviews_json threads_json
  reviews_json="$(gh pr view "$pr_number" --repo "$REPO" --json reviews 2>/dev/null || echo '{}')"
  threads_json="$(gh api "repos/$REPO/pulls/$pr_number/comments" 2>/dev/null || echo '[]')"

  jq -c -n \
    --argjson reviews "$reviews_json" \
    --argjson threads "$threads_json" '
      (
        try (
          [$reviews.reviews[]? | {
            author: (.author.login // ""),
            state: (.state // ""),
            body: (.body // ""),
            submittedAt: (.submittedAt // "")
          }]
        ) catch []
      ) + (
        try (
          [$threads[]? | {
            author: (.user.login // ""),
            path: (.path // ""),
            line: (.line // null),
            body: (.body // ""),
            createdAt: (.created_at // "")
          }]
        ) catch []
      )
    ' 2>/dev/null || echo '[]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::list_pr_reviews PR_NUMBER"; echo "  List formal reviews and inline review-thread comments (JSON array)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
