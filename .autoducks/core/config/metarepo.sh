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

# metarepo::serialize_per_module → exit 0 when metarepo.serialize_per_module is
# true (strict per-child ordering), else 1 (default: concurrent + resolver-healed).
metarepo::serialize_per_module() {
  metarepo::enabled || return 1
  [[ "$(jq -r '.metarepo.serialize_per_module // false' "$AUTODUCKS_ROOT/autoducks.json")" == "true" ]]
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

# metarepo::delivered_children_from_body BODY → one delivered submodule path per
# line, declared in a PR body via the `<!-- autoducks:delivered-children: a,b -->`
# marker Maestro stamps. Structured read — never fuzzy text parsing. Empty when
# the marker is absent.
metarepo::delivered_children_from_body() {
  local body="$1" line
  line="$(printf '%s\n' "$body" | grep -oE '<!-- autoducks:delivered-children:[^>]*-->' | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  line="${line#<!-- autoducks:delivered-children:}"
  line="${line%-->}"
  # Commas → spaces, then word-split (module paths never contain spaces). This
  # trims surrounding whitespace and drops empties without the trailing-newline
  # pitfall of `while read`.
  local m
  for m in ${line//,/ }; do
    printf '%s\n' "$m"
  done
}

# metarepo::delivered_children_marker CHILDREN → the structured
# `<!-- autoducks:delivered-children: a,b -->` marker line for CHILDREN (a
# comma- or space-separated list of module paths), or empty when CHILDREN is
# empty. Companion writer to metarepo::delivered_children_from_body (the
# reader); Maestro stamps this onto the final PR body at delivery time so the
# poller never recomputes the affected set from task issues.
metarepo::delivered_children_marker() {
  local children="$1" csv
  csv="$(printf '%s' "$children" | tr -s ' ,\t\n' ',' | sed -e 's/^,//' -e 's/,$//')"
  [[ -n "$csv" ]] || return 0
  printf '<!-- autoducks:delivered-children: %s -->\n' "$csv"
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

# metarepo::repin_gitlinks(feature_branch, path=sha ...) — re-point parent
# gitlinks to the given (post-delivery) child SHAs on the feature branch, then
# push. Used after a squash/rebase child delivery, where the child's default
# branch was rewritten to a new SHA that the parent must now pin instead of the
# abandoned pre-merge SHA. On a successful push, deletes the (now unreferenced)
# retained child feature branches. Uses `git update-index --cacheinfo`, so no
# submodule working tree needs to be initialized.
metarepo::repin_gitlinks() {
  local feature_branch="$1"; shift
  local token; token="$(git::resolve_token "${REPO:-}")"

  git::configure_identity 2>/dev/null || true
  [[ -n "$token" ]] && git remote set-url origin "https://x-access-token:${token}@github.com/${REPO}.git"
  git fetch -q origin "$feature_branch" 2>/dev/null || { echo "::warning::repin: cannot fetch $feature_branch" >&2; return 1; }
  git checkout -q -B "$feature_branch" "origin/$feature_branch" 2>/dev/null || { echo "::warning::repin: cannot checkout $feature_branch" >&2; return 1; }

  local pair path sha changed=0
  for pair in "$@"; do
    path="${pair%%=*}"; sha="${pair#*=}"
    [[ -z "$path" || -z "$sha" ]] && continue
    git update-index --cacheinfo "160000,${sha},${path}" 2>/dev/null && changed=1
  done
  [[ "$changed" == 1 ]] || return 0

  git commit -q -m "chore(metarepo): re-pin submodule gitlinks to delivered SHAs" 2>/dev/null || return 0
  if git push -q origin "HEAD:refs/heads/${feature_branch}" 2>/dev/null; then
    echo "::notice::repin: re-pinned submodule gitlink(s) on $feature_branch" >&2
    # The pre-merge SHAs are now unreferenced — delete the retained child branches.
    for pair in "$@"; do
      path="${pair%%=*}"
      local slug ctok; slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
      [[ -n "$slug" ]] || continue
      ctok="$(git::resolve_token "$slug")"
      GH_TOKEN="$ctok" gh api "repos/$slug/git/refs/heads/${feature_branch}" -X DELETE --silent 2>/dev/null || true
    done
  else
    echo "::warning::repin: failed to push re-pinned gitlinks to $feature_branch — child feature branches kept (pre-merge SHA still reachable)." >&2
    return 1
  fi
}

# metarepo::pin_relation(slug, pinned_sha, tip_sha) → one of
#   identical | behind | ahead | diverged | unknown
# describing where the currently pinned SHA sits relative to the child's
# default-branch tip. `behind` is the only safe direction to reconcile in: the
# pin is an ancestor of the tip, so moving it forward is a fast-forward that adds
# no history the parent had not already accepted. `ahead` means the child has not
# merged yet (an async auto-merge still pending) and moving the pin would regress
# it; `diverged` means something rewrote the child's history and a human should
# look. Uses the compare API with base=tip, head=pin, so GitHub's own answer
# decides — no local clone of the child is needed.
metarepo::pin_relation() {
  local slug="$1" pinned="$2" tip="$3"
  [[ -n "$slug" && -n "$pinned" && -n "$tip" ]] || { echo unknown; return 0; }
  [[ "$pinned" == "$tip" ]] && { echo identical; return 0; }
  local token status
  token="$(git::resolve_token "$slug")"
  status="$(GH_TOKEN="$token" gh api "repos/$slug/compare/${tip}...${pinned}" --jq '.status' 2>/dev/null || true)"
  case "$status" in
    identical|behind|ahead|diverged) echo "$status" ;;
    *) echo unknown ;;
  esac
}

# metarepo::reconcile_gitlinks(head_branch, path ...) — bring a parent PR's
# gitlinks back in line with each child's *current* default-branch tip, then push
# to head_branch. Returns 0 when nothing needed doing or the push succeeded.
#
# This is the late reconciliation half of the pin contract (#119b). Two things
# make it necessary, and neither is knowable when the pin is first written:
#
#   1. An async auto-merge delivery cannot report the SHA it will produce, so the
#      pin written at delivery time is provisional until the child PR merges.
#   2. Nothing rebases an open parent PR's gitlink when the parent's default
#      branch moves. Two parent PRs open at once means the first to merge leaves
#      the second pinning a SHA that no longer matches its base — a gitlink is an
#      opaque SHA and GitHub's 3-way merge conflicts on it, reachable or not.
#      That is exactly how meta#108 went CONFLICTING 4 minutes after meta#97
#      moved main's gitlink.
#
# Only fast-forwards are applied (see metarepo::pin_relation); anything else is
# reported and left alone, so this can never quietly move a pin backwards or
# across rewritten history.
metarepo::reconcile_gitlinks() {
  local head_branch="$1"; shift
  local token; token="$(git::resolve_token "${REPO:-}")"

  git::configure_identity 2>/dev/null || true
  if [[ -n "$token" ]]; then
    git remote set-url origin "https://x-access-token:${token}@github.com/${REPO}.git"
  fi
  git fetch -q origin "$head_branch" 2>/dev/null || { echo "::warning::reconcile: cannot fetch $head_branch" >&2; return 1; }
  git checkout -q -B "$head_branch" "origin/$head_branch" 2>/dev/null || { echo "::warning::reconcile: cannot checkout $head_branch" >&2; return 1; }

  local path slug ctok default_branch tip pinned relation changed=0
  for path in "$@"; do
    [[ -n "$path" ]] || continue
    slug="$(metarepo::slug_for_path "$path" 2>/dev/null || true)"
    [[ -n "$slug" ]] || continue
    pinned="$(git rev-parse "HEAD:$path" 2>/dev/null || true)"
    [[ -n "$pinned" ]] || continue
    ctok="$(git::resolve_token "$slug")"
    default_branch="$(GH_TOKEN="$ctok" gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
    tip="$(GH_TOKEN="$ctok" gh api "repos/$slug/commits/$default_branch" --jq '.sha' 2>/dev/null || true)"
    [[ -n "$tip" ]] || { echo "::warning::reconcile: cannot read $slug $default_branch tip — leaving '$path' pinned at $pinned" >&2; continue; }

    relation="$(metarepo::pin_relation "$slug" "$pinned" "$tip")"
    case "$relation" in
      identical)
        ;;
      behind)
        if git update-index --cacheinfo "160000,${tip},${path}" 2>/dev/null; then
          changed=1
          echo "::notice::reconcile: '$path' → $tip (was $pinned, a fast-forward on $slug $default_branch)" >&2
        fi
        ;;
      ahead)
        echo "::notice::reconcile: '$path' pin $pinned is ahead of $slug $default_branch ($tip) — delivery has not merged yet, leaving it alone." >&2
        ;;
      *)
        echo "::warning::reconcile: '$path' pin $pinned and $slug $default_branch ($tip) are $relation — refusing to move the gitlink automatically." >&2
        ;;
    esac
  done
  [[ "$changed" == 1 ]] || return 0

  git commit -q -m "chore(metarepo): reconcile submodule gitlinks with child default branches" 2>/dev/null || return 0
  if git push -q origin "HEAD:refs/heads/${head_branch}" 2>/dev/null; then
    echo "::notice::reconcile: pushed reconciled gitlink(s) to $head_branch" >&2
    # STDOUT contract: the new head SHA, and only when a reconcile was actually
    # pushed. Callers use it to attach anything anchored on the old head (the
    # delivery check-run) to the commit that superseded it; an empty stdout means
    # "nothing moved", which must not be confused with a branch that merely
    # advanced for unrelated reasons.
    git rev-parse HEAD
    return 0
  fi
  echo "::warning::reconcile: could not push reconciled gitlinks to $head_branch (raced with another push?) — the next run retries." >&2
  return 1
}

