#!/usr/bin/env bash
# release.sh — cuts the v<semver> tags the "stable" channel resolves against.
# Upstream-only: deliberately absent from install.sh's scripts/ copy loop so
# it never lands in a consumer repo. Sources semver.sh for bump arithmetic and
# changelog.sh for CHANGELOG.md section handling.
#
# Usage: scripts/release.sh [--major|--minor|--patch] [--dry-run]
#   No flag: the next version is inferred from commit subjects since the last
#   v* tag ('!'/'BREAKING CHANGE:' -> major, 'feat' -> minor, else patch) and
#   the inference is printed for confirmation. An explicit flag always wins.
#
#   1. Refuses unless on the default branch, the tree is clean, and the
#      target tag does not already exist.
#   2. Computes VERSION -> next version.
#   3. Writes VERSION, inserts a CHANGELOG.md section seeded with the
#      harvested commit subjects, commits, tags, and pushes both.

[[ -n "${_RELEASE_SH_LOADED:-}" ]] && return 0
readonly _RELEASE_SH_LOADED=1

set -uo pipefail

_RELEASE_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RELEASE_SH_REPO_ROOT="$(cd "$_RELEASE_SH_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$_RELEASE_SH_REPO_ROOT/.autoducks/core/config/semver.sh"
# shellcheck source=/dev/null
source "$_RELEASE_SH_REPO_ROOT/.autoducks/core/config/changelog.sh"

: "${AUTODUCKS_ROOT:=.autoducks}"

# Conventional-commit subject patterns. Held in variables (not inlined) so
# the parens are never handed to bash's own parser on the [[ =~ ]] RHS.
_RELEASE_RE_BREAKING='^[a-zA-Z]+(\([^)]*\))?!:'
_RELEASE_RE_FEAT='^feat(\([^)]*\))?:'
_RELEASE_RE_FIX='^fix(\([^)]*\))?:'

release::usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--major|--minor|--patch] [--dry-run]

Upstream-only release tooling. Refuses unless run on the default branch with
a clean working tree and no existing tag for the target version.

  --major, --minor, --patch  Force the bump kind. Without one, the kind is
                              inferred from commit subjects since the last
                              v* tag and printed for confirmation.
  --dry-run                  Print the computed version, the changelog
                              section, and the tag; mutate nothing.
EOF
}

release::die() {
  echo "release: $1" >&2
  exit 1
}

# release::assert_branch_pushable BRANCH TAG — die when a direct push to BRANCH will
# be refused by branch protection.
#
# The release commit goes straight to the default branch. That works only while
# admins can bypass protection; with enforce_admins on, the push is rejected and
# the tag is already made locally by then. Advisory only: an unreadable
# protection API (no admin scope, or no protection at all) is not a failure.
release::assert_branch_pushable() {
  local branch="$1" slug protection
  slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  [[ -n "$slug" ]] || return 0

  protection="$(gh api "repos/$slug/branches/$branch/protection" 2>/dev/null || true)"
  [[ -n "$protection" ]] || return 0

  local enforced checks
  enforced="$(printf '%s' "$protection" | jq -r '.enforce_admins.enabled // false')"
  checks="$(printf '%s' "$protection" | jq -r '[.required_status_checks.contexts // []] | flatten | length')"
  [[ "$enforced" == "true" && "${checks:-0}" -gt 0 ]] || return 0

  release::die "refusing — '$branch' requires status checks and enforces them on
    admins, so the release commit cannot be pushed directly and this would
    leave a local commit and tag behind.

    Cut the release through a pull request instead:

      git checkout -b release/$2
      # re-run: scripts/release.sh writes VERSION + CHANGELOG on this branch
      gh pr create --fill && gh pr merge --squash --auto

    then tag the merged commit on $branch and push the tag."
}

# release::current_version — trimmed contents of $AUTODUCKS_ROOT/VERSION
release::current_version() {
  local f="$AUTODUCKS_ROOT/VERSION"
  [[ -f "$f" ]] || return 1
  tr -d '[:space:]' < "$f"
}

release::current_branch() {
  git rev-parse --abbrev-ref HEAD
}

# release::default_branch — gh's view of the repo's default branch, falling
# back to origin/HEAD's target, falling back to "main".
release::default_branch() {
  local db=""
  if command -v gh &>/dev/null; then
    db="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  fi
  if [[ -z "$db" ]]; then
    local ref
    ref="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
    [[ -n "$ref" ]] && db="${ref#refs/remotes/origin/}"
  fi
  printf '%s' "${db:-main}"
}

