#!/usr/bin/env bash
# =============================================================================
# Install / Update Script for claude-in-github
# =============================================================================
#
# USAGE
#   curl -fsSL https://raw.githubusercontent.com/ggondim/claude-in-github/main/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --repo OWNER/REPO
#   curl -fsSL .../install.sh | bash -s -- --no-setup
#
# WHAT IT DOES
#   Downloads all workflow files, prompts, and scripts into .github/ only.
#   On a fresh install (files not present): runs setup automatically.
#   On an update (files already present): only overwrites files, skips setup.
# =============================================================================

set -euo pipefail

SOURCE_REPO="ggondim/claude-in-github"
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

# Detect mode: fresh install or update
FRESH_INSTALL=true
if [[ -f ".github/workflows/claude-meta.yml" ]]; then
  FRESH_INSTALL=false
fi

if [[ "$FRESH_INSTALL" == "true" ]]; then
  echo "=== Installing claude-in-github ==="
else
  echo "=== Updating claude-in-github ==="
fi
echo ""

# Pairs of "source:destination" (bash 3 compatible, no associative arrays)
FILE_PAIRS=(
  ".github/workflows/claude-meta.yml:.github/workflows/claude-meta.yml"
  ".github/workflows/claude-task.yml:.github/workflows/claude-task.yml"
  ".github/workflows/claude-fix.yml:.github/workflows/claude-fix.yml"
  ".github/workflows/claude-plan.yml:.github/workflows/claude-plan.yml"
  ".github/scripts/meta-orchestrate.sh:.github/scripts/meta-orchestrate.sh"
  ".github/prompts/plan-agent.md:.github/prompts/plan-agent.md"
  ".github/prompts/splitter-agent.md:.github/prompts/splitter-agent.md"
  ".github/prompts/task-worker.md:.github/prompts/task-worker.md"
  ".github/prompts/fix-agent.md:.github/prompts/fix-agent.md"
  ".github/ISSUE_TEMPLATE/meta-issue.yml:.github/ISSUE_TEMPLATE/meta-issue.yml"
  ".github/ISSUE_TEMPLATE/task-issue.yml:.github/ISSUE_TEMPLATE/task-issue.yml"
  "scripts/setup.sh:.github/scripts/setup.sh"
  "scripts/install.sh:.github/scripts/install.sh"
)

for pair in "${FILE_PAIRS[@]}"; do
  src="${pair%%:*}"
  dest="${pair#*:}"
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  if curl -sf "${BASE_URL}/${src}" -o "$dest"; then
    echo "  ✓ $dest"
  else
    echo "  ✗ Failed to download ${src}" >&2
    exit 1
  fi
done

chmod +x .github/scripts/*.sh

echo ""
echo "All files installed to .github/"
echo ""

if [[ "$NO_SETUP" == "true" ]] || [[ "$FRESH_INSTALL" == "false" ]]; then
  if [[ "$FRESH_INSTALL" == "false" ]]; then
    echo "Updated successfully. Run .github/scripts/setup.sh if you need to re-run the setup checks."
  else
    echo "Skipping setup (--no-setup). Run .github/scripts/setup.sh to configure your repo."
  fi
  exit 0
fi

# Fresh install: run setup
REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
fi

echo "Running setup..."
echo ""
# shellcheck disable=SC2086
.github/scripts/setup.sh $REPO_ARG
