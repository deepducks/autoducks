#!/usr/bin/env bash
set -euo pipefail

# Post questions from the agent to the issue for human clarification
# Usage: ask_questions <issue_id> <questions_file>
ask_questions() {
  local issue_id="$1"
  local questions_file="$2"

  [[ ! -f "$questions_file" ]] && return 1

  local questions
  questions=$(cat "$questions_file")

  local body="🤔 **The agent has questions before proceeding:**

$questions

Please reply to this comment with answers, then re-run the agent."

  its::comment_issue "$issue_id" "$body"
}
