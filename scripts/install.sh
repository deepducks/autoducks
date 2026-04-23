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
BASE_URL="https://raw.githubusercontent.com/${SOURCE_REPO}/${BRANCH}"

REPO=""
NO_SETUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --no-setup) NO_SETUP=true; shift ;;
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

# Download the full .autoducks/ tree via GitHub API (tarball)
echo "Downloading .autoducks/ tree..."
TMP_DIR=$(mktemp -d)
curl -sL "https://api.github.com/repos/${SOURCE_REPO}/tarball/${BRANCH}" \
  | tar xz -C "$TMP_DIR" --strip-components=1

# Copy .autoducks/ directory
cp -r "$TMP_DIR/.autoducks" .autoducks
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
for f in setup.sh install.sh smoke-test.sh smoke-test-plan.sh; do
  if [[ -f "$TMP_DIR/scripts/$f" ]]; then
    cp "$TMP_DIR/scripts/$f" "scripts/$f"
  fi
done
chmod +x scripts/*.sh
echo "  Scripts copied"

# Make all .sh files executable
find .autoducks -name '*.sh' -exec chmod +x {} +

rm -rf "$TMP_DIR"

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
