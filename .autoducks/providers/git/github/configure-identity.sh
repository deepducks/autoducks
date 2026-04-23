#!/usr/bin/env bash
set -euo pipefail

git::configure_identity() {
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
}
