#!/usr/bin/env bash
# Metarepo (submodule aggregation) config helpers.
#
# Sourced by load-config.sh (and, transitively, by every agent). All behaviour
# here is inert unless AUTODUCKS_METAREPO=true, so single-repo installs pay
# nothing. The functions below map a submodule *path* (the gitlink in the parent
# tree) to the child repo's slug/owner by reading `.gitmodules` — the single
# source of truth for the parent→child relationship (repo/url/path are never
# duplicated in autoducks.json).
set -uo pipefail

# metarepo::enabled → exit 0 when running in metarepo mode.
metarepo::enabled() {
  [[ "${AUTODUCKS_METAREPO:-false}" == "true" ]]
}

# metarepo::gitmodules_file → absolute path to the parent's .gitmodules (or 1).
metarepo::gitmodules_file() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${AUTODUCKS_REPO_ROOT:-$PWD}")"
  local f="$root/.gitmodules"
  [[ -f "$f" ]] || return 1
  printf '%s\n' "$f"
}

# metarepo::submodule_paths → every submodule path declared in .gitmodules,
# one per line. Empty (exit 0) when there is no .gitmodules.
metarepo::submodule_paths() {
  local gm
  gm="$(metarepo::gitmodules_file)" || return 0
  git config -f "$gm" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'
}

# metarepo::_name_for_path PATH → the .gitmodules section name whose `.path`
# equals PATH (the name is not always equal to the path).
metarepo::_name_for_path() {
  local path="$1" gm
  gm="$(metarepo::gitmodules_file)" || return 1
  git config -f "$gm" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk -v p="$path" '$2==p { key=$1; sub(/\.path$/,"",key); sub(/^submodule\./,"",key); print key; exit }'
}

# metarepo::url_for_path PATH → the remote url declared in .gitmodules for PATH.
metarepo::url_for_path() {
  local path="$1" gm name
  gm="$(metarepo::gitmodules_file)" || return 1
  name="$(metarepo::_name_for_path "$path")" || return 1
  [[ -n "$name" ]] || return 1
  git config -f "$gm" --get "submodule.$name.url" 2>/dev/null
}

# metarepo::_slug_from_url URL → "owner/repo" for a GitHub remote, or empty for
# a non-GitHub remote (file://, relative path) so callers can treat it as a
# local/offline child that needs no token.
metarepo::_slug_from_url() {
  local url="$1"
  case "$url" in
    git@github.com:*)        url="${url#git@github.com:}" ;;
    ssh://git@github.com/*)  url="${url#ssh://git@github.com/}" ;;
    https://github.com/*)    url="${url#https://github.com/}" ;;
    http://github.com/*)     url="${url#http://github.com/}" ;;
    https://*@github.com/*)  url="${url#https://*@github.com/}" ;;
    *)                       printf '' ; return 0 ;;
  esac
  url="${url%.git}"
  url="${url%/}"
  printf '%s\n' "$url"
}

# metarepo::slug_for_path PATH → child repo slug "owner/repo" (empty for a
# non-GitHub / offline remote).
metarepo::slug_for_path() {
  local path="$1" url
  url="$(metarepo::url_for_path "$path")" || return 1
  metarepo::_slug_from_url "$url"
}

# metarepo::owner_for_path PATH → the child repo owner (empty when no slug).
metarepo::owner_for_path() {
  local slug
  slug="$(metarepo::slug_for_path "$1")" || return 1
  printf '%s\n' "${slug%%/*}"
}

# metarepo::modules_from_body BODY → space-separated module paths declared in a
# task issue body via the `<!-- autoducks:modules: a,b -->` marker parse-plan.py
# embeds. Structured read — never fuzzy text parsing. Empty when absent.
metarepo::modules_from_body() {
  local body="$1" line
  line="$(printf '%s\n' "$body" | grep -oE '<!-- autoducks:modules:[^>]*-->' | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  line="${line#<!-- autoducks:modules:}"
  line="${line%-->}"
  # Commas → spaces, then word-split (module paths never contain spaces). This
  # trims surrounding whitespace and drops empties without the trailing-newline
  # pitfall of `while read`.
  local m
  for m in ${line//,/ }; do
    printf '%s\n' "$m"
  done
}

# metarepo::commit_task(issue_num, child_branch, msg) — the metarepo commit path
# shared by developer/post.sh and fix/post.sh. Enforces the drift guard (changed
# submodules ⊆ the task's declared `**Modules:**`), then commits/pushes each
# changed child onto child_branch *before* staging the parent gitlinks
# (git::commit_push_recursive). Returns 1 (without pushing) on a drift violation,
# after posting a clear issue comment.
metarepo::commit_task() {
  local issue_num="$1" child_branch="$2" msg="$3"
  local declared changed c d ok body
  body="$(its::get_issue "$issue_num" | jq -r '.body' 2>/dev/null || true)"
  declared="$(metarepo::modules_from_body "$body" | tr '\n' ' ')"
  changed="$(git::submodule_list_changed | tr '\n' ' ')"
  for c in $changed; do
    ok=false
    for d in $declared; do [[ "$c" == "$d" ]] && { ok=true; break; }; done
    if [[ "$ok" != true ]]; then
      export AUTODUCKS_FAIL_CATEGORY="module_drift" AUTODUCKS_FAIL_PHASE="post"
      its::comment_issue "$issue_num" "🚧 **Drift guard:** this task changed submodule \`$c\`, which is **not** in its declared \`**Modules:**\` (\`${declared:-none}\`). Metarepo tasks may only touch declared modules so cross-module dependency ordering stays correct.

**Fix:** re-run \`$(autoducks_command_for engineer)\` to add \`$c\` to this task's modules, or restrict the change to the declared module(s)." 2>/dev/null || true
      echo "::error::metarepo drift guard: task #$issue_num changed undeclared module '$c' (declared: ${declared:-none})" >&2
      return 1
    fi
  done
  git::commit_push_recursive "$child_branch" "$msg"
}

# metarepo::validate_modules MOD... → exit 0 if every arg is a known submodule
# path, else print the offenders and exit 1.
metarepo::validate_modules() {
  local known unknown=() m
  known="$(metarepo::submodule_paths)"
  for m in "$@"; do
    [[ -z "$m" ]] && continue
    grep -qxF "$m" <<< "$known" || unknown+=("$m")
  done
  if [[ "${#unknown[@]}" -gt 0 ]]; then
    echo "metarepo: unknown module(s): ${unknown[*]}" >&2
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    paths)  metarepo::submodule_paths ;;
    slug)   metarepo::slug_for_path "${2:?path required}" ;;
    owner)  metarepo::owner_for_path "${2:?path required}" ;;
    modules) metarepo::modules_from_body "${2:-}" ;;
    --help|*)
      echo "Usage: metarepo.sh {paths|slug PATH|owner PATH}"
      echo "  Config helpers mapping a submodule path -> child repo slug via .gitmodules" ;;
  esac
fi
