#!/usr/bin/env bash
set -euo pipefail

# git::commit_push_recursive(child_branch, commit_msg) — the ordered
# submodules-first commit/push dance from HANDOFF.md. For every changed child:
# commit its work onto the mirrored child feature branch and push it. Then stage
# the parent's gitlink bumps (+ any parent-only files) and commit locally. The
# parent branch push stays with the caller (git::push_branch), which guarantees
# children are always pushed *before* the parent points at their new SHAs — else
# a fresh clone hits `reference is not a tree`.
#
# Assumes each child has already been checked out onto `child_branch`
# (developer/pre.sh does `git submodule foreach ... checkout -B`). Falls back to
# `HEAD:refs/heads/<branch>` on push so a detached child still lands on the branch.
git::commit_push_recursive() {
  local child_branch="$1"
  local commit_msg="$2"

  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -d "$p" ]] || continue

    git -C "$p" add -A
    if ! git -C "$p" diff --cached --quiet 2>/dev/null; then
      ( cd "$p" && git::configure_identity )
      git -C "$p" commit -m "$commit_msg" >/dev/null || true
    fi

    git::submodule_remote "$p"
    git -C "$p" push origin "HEAD:refs/heads/${child_branch}"
  done < <(git::submodule_list_changed)

  # Parent: record the new gitlinks + any parent-only files. The parent push is
  # the caller's responsibility (after this returns, so children are already up).
  git add -A
  git commit -m "$commit_msg" >/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::commit_push_recursive CHILD_BRANCH COMMIT_MSG"; echo "  Commit+push changed submodules first, then commit parent gitlinks (metarepo mode)"; exit 0 ;;
  esac
fi
