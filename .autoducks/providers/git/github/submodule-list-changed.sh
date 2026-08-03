#!/usr/bin/env bash
set -euo pipefail

# git::submodule_list_changed() — print each submodule path (from .gitmodules)
# that carries a change in the working tree: either dirty content inside the
# submodule, or a gitlink the parent sees as moved. Ground truth for the
# developer drift guard (changed ⊆ declared modules).
git::submodule_list_changed() {
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -d "$p" ]] || continue
    # Dirty content inside the child, or the parent sees a gitlink change.
    if [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]] \
       || [[ -n "$(git status --porcelain -- "$p" 2>/dev/null)" ]]; then
      printf '%s\n' "$p"
    fi
  done < <(metarepo::submodule_paths)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submodule_list_changed"; echo "  List submodule paths with working-tree changes (metarepo mode)"; exit 0 ;;
  esac
fi
