#!/usr/bin/env bash
set -euo pipefail

# Reviewer/CODEOWNERS `read:org` scope errors from `gh pr create` must never
# fail PR creation outright: GitHub often creates the PR before hitting the
# scope error while requesting reviewers, so we recover the PR number instead
# of surfacing a false failure.
git::_find_open_pr_number() {
  local head="$1" base="$2"
  local num
  num="$(gh pr list --repo "$REPO" --head "$head" --base "$base" --state open --json number --jq '.[0].number' 2>/dev/null)"
  [[ -n "$num" && "$num" != "null" ]] || return 1
  echo "$num"
}

git::_warn_reviewer_scope() {
  local msg="$1"
  # git::create_pr's stdout is the PR-number contract callers rely on
  # (`PR_NUM=$(git::create_pr ...)`), so the warning must go to stderr.
  echo "::warning::$msg" >&2
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$msg" >> "$GITHUB_STEP_SUMMARY"
  fi
}

git::create_pr() {
  local head="$1" base="$2" title="$3" body="${4:-}" draft="${5:-false}"
  local args=(--repo "$REPO" --base "$base" --head "$head" --title "$title" --body "$body")
  [[ "$draft" == "true" ]] && args+=(--draft)

  local out rc
  out="$(gh pr create "${args[@]}" 2>&1)" && rc=0 || rc=$?

  local num
  num="$(grep -oE '/pull/[0-9]+' <<< "$out" | head -n1 | grep -oE '[0-9]+' || true)"

  if [[ "$rc" -eq 0 ]]; then
    if [[ -n "$num" ]]; then
      echo "$num"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi

  if grep -qiE 'read:org|required scopes|already exists' <<< "$out"; then
    [[ -n "$num" ]] || num="$(git::_find_open_pr_number "$head" "$base")" || num=""
    if [[ -n "$num" ]]; then
      git::_warn_reviewer_scope "gh pr create reported an error (likely a reviewer/CODEOWNERS read:org scope issue) but PR #$num for $head -> $base exists — recovered it instead of failing the run. Original error: $out"
      echo "$num"
      return 0
    fi
  fi

  echo "$out" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::create_pr HEAD BASE TITLE [BODY] [DRAFT]"; echo "  Create a pull request, returns PR number"; echo "  DRAFT: \"true\" to create as draft (default false)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
