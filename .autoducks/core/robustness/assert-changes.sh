#!/usr/bin/env bash
set -euo pipefail

# Assert that the agent made changes to the working tree
# Usage: assert_changes <base_branch>
# Exits 1 if no changes were made
assert_changes() {
  local base="$1"
  git add -A
  if git diff --cached --quiet; then
    if [[ "$(git::commits_ahead "$base")" -gt 0 ]]; then
      echo "::warning::No newly-staged changes, but this branch is ahead of base"
      return 0
    fi

    # Metarepo: the parent tree is the wrong place to look. All real code lives
    # in submodules, and a child whose working tree is dirty but whose HEAD has
    # not moved yet produces no staged change in the parent — `git add -A` does
    # not stage a submodule's uncommitted content. This runs before
    # metarepo::commit_task (which is what moves those HEADs), so the parent is
    # legitimately clean at this point and the check was reporting the exact
    # opposite of what the agent did (#182).
    if command -v metarepo::enabled >/dev/null 2>&1 && metarepo::enabled \
      && [[ -n "$(git::submodule_list_changed 2>/dev/null)" ]]; then
      echo "::notice::No parent-tree changes, but these submodules changed: $(git::submodule_list_changed | tr '\n' ' ')"
      return 0
    fi

    echo "::error::Agent made no changes to the codebase"
    return 1
  fi
  return 0
}
