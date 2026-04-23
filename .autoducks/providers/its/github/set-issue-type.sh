#!/usr/bin/env bash
set -euo pipefail

its::set_issue_type() {
  local issue_id="$1"
  local type="$2"
  gh api "repos/$REPO/issues/$issue_id" --method PATCH -f "type=$type" --silent
}
