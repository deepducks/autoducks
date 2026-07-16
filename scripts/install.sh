#!/usr/bin/env bash
# =============================================================================
# Install / Update Script for autoducks
# =============================================================================
#
# USAGE
#   curl -fsSL https://raw.githubusercontent.com/deepducks/autoducks/main/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --repo OWNER/REPO
#   curl -fsSL .../install.sh | bash -s -- --no-setup
#
# WHAT IT DOES
#   Downloads the .autoducks/ directory tree and copies runtime workflows
#   into .github/workflows/. On fresh install, runs setup automatically.
# =============================================================================

set -euo pipefail

SOURCE_REPO="deepducks/autoducks"
BRANCH="main"

REPO=""
NO_SETUP=false
APP_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --no-setup) NO_SETUP=true; shift ;;
    # Enable the autoducks GitHub App broker by default in the installed
    # workflows (un-gates the mint step so no AUTODUCKS_APP variable is needed).
    # Used by the cloud/installer-workflow setup where the app is installed.
    --app-mode) APP_MODE=true; shift ;;
    # Pin the machinery to a specific ref (commit SHA/tag) instead of main.
    --ref) BRANCH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

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
  curl -sL "https://api.github.com/repos/${SOURCE_REPO}/tarball/${BRANCH}" \
    | tar xz -C "$TMP_DIR" --strip-components=1
fi

# Copy .autoducks/ directory, preserving consumer-owned files across updates.
STASH_DIR=$(mktemp -d)
if [[ -f ".autoducks/autoducks.json" ]]; then
  cp ".autoducks/autoducks.json" "$STASH_DIR/autoducks.json"
fi
if [[ -f ".autoducks/providers/llm/claude/settings.json" ]]; then
  mkdir -p "$STASH_DIR/providers/llm/claude"
  cp ".autoducks/providers/llm/claude/settings.json" "$STASH_DIR/providers/llm/claude/settings.json"
fi
if [[ -d ".autoducks/custom" ]]; then
  cp -R ".autoducks/custom" "$STASH_DIR/custom"
fi
if [[ -d ".autoducks/plugins" ]]; then
  cp -R ".autoducks/plugins" "$STASH_DIR/plugins"
fi

rm -rf .autoducks
cp -R "$TMP_DIR/.autoducks" .autoducks

if [[ -f "$STASH_DIR/autoducks.json" ]]; then
  cp "$STASH_DIR/autoducks.json" ".autoducks/autoducks.json"
fi
if [[ -f "$STASH_DIR/providers/llm/claude/settings.json" ]]; then
  mkdir -p ".autoducks/providers/llm/claude"
  cp "$STASH_DIR/providers/llm/claude/settings.json" ".autoducks/providers/llm/claude/settings.json"
fi
if [[ -d "$STASH_DIR/custom" ]]; then
  rm -rf ".autoducks/custom"
  cp -R "$STASH_DIR/custom" ".autoducks/custom"
fi
if [[ -d "$STASH_DIR/plugins" ]]; then
  rm -rf ".autoducks/plugins"
  cp -R "$STASH_DIR/plugins" ".autoducks/plugins"
fi

rm -rf "$STASH_DIR"
echo "  .autoducks/ installed"

# Copy runtime workflows to .github/workflows/
mkdir -p .github/workflows
cp .autoducks/runtimes/github-actions/autoducks-*.yml .github/workflows/
echo "  Workflows copied to .github/workflows/"

# Copy issue templates
mkdir -p .github/ISSUE_TEMPLATE
if [[ -d "$TMP_DIR/.github/ISSUE_TEMPLATE" ]]; then
  cp "$TMP_DIR/.github/ISSUE_TEMPLATE/"* .github/ISSUE_TEMPLATE/
  echo "  Issue templates copied"
fi

# Copy scripts
mkdir -p scripts
for f in setup.sh install.sh update-triggers.sh smoke-test.sh smoke-test-plan.sh smoke-test-product.sh; do
  if [[ -f "$TMP_DIR/scripts/$f" ]]; then
    cp "$TMP_DIR/scripts/$f" "scripts/$f"
  fi
done
chmod +x scripts/*.sh
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
