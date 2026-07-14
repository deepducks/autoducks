#!/usr/bin/env bash
set -euo pipefail

# git::get_pr_diff(pr_number) — unified diff for a PR on stdout.
#
# In metarepo mode the parent PR carries only gitlink bumps
# (`-Subproject commit …`), which are useless for a reviewer. When a local
# checkout with submodules is available we instead emit the *expanded* diff
# (`git diff --submodule=diff base...head`) so the reviewer sees the real
# per-file code from every touched child. Falls back to the plain `gh pr diff`
# when not in metarepo mode or when the local refs aren't present.
git::get_pr_diff() {
  local pr_number="$1"

  if metarepo::enabled 2>/dev/null; then
    local base head
    base="$(gh pr view "$pr_number" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
    head="$(gh pr view "$pr_number" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
    if [[ -n "$base" && -n "$head" ]]; then
      git fetch origin "$base" "$head" >/dev/null 2>&1 || true
      if git rev-parse --verify "origin/$base" >/dev/null 2>&1 \
         && git rev-parse --verify "origin/$head" >/dev/null 2>&1; then
        # --submodule=diff inlines each child's real per-file diff.
        git diff --submodule=diff "origin/${base}...origin/${head}" 2>/dev/null && return 0
      fi
    fi
    echo "::warning::get_pr_diff: metarepo mode but could not expand submodule diff locally; falling back to gitlink diff." >&2
  fi

  gh pr diff "$pr_number" --repo "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::get_pr_diff PR_NUMBER"; echo "  Fetch the unified diff for a pull request (submodule-expanded in metarepo mode)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
