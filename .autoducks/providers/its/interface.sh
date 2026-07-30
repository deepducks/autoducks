#!/usr/bin/env bash
set -euo pipefail

# ITS (Issue Tracking System) provider interface
# Sources the concrete implementation from providers/its/$AUTODUCKS_ITS_PROVIDER/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${AUTODUCKS_ITS_PROVIDER:?AUTODUCKS_ITS_PROVIDER must be set (e.g. \"github\")}"

PROVIDER_DIR="${SCRIPT_DIR}/${AUTODUCKS_ITS_PROVIDER}"

if [[ ! -d "$PROVIDER_DIR" ]]; then
  echo "ERROR: ITS provider directory not found: ${PROVIDER_DIR}" >&2
  exit 1
fi

# Source all .sh files from the provider implementation directory
for f in "${PROVIDER_DIR}"/*.sh; do
  [[ -f "$f" ]] || continue
  # shellcheck source=/dev/null
  source "$f"
done

# ── Required function signatures ──────────────────────────────────────────
#
#   its::get_issue(issue_id)                         → JSON {title, body, labels, type, author}
#   its::create_issue(title, body, labels, type, parent_id?)  → issue_id
#   its::close_issue(issue_id, comment?, reason?)   reason ∈ {completed, not_planned, duplicate}
#     → 0 closed (or already closed) | 1 close failed (issue still open) | 2 invalid reason
#   its::reopen_issue(issue_id, comment?)
#   its::update_issue_body(issue_id, body)
#   its::comment_issue(issue_id, body)
#   its::react_to_comment(comment_id, reaction)
#   its::add_label(issue_id, label)
#   its::remove_label(issue_id, label)
#   its::set_issue_type(issue_id, type)
#   its::link_sub_issue(parent_id, child_id)         → token ∈ {linked, already-linked, unavailable, forbidden, error}
#   its::sub_issues_available(any_issue_id)          → token ∈ {available, unavailable, forbidden, error}
#   its::list_comments(issue_id, limit?)             → JSON array
#   its::list_sub_issues(issue_id)                   → JSON array
#   its::get_parent(issue_id)                        → parent number | empty; exit 1 = query failed
#   its::get_issue_edit_history(issue_id)             → JSON array
#   its::delete_comment(comment_id)
#   its::update_comment(comment_id, body)
#   its::assign_issue(issue_id, assignee)
#   its::list_issues(state, limit?, extra_filter?)   → JSON array [{number,title,body,labels,type,updatedAt}]
#   its::search_issues(query)                        → JSON array
#   its::set_priority(issue_id, priority)            → token ∈ {project, labels, off, unavailable}
#   its::priority_backend()                          → token ∈ {project, labels, off}

REQUIRED_FUNCTIONS=(
  "its::get_issue"
  "its::create_issue"
  "its::close_issue"
  "its::reopen_issue"
  "its::update_issue_body"
  "its::comment_issue"
  "its::react_to_comment"
  "its::add_label"
  "its::remove_label"
  "its::set_issue_type"
  "its::link_sub_issue"
  "its::sub_issues_available"
  "its::list_comments"
  "its::list_sub_issues"
  "its::get_parent"
  "its::get_issue_edit_history"
  "its::delete_comment"
  "its::update_comment"
  "its::assign_issue"
  "its::list_issues"
  "its::search_issues"
  "its::set_priority"
  "its::priority_backend"
)

missing=0
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  if [[ "$(type -t "$fn" 2>/dev/null)" != "function" ]]; then
    echo "ERROR: ITS provider '${AUTODUCKS_ITS_PROVIDER}' does not implement required function: ${fn}" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