# metarepo::agent_context_block → the runtime "you ARE in metarepo mode" signal
# injected into the engineer/developer LLM inputs. Without this, an agent can't
# tell it's a metarepo and edits the metarepo's OWN .autoducks/ machinery instead
# of the target submodule (silent, since those paths collide).
metarepo::agent_context_block() {
  local p slug
  echo "## ⚙️ Metarepo mode — RUNTIME SIGNAL (you ARE operating in a metarepo)"
  echo
  echo "This repository is a **metarepo**: its children are git submodules. Feature work"
  echo "does **not** go in this repo's own files — each child lives under its submodule dir:"
  echo
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    slug="$(metarepo::slug_for_path "$p" 2>/dev/null || true)"
    echo "- \`$p/\` → ${slug:-$p}"
  done < <(metarepo::submodule_paths)
  echo
  echo "**Mandatory rules:**"
  echo "- All work for a child happens **inside its submodule directory** (e.g. \`autoducks/.autoducks/...\`), **never** the metarepo's own root \`.autoducks/\` or \`.github/\`."
  echo "- The metarepo's OWN \`.autoducks/\`, \`.github/\`, and root files are the metarepo's machinery — **never edit them for a feature**."
  echo "- A design that references a path like \`.autoducks/runtimes/...\` means that path **inside the target submodule** (\`<module>/.autoducks/runtimes/...\`)."
  echo "- **Engineer:** tag every task's \`**Modules:**\` with the submodule path(s) it changes (e.g. \`autoducks\`). This is required, not optional."
  echo "- **Developer:** only edit files under the task's declared module directories; if the task needs a file outside them, stop rather than editing the metarepo root."
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
    delivered) metarepo::delivered_children_from_body "${2:-}" ;;
    --help|*)
      echo "Usage: metarepo.sh {paths|slug PATH|owner PATH}"
      echo "  Config helpers mapping a submodule path -> child repo slug via .gitmodules" ;;
  esac
fi