# release::last_tag — most recent v* tag reachable from HEAD, or empty
release::last_tag() {
  git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true
}

# release::commit_subjects_since TAG — one commit subject per line, from TAG
# (exclusive) to HEAD; every commit reachable from HEAD when TAG is empty.
release::commit_subjects_since() {
  local tag="$1"
  if [[ -n "$tag" ]]; then
    git log --format='%s' "$tag"..HEAD 2>/dev/null || true
  else
    git log --format='%s' HEAD 2>/dev/null || true
  fi
}

# release::classify_subject SUBJECT -> major|minor|patch
release::classify_subject() {
  local subject="$1"
  if [[ "$subject" =~ $_RELEASE_RE_BREAKING ]] || [[ "$subject" == *"BREAKING CHANGE:"* ]]; then
    printf 'major'
  elif [[ "$subject" =~ $_RELEASE_RE_FEAT ]]; then
    printf 'minor'
  else
    printf 'patch'
  fi
}

# release::infer_bump SUBJECT... -> the highest-severity classification
# across all subjects (major > minor > patch); "patch" when none are given.
release::infer_bump() {
  local subject kind best="patch"
  for subject in "$@"; do
    kind="$(release::classify_subject "$subject")"
    if [[ "$kind" == "major" ]]; then
      best="major"
      break
    elif [[ "$kind" == "minor" && "$best" != "major" ]]; then
      best="minor"
    fi
  done
  printf '%s' "$best"
}

# release::bump_version VERSION KIND -> next x.y.z
release::bump_version() {
  local version="$1" kind="$2"
  local IFS=. parts
  read -ra parts <<<"$version"
  local major="${parts[0]:-0}" minor="${parts[1]:-0}" patch="${parts[2]:-0}"
  case "$kind" in
    major) printf '%d.%d.%d' "$((major + 1))" 0 0 ;;
    minor) printf '%d.%d.%d' "$major" "$((minor + 1))" 0 ;;
    patch) printf '%d.%d.%d' "$major" "$minor" "$((patch + 1))" ;;
    *) return 1 ;;
  esac
}

# release::changelog_section VERSION DATE SUBJECT... -> the '## [VERSION] -
# DATE' markdown block, harvested subjects bucketed by Keep-a-Changelog
# category. A 'feat!'/'BREAKING CHANGE:' subject lands under ### Breaking
# with a stub the human is expected to edit with the actual breaking-change
# prose.
release::changelog_section() {
  local version="$1" date="$2"
  shift 2
  local -a breaking=() added=() fixed=() changed=()
  local subject
  for subject in "$@"; do
    if [[ "$subject" =~ $_RELEASE_RE_BREAKING ]] || [[ "$subject" == *"BREAKING CHANGE:"* ]]; then
      breaking+=("$subject")
    elif [[ "$subject" =~ $_RELEASE_RE_FEAT ]]; then
      added+=("$subject")
    elif [[ "$subject" =~ $_RELEASE_RE_FIX ]]; then
      fixed+=("$subject")
    else
      changed+=("$subject")
    fi
  done

  printf '## [%s] - %s\n' "$version" "$date"
  if [[ "${#breaking[@]}" -gt 0 ]]; then
    printf '\n### Breaking\n'
    printf -- '- %s\n' "${breaking[@]}"
    echo "(edit this section with the actual breaking-change prose)" >&2
  fi
  if [[ "${#added[@]}" -gt 0 ]]; then
    printf '\n### Added\n'
    printf -- '- %s\n' "${added[@]}"
  fi
  if [[ "${#fixed[@]}" -gt 0 ]]; then
    printf '\n### Fixed\n'
    printf -- '- %s\n' "${fixed[@]}"
  fi
  if [[ "${#changed[@]}" -gt 0 ]]; then
    printf '\n### Changed\n'
    printf -- '- %s\n' "${changed[@]}"
  fi
  if [[ "${#breaking[@]}" -eq 0 && "${#added[@]}" -eq 0 && "${#fixed[@]}" -eq 0 && "${#changed[@]}" -eq 0 ]]; then
    printf '\n### Changed\n- No commit subjects harvested for this release.\n'
  fi
}

