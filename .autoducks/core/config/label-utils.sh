#!/usr/bin/env bash
# Case-insensitive label matching and create-or-reconcile for $REPO. Single
# source of truth so progress-labels.sh, classify-label.sh, and set-priority.sh
# don't each grow their own case-folding logic. Requires $REPO and gh in the
# caller's environment for every function except the *_in_list helpers, which
# are pure string operations usable with no network and no $REPO. This module
# sources nothing itself: the dependency runs one way, callers → label-utils.sh.

# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_LABEL_UTILS_SH_LOADED:-}" ]] && return 0
readonly _LABEL_UTILS_SH_LOADED=1

# Process-local cache: lowercased name → actual casing on $REPO. Populated by
# label::load, invalidated by label::_invalidate.
declare -gA _LABEL_UTILS_CACHE=()
_LABEL_UTILS_CACHE_LOADED=0

# label::_invalidate — clear the cache and the loaded flag, forcing the next
# label::load to make a fresh `gh label list` call.
label::_invalidate() {
  _LABEL_UTILS_CACHE=()
  _LABEL_UTILS_CACHE_LOADED=0
}

# label::load
#   Fetch every label on $REPO exactly once into the process-local cache.
#   Limit is AUTODUCKS_LABEL_LIST_LIMIT (default 500) — gh paginates
#   internally. Idempotent; a second call is a no-op unless label::_invalidate
#   ran.
label::load() {
  [[ "$_LABEL_UTILS_CACHE_LOADED" -eq 1 ]] && return 0

  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    _LABEL_UTILS_CACHE["${name,,}"]="$name"
  done < <(gh label list --repo "$REPO" \
    --limit "${AUTODUCKS_LABEL_LIST_LIMIT:-500}" \
    --json name --jq '.[].name' 2>/dev/null)

  _LABEL_UTILS_CACHE_LOADED=1
}

# label::resolve NAME → the label's actual casing on $REPO, or empty
#   Case-insensitive lookup. GitHub label names are case-insensitively unique,
#   so the answer is unambiguous: at most one match exists.
label::resolve() {
  local name="$1"
  label::load
  printf '%s' "${_LABEL_UTILS_CACHE["${name,,}"]:-}"
}

# label::exists NAME → 0/1   (case-insensitive)
label::exists() {
  local name="$1"
  label::load
  [[ -n "${_LABEL_UTILS_CACHE["${name,,}"]:-}" ]]
}

# label::in_list LIST NAME → 0/1
#   LIST is a newline-separated label list (the shape every caller already has
#   from `jq -r '.labels[]'`). Case-insensitive whole-line match. Pure string
#   operation: no gh call, no cache access, no $REPO required.
label::in_list() {
  local list="$1" name="$2" line
  local name_lc="${name,,}"
  while IFS= read -r line; do
    [[ "${line,,}" == "$name_lc" ]] && return 0
  done <<< "$list"
  return 1
}

# label::any_in_list LIST NAME... → 0/1
label::any_in_list() {
  local list="$1"
  shift
  local name
  for name in "$@"; do
    label::in_list "$list" "$name" && return 0
  done
  return 1
}

# label::has_prefix_in_list LIST PREFIX → prints matching lines (case-insensitive)
#   Backs the Priority:* sweep in set-priority.sh. Pure string operation: no
#   gh call, no cache access, no $REPO required. Returns 0 if at least one
#   line matched, 1 otherwise.
label::has_prefix_in_list() {
  local list="$1" prefix="$2" line line_head
  local prefix_lc="${prefix,,}"
  local plen=${#prefix_lc}
  local found=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line_head="${line:0:plen}"
    if [[ "${line_head,,}" == "$prefix_lc" ]]; then
      printf '%s\n' "$line"
      found=0
    fi
  done <<< "$list"
  return "$found"
}

# label::ensure NAME [COLOR] [DESCRIPTION]
#   Create-or-reconcile. Returns 0 on "the label now exists under NAME's exact
#   casing", 1 otherwise (and prints gh's stderr to stderr).
#     1. Cache hit under exact casing            → no-op.
#     2. Cache hit under different casing        → rename to NAME (see below).
#     3. Cache miss                              → gh label create.
#   Rename is skipped when AUTODUCKS_LABEL_AUTORENAME=0, in which case the
#   function returns 1 with an explanatory message.
#   The cache is updated in place after every successful create/rename, so a
#   caller looping over N labels still makes exactly one read call.
#
#   Rename issues `gh label edit "$existing" --repo "$REPO" --name "$NAME"` —
#   name only. Color and description of a pre-existing label are left alone;
#   newly created labels get the canonical color/description from the caller.
label::ensure() {
  local name="$1" color="${2:-}" desc="${3:-}"
  local name_lc="${name,,}"
  label::load

  local existing="${_LABEL_UTILS_CACHE["$name_lc"]:-}"
  local err

  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$name" ]] && return 0

    if [[ "${AUTODUCKS_LABEL_AUTORENAME:-1}" == "0" ]]; then
      echo "label::ensure: found '$existing' but AUTODUCKS_LABEL_AUTORENAME=0 disables renaming to canonical name '$name'" >&2
      return 1
    fi

    if err="$(gh label edit "$existing" --repo "$REPO" --name "$name" 2>&1 >/dev/null)"; then
      _LABEL_UTILS_CACHE["$name_lc"]="$name"
      return 0
    fi
    echo "$err" >&2
    return 1
  fi

  local args=(gh label create "$name" --repo "$REPO")
  [[ -n "$color" ]] && args+=(--color "$color")
  [[ -n "$desc" ]] && args+=(--description "$desc")

  if err="$("${args[@]}" 2>&1 >/dev/null)"; then
    _LABEL_UTILS_CACHE["$name_lc"]="$name"
    return 0
  fi
  echo "$err" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help)
      echo "Usage: source label-utils.sh"
      echo "  Case-insensitive label matching and create-or-reconcile for \$REPO"
      echo "  label::load                              - fetch every label once (cached)"
      echo "  label::resolve NAME                      - actual casing on \$REPO, or empty"
      echo "  label::exists NAME                       - 0/1, case-insensitive"
      echo "  label::in_list LIST NAME                 - 0/1, whole-line case-insensitive match"
      echo "  label::any_in_list LIST NAME...          - 0/1, any match"
      echo "  label::has_prefix_in_list LIST PREFIX    - print case-insensitive prefix matches"
      echo "  label::ensure NAME [COLOR] [DESCRIPTION] - create-or-reconcile"
      echo "  Requires: REPO, gh env (except the *_in_list helpers, which need neither)"
      echo "  Env: AUTODUCKS_LABEL_LIST_LIMIT (default 500), AUTODUCKS_LABEL_AUTORENAME (default 1)"
      exit 0
      ;;
  esac
fi
