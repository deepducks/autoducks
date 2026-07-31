#!/usr/bin/env bash
# =============================================================================
# Install / Update Script for autoducks
# =============================================================================
#
# USAGE
#   curl -fsSL https://raw.githubusercontent.com/deepducks/autoducks/main/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --repo OWNER/REPO
#   curl -fsSL .../install.sh | bash -s -- --no-setup
#   curl -fsSL .../install.sh | bash -s -- --channel edge
#   curl -fsSL .../install.sh | bash -s -- --source-repo OWNER/REPO --ref v0.2.0
#
# WHAT IT DOES
#   Downloads the .autoducks/ directory tree and copies runtime workflows
#   into .github/workflows/. On fresh install, runs setup automatically.
#   Records what was installed in .autoducks/.installed.json.
# =============================================================================

set -euo pipefail

# ── Self-exec guard ─────────────────────────────────────────────────────────
# Must be the very first thing this script does. When invoked as
# `bash scripts/install.sh` from inside the repo being installed into, this
# same file is later overwritten (it re-copies scripts/install.sh out of the
# downloaded tree, further down). Bash reads a script off disk incrementally
# as it executes it, so overwriting the file mid-run truncates/corrupts the
# still-running interpreter. Re-exec from a private temp copy so the running
# process never reads through the file it's about to replace. No-op when
# piped via `curl | bash` ($0 is not a real path inside the target repo then).
if [[ -z "${AUTODUCKS_SELF_EXEC_GUARD:-}" ]] && [[ -f "$0" ]]; then
  SELF_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  CWD_ABS="$(pwd)"
  if [[ "$SELF_ABS" == "$CWD_ABS"/* ]]; then
    SELF_TMP="$(mktemp)"
    cp "$SELF_ABS" "$SELF_TMP"
    chmod +x "$SELF_TMP"
    AUTODUCKS_SELF_EXEC_GUARD=1 exec bash "$SELF_TMP" "$@"
  fi
fi

SOURCE_REPO="deepducks/autoducks"
CHANNEL="stable"
REF=""

REPO=""
NO_SETUP=false
APP_MODE=false
LOCK_NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --no-setup) NO_SETUP=true; shift ;;
    # Enable the autoducks GitHub App broker by default in the installed
    # workflows (un-gates the mint step so no AUTODUCKS_APP variable is needed).
    # Used by the cloud/installer-workflow setup where the app is installed.
    --app-mode) APP_MODE=true; shift ;;
    # Pin the machinery to a specific ref (commit SHA/tag/branch) instead of
    # the channel default.
    --ref) REF="$2"; shift 2 ;;
    # Release channel used to pick a default ref when --ref is not given:
    # stable -> main, edge -> edge.
    --channel) CHANNEL="$2"; shift 2 ;;
    # Fetch the machinery from a different source repo (fork/private mirror)
    # instead of deepducks/autoducks.
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    # Free-form note recorded as .installed.json's installed_by field.
    --lock-note) LOCK_NOTE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REF" ]]; then
  # Channel semantics are defined by the updater (agents/update/run.sh) and the
  # updates reference: `stable` is the highest v<semver> tag, `edge` is the tip
  # of the source repo's default branch. The installer had them crossed —
  # `stable → main`, `edge → edge` — which broke both ways:
  #
  #   --channel edge  resolved to the literal ref "edge", which no repo has, so
  #                   the tarball fetch 404'd and the run died in tar with an
  #                   opaque "not in gzip format".
  #   --channel stable installed main's tip but recorded `channel: stable`, so
  #                   the first update resolved stable to an older *tag* and
  #                   proposed moving backwards.
  #
  # Resolve the same way the updater does, and fall back to the default branch
  # when no release has been cut yet (the bootstrap period), warning rather than
  # failing so a fresh install still works before the first tag exists.
  case "$CHANNEL" in
    stable|edge) ;;
    *) echo "Unknown --channel: $CHANNEL (expected stable or edge)" >&2; exit 1 ;;
  esac

  if [[ -n "${AUTODUCKS_SOURCE_DIR:-}" ]]; then
    # Offline seam: the tree comes from disk, so there is nothing to resolve a
    # ref against and no network to reach. Record the channel name itself, which
    # is what the lockfile is asked for in that mode.
    REF="$CHANNEL"
  else
    DEFAULT_BRANCH="$(curl -fsSL "https://api.github.com/repos/$SOURCE_REPO" 2>/dev/null \
      | grep -m1 '"default_branch"' | sed 's/.*: *"\(.*\)".*/\1/')"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
    if [[ "$CHANNEL" == "edge" ]]; then
      REF="$DEFAULT_BRANCH"
    else
      REF="$(curl -fsSL "https://api.github.com/repos/$SOURCE_REPO/tags?per_page=100" 2>/dev/null \
        | grep -o '"name": *"v[0-9]\+\.[0-9]\+\.[0-9]\+"' \
        | sed 's/.*"v/v/;s/"$//' \
        | sort -t. -k1.2,1n -k2,2n -k3,3n \
        | tail -n1)"
      if [[ -z "$REF" ]]; then
        echo "⚠️  $SOURCE_REPO has cut no releases yet — installing from $DEFAULT_BRANCH (bootstrap period)." >&2
        REF="$DEFAULT_BRANCH"
      fi
    fi
  fi
fi

if [[ -n "$LOCK_NOTE" ]]; then
  INSTALLED_BY="$LOCK_NOTE"
elif [[ -n "${GITHUB_WORKFLOW:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  INSTALLED_BY="${GITHUB_WORKFLOW}#${GITHUB_RUN_ID}"
else
  INSTALLED_BY="manual"
fi

FRESH_INSTALL=true
if [[ -f ".autoducks/autoducks.json" ]]; then
  FRESH_INSTALL=false
fi

if [[ "$FRESH_INSTALL" == "true" ]]; then
  echo "=== Installing autoducks ==="
else
  echo "=== Updating autoducks ==="
fi
echo ""

# Read any pre-existing lockfile before the tree is replaced, so its
# ref/sha/version can be carried forward as this run's "previous". Not
# stashed like the consumer-owned set below: it's output, not consumer state.
PREVIOUS_JSON="null"
if [[ -f ".autoducks/.installed.json" ]] && command -v jq &>/dev/null; then
  PREVIOUS_JSON="$(jq -c '{ref: (.ref // ""), sha: (.sha // ""), version: (.version // "")}' \
    ".autoducks/.installed.json" 2>/dev/null || echo "null")"
fi

# Resolve the ref to a commit SHA before downloading, so a mid-run upstream
# push cannot make the download and the recorded lockfile disagree.
RESOLVED_SHA=""
if command -v gh &>/dev/null; then
  RESOLVED_SHA="$(gh api "repos/${SOURCE_REPO}/commits/${REF}" --jq .sha 2>/dev/null || true)"
fi

# Download the full .autoducks/ tree via GitHub API (tarball), unless a
# local source dir is provided (e.g. for offline testing).
echo "Downloading .autoducks/ tree..."
CLEANUP_TMP=true
if [[ -n "${AUTODUCKS_SOURCE_DIR:-}" ]]; then
  TMP_DIR="$AUTODUCKS_SOURCE_DIR"
  CLEANUP_TMP=false
  echo "  Using local source dir: $TMP_DIR"
else
  TMP_DIR=$(mktemp -d)
  DOWNLOAD_REF="${RESOLVED_SHA:-$REF}"
  TARBALL_FILE="$(mktemp)"
  # -f matters: without it a 404 writes GitHub's JSON error body into the file
  # and the failure only surfaces several lines later as tar's "not in gzip
  # format", which says nothing about the ref that could not be found.
  if ! curl -fsSL "https://api.github.com/repos/${SOURCE_REPO}/tarball/${DOWNLOAD_REF}" -o "$TARBALL_FILE"; then
    rm -f "$TARBALL_FILE"
    echo "❌ Could not download ${SOURCE_REPO} at ref '${DOWNLOAD_REF}'." >&2
    echo "   Check that the ref exists (a tag like v0.2.0, a branch, or a SHA)." >&2
    exit 1
  fi
  if [[ -z "$RESOLVED_SHA" ]]; then
    # gh unavailable: derive the sha from the tarball's top-level directory,
    # the same directory --strip-components=1 strips off below.
    TARBALL_TOP_DIR="$(tar tzf "$TARBALL_FILE" | head -1)"
    TARBALL_TOP_DIR="${TARBALL_TOP_DIR%%/*}"
    RESOLVED_SHA="${TARBALL_TOP_DIR##*-}"
  fi
  tar xzf "$TARBALL_FILE" -C "$TMP_DIR" --strip-components=1
  rm -f "$TARBALL_FILE"
fi

# The consumer-owned set is the single source of truth for what install.sh
# must never clobber. Source it from the just-downloaded tree, not the local
# .autoducks/ (which may not exist yet on a fresh install, or may predate
# this file on an update from an older version).
# shellcheck source=/dev/null
source "$TMP_DIR/.autoducks/core/config/consumer-owned.sh"

# Copy .autoducks/ directory, preserving consumer-owned files across updates.
STASH_DIR=$(mktemp -d)
SECURITY_GUIDELINES_STASHED=false
for rel in "${AUTODUCKS_CONSUMER_OWNED[@]}"; do
  src=".autoducks/$rel"
  if [[ "$rel" == "security-guidelines.md" ]]; then
    # Only preserved when the consumer's copy differs from the incoming
    # template, so a never-edited file still receives upstream improvements.
    incoming="$TMP_DIR/.autoducks/$rel"
    if [[ -f "$src" ]] && [[ -f "$incoming" ]] && ! cmp -s "$src" "$incoming"; then
      mkdir -p "$STASH_DIR/$(dirname "$rel")"
      cp "$src" "$STASH_DIR/$rel"
      SECURITY_GUIDELINES_STASHED=true
    fi
    continue
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "$STASH_DIR/$(dirname "$rel")"
    cp -R "$src" "$STASH_DIR/$rel"
  elif [[ -f "$src" ]]; then
    mkdir -p "$STASH_DIR/$(dirname "$rel")"
    cp "$src" "$STASH_DIR/$rel"
  fi
done

rm -rf .autoducks
cp -R "$TMP_DIR/.autoducks" .autoducks

for rel in "${AUTODUCKS_CONSUMER_OWNED[@]}"; do
  stashed="$STASH_DIR/$rel"
  dest=".autoducks/$rel"
  if [[ -d "$stashed" ]]; then
    rm -rf "$dest"
    cp -R "$stashed" "$dest"
  elif [[ -f "$stashed" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$stashed" "$dest"
  fi
done

rm -rf "$STASH_DIR"
echo "  .autoducks/ installed"

if [[ "$FRESH_INSTALL" == "false" ]]; then
  if [[ "$SECURITY_GUIDELINES_STASHED" == "true" ]]; then
    echo "  security-guidelines.md: kept local edits (differs from incoming template)"
  else
    echo "  security-guidelines.md: replaced with incoming template (no local edits)"
  fi
fi

# Write the install lockfile after the copy, so any .installed.json riding in
# the tarball is overwritten by the real record of this run.
if command -v jq &>/dev/null; then
  VERSION_VALUE="$(cat .autoducks/VERSION 2>/dev/null || echo "")"
  INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg source_repo "$SOURCE_REPO" \
    --arg channel "$CHANNEL" \
    --arg ref "$REF" \
    --arg sha "$RESOLVED_SHA" \
    --arg version "$VERSION_VALUE" \
    --arg installed_at "$INSTALLED_AT" \
    --arg installed_by "$INSTALLED_BY" \
    --argjson previous "$PREVIOUS_JSON" \
    '{schemaVersion: 1, source_repo: $source_repo, channel: $channel, ref: $ref,
      sha: $sha, version: $version, installed_at: $installed_at,
      installed_by: $installed_by, previous: $previous}' \
    > .autoducks/.installed.json
  echo "  Lockfile written: .autoducks/.installed.json"
else
  echo "  Warning: jq not found, skipping .installed.json lockfile" >&2
fi

# Copy runtime workflows to .github/workflows/
mkdir -p .github/workflows
cp .autoducks/runtimes/github-actions/autoducks-*.yml .github/workflows/
echo "  Workflows copied to .github/workflows/"

# Prune stale mirrors: a .github/workflows/autoducks-*.yml left over from a
# runtime that was renamed/removed upstream has no counterpart in the new
# runtime templates and would otherwise linger forever.
#
# "No runtime template" is not sufficient on its own. Upstream-only workflows —
# autoducks-release.yml is one — live in .github/workflows/ by design and are
# deliberately absent from runtimes/ so they never ship to a consumer. Pruning on
# the template check alone deletes them, and running this script inside
# deepducks/autoducks itself would remove the release workflow that publishes the
# tags the entire `stable` channel resolves against.
#
# The distinction is already in the source tree, so it needs no list to maintain:
# a retired workflow is absent from the source's runtimes/ *and* its
# .github/workflows/; an upstream-only one is present in the latter. Keep
# anything the source still ships at repo level.
for wf in .github/workflows/autoducks-*.yml; do
  [[ -f "$wf" ]] || continue
  bn="$(basename "$wf")"
  if [[ -f ".autoducks/runtimes/github-actions/$bn" ]]; then
    continue
  fi
  if [[ -f "$TMP_DIR/.github/workflows/$bn" ]]; then
    echo "  Kept upstream-only workflow: $wf"
    continue
  fi
  rm -f "$wf"
  echo "  Removed stale mirror: $wf"
done

# Copy issue templates
mkdir -p .github/ISSUE_TEMPLATE
if [[ -d "$TMP_DIR/.github/ISSUE_TEMPLATE" ]]; then
  cp "$TMP_DIR/.github/ISSUE_TEMPLATE/"* .github/ISSUE_TEMPLATE/
  echo "  Issue templates copied"
fi

# Copy scripts
mkdir -p scripts scripts/tests
for f in setup.sh install.sh update-triggers.sh smoke-test.sh smoke-test-plan.sh smoke-test-product.sh smoke-test-update.sh tests/run.sh tests/label-utils.test.sh; do
  if [[ -f "$TMP_DIR/scripts/$f" ]]; then
    cp "$TMP_DIR/scripts/$f" "scripts/$f"
  fi
done
chmod +x scripts/*.sh
# The chmod above only globs scripts/*.sh, not the tests/ subdirectory; `find`
# is a no-op (not a glob error) when scripts/tests ends up empty.
find scripts/tests -maxdepth 1 -name '*.sh' -exec chmod +x {} +
echo "  Scripts copied"

# Make all .sh files executable
find .autoducks -name '*.sh' -exec chmod +x {} +

if [[ "$CLEANUP_TMP" == "true" ]]; then
  rm -rf "$TMP_DIR"
fi

# Bake per-team custom trigger aliases (triggers.<agent>[] in autoducks.json)
# into the workflow guards. GitHub's file-blind if: engine cannot read config at
# run time, so aliases must be baked into both the runtime template and the
# .github/workflows/ mirror. No-op (byte-identical) when no custom aliases are
# configured. Runs before setup so the runtime-sync check validates the result.
if [[ -f ".autoducks/autoducks.json" ]] && [[ -f "scripts/update-triggers.sh" ]] \
   && command -v jq &>/dev/null; then
  echo ""
  echo "Applying custom trigger aliases..."
  bash scripts/update-triggers.sh
fi

# Compile plugins[] (autoducks.json) into aggregator hook actions and per-agent
# Claude settings/tool-grant deltas. No-op when no plugins are configured.
if [[ -f ".autoducks/autoducks.json" ]] && [[ -f ".autoducks/core/config/apply-plugins.sh" ]] \
   && command -v jq &>/dev/null; then
  echo ""
  echo "Applying plugins..."
  bash .autoducks/core/config/apply-plugins.sh
fi

# App mode: default the AUTODUCKS_APP flag to on in the installed workflows so
# the broker mint step is active by presence (no repo variable needed). The
# app is installed in cloud/installer-workflow setup, so minting always applies.
# Idempotent: the rewritten form no longer ends in "vars.AUTODUCKS_APP }}".
if [[ "$APP_MODE" == true ]]; then
  echo ""
  echo "Enabling autoducks app mode in workflows..."
  for wf in .github/workflows/autoducks-*.yml; do
    [[ -f "$wf" ]] || continue
    perl -pi -e "s/vars\.AUTODUCKS_APP \}\}/vars.AUTODUCKS_APP || '1' }}/g" "$wf"
  done
fi

echo ""
echo "All files installed."
echo ""

if [[ "$NO_SETUP" == "true" ]] || [[ "$FRESH_INSTALL" == "false" ]]; then
  if [[ "$FRESH_INSTALL" == "false" ]]; then
    echo "Updated successfully. Run scripts/setup.sh to re-run setup checks."
  else
    echo "Skipping setup (--no-setup). Run scripts/setup.sh to configure your repo."
  fi
  exit 0
fi

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
fi

echo "Running setup..."
echo ""
# shellcheck disable=SC2086
scripts/setup.sh $REPO_ARG