# release::insert_changelog_section FILE SECTION — insert SECTION (no
# trailing newline) immediately before the file's first '## [' heading, or
# append it (creating a '# Changelog' preamble first) when there is none.
release::insert_changelog_section() {
  local file="$1" section="$2"
  local -a out=()
  local line inserted=0

  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$inserted" -eq 0 && "$line" == '## ['* ]]; then
        out+=("$section" "")
        inserted=1
      fi
      out+=("$line")
    done < "$file"
  else
    out+=("# Changelog" "")
  fi

  [[ "$inserted" -eq 0 ]] && out+=("$section")

  printf '%s\n' "${out[@]}" > "$file"
}

release::main() {
  local kind="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --major|--minor|--patch)
        [[ -n "$kind" ]] && release::die "pass only one of --major/--minor/--patch"
        kind="${1#--}"
        shift
        ;;
      --dry-run) dry_run=true; shift ;;
      -h|--help) release::usage; return 0 ;;
      *) release::die "unknown option: $1 (usage: release.sh [--major|--minor|--patch] [--dry-run])" ;;
    esac
  done

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || release::die "not inside a git repository"
  cd "$repo_root" || release::die "could not cd to repo root $repo_root"

  local branch default_branch
  branch="$(release::current_branch)"
  default_branch="$(release::default_branch)"
  [[ "$branch" == "$default_branch" ]] || \
    release::die "refusing — on branch '$branch', not the default branch '$default_branch'; checkout '$default_branch' and try again"

  [[ -z "$(git status --porcelain)" ]] || \
    release::die "refusing — working tree is dirty; commit or stash your changes before releasing"

  local current
  current="$(release::current_version)" || release::die "could not read a version from $AUTODUCKS_ROOT/VERSION"

  local last
  last="$(release::last_tag)"
  local -a subjects=()
  local subj
  while IFS= read -r subj; do
    [[ -n "$subj" ]] && subjects+=("$subj")
  done < <(release::commit_subjects_since "$last")

  if [[ -n "$kind" ]]; then
    echo "release: bump requested via --$kind" >&2
  else
    kind="$(release::infer_bump "${subjects[@]}")"
    echo "release: no bump flag given — inferred '$kind' from ${#subjects[@]} commit subject(s) since ${last:-the beginning of history} (advisory; pass --major/--minor/--patch to override)" >&2
  fi

  local next
  next="$(release::bump_version "$current" "$kind")" || release::die "could not compute a '$kind' bump from version '$current'"

  local check_kind
  check_kind="$(semver::bump_kind "$current" "$next")"
  [[ "$check_kind" == "$kind" ]] || \
    release::die "internal error: $current -> $next does not read back as a $kind bump (got $check_kind)"

  local tag="v$next"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 && \
    release::die "refusing — tag '$tag' already exists; delete it or bump a different component"

  # Step 5 commits, tags, and only then pushes the branch. If the branch push is
  # going to be refused, finding out there leaves a local release commit and tag
  # behind that the operator has to unwind by hand. Check first.
  release::assert_branch_pushable "$default_branch" "$tag"

  local date
  date="$(date -u +%Y-%m-%d)"
  local section
  section="$(release::changelog_section "$next" "$date" "${subjects[@]}")"

  if [[ "$dry_run" == "true" ]]; then
    echo "Current version: $current"
    echo "Next version:    $next ($kind)"
    echo "Tag:             $tag"
    echo ""
    echo "Changelog section that would be inserted:"
    echo "---"
    printf '%s\n' "$section"
    echo "---"
    echo "Dry run: nothing was written."
    return 0
  fi

  printf '%s\n' "$next" > "$AUTODUCKS_ROOT/VERSION"
  release::insert_changelog_section "$(changelog::_file)" "$section"

  git add "$AUTODUCKS_ROOT/VERSION" "$(changelog::_file)" || release::die "git add failed"
  git commit -q -m "chore(release): $tag" || release::die "git commit failed"
  git tag "$tag" || release::die "git tag failed"
  git push origin "$default_branch" || release::die "git push of $default_branch failed (tag '$tag' was created locally — push it manually once resolved)"
  git push origin "$tag" || release::die "git push of tag '$tag' failed (branch push already succeeded)"

  echo "release: pushed $tag ($AUTODUCKS_ROOT/VERSION -> $next)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  release::main "$@"
fi
