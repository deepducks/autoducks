#!/usr/bin/env bash
# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_CONTEXT_PARTS_SH_LOADED:-}" ]] && return 0
readonly _CONTEXT_PARTS_SH_LOADED=1

# Catalog of per-part context materializer functions.
#
#   context_part::<id> <issue_num> <out_file>
#
# Materializes the part into <out_file>. Reads only ITS/git state via the
# provider interfaces (its::*, git::*) — never `gh` directly. Idempotent;
# safe to no-op to an empty file when the source is absent (mirrors the
# reviewer's empty task-criteria.md / security-guidelines.md tolerance).
#
# The resolver (a separate concern) is responsible for picking which parts
# to materialize and for `design.<section>` extraction via
# design_sections::extract — that routing is not part of this catalog.

source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/robustness/verify-loop.sh"

# issue_title: the raw issue title.
context_part::issue_title() {
  local issue_num="$1" out="$2"
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.title // empty' > "$out" || : > "$out"
}

# issue_description: the raw issue body.
context_part::issue_description() {
  local issue_num="$1" out="$2"
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.body // empty' > "$out" || : > "$out"
}

# issue_comments is turn-agnostic: it materializes the bounded last-20 comment
# window whenever selected, regardless of first-pass vs. revision. No
# body_has_markers gate.
context_part::issue_comments() {
  local issue_num="$1" out="$2"
  its::list_comments "$issue_num" 20 \
    | jq -r '.[] | "### " + .author + "\n\n" + .body + "\n\n---\n"' > "$out"
}

# issue_metadata: grounded to the fields its::get_issue returns
# ({title, body, labels, type, author}). Timestamps are NOT available and are
# out of scope here.
context_part::issue_metadata() {
  local issue_num="$1" out="$2"
  its::get_issue "$issue_num" | jq -r '
    "## Issue metadata\n",
    "- Labels: " + ((.labels // []) | join(", ")),
    "- Type: " + (.type // "n/a"),
    "- Author: " + (.author // "n/a")' > "$out"
}

# task_title: the raw title of a task issue (same shape as issue_title —
# a distinct catalog id because the resolver may select it for a different
# issue number, e.g. a task issue rather than the parent feature).
context_part::task_title() {
  local issue_num="$1" out="$2"
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.title // empty' > "$out" || : > "$out"
}

# task_description: the raw body of a task issue.
context_part::task_description() {
  local issue_num="$1" out="$2"
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.body // empty' > "$out" || : > "$out"
}

# task_criteria: the acceptance criteria of every task enumerated in the
# feature/bug issue's wave plan (reviewer/pre.sh L124-137). Best-effort — a
# body without a `waves:` block simply yields an empty file.
context_part::task_criteria() {
  local issue_num="$1" out="$2"
  : > "$out"
  local feature_body
  feature_body=$(its::get_issue "$issue_num" 2>/dev/null | jq -r '.body // empty') || feature_body=""
  [[ -z "$feature_body" ]] && return 0

  local parsed
  if parsed=$(parse_waves "$feature_body" 2>/dev/null); then
    local task_nums
    task_nums=$(echo "$parsed" | awk -F'|' '$1 == "TASK" {print $3}' | sort -un)
    local t
    for t in $task_nums; do
      its::get_issue "$t" 2>/dev/null \
        | jq -r --arg n "$t" '"## Task #" + $n + " — " + .title + "\n\n" + .body + "\n\n---\n"' \
        >> "$out" || true
    done
  fi
}

# prior_feedback: on a re-dispatched retry (ITERATION > 1), the marker-anchored
# check-failure feedback comment (developer/pre.sh L141-156). No-ops empty on
# a first attempt (ITERATION=1 or unset) and when no such comment exists.
context_part::prior_feedback() {
  local issue_num="$1" out="$2"
  : > "$out"
  local iteration="${ITERATION:-1}"
  [[ "$iteration" -gt 1 ]] || return 0

  local feedback_body
  feedback_body=$(its::list_comments "$issue_num" 2>/dev/null | jq -r \
    --arg marker "$AUTODUCKS_CHECK_FEEDBACK_MARKER" \
    '[.[] | select((.author == "github-actions[bot]" or .author == "github-actions")
                   and ((.body // "") | contains($marker)))]
     | sort_by(.updated_at // .created_at // "") | last | .body // empty') || feedback_body=""
  [[ -n "$feedback_body" ]] || return 0

  {
    echo ""
    echo "## Previous check failure"
    echo ""
    echo "$feedback_body"
  } > "$out"
}

# pr_diff: the unified diff of the PR (git::get_pr_diff).
context_part::pr_diff() {
  local pr_num="$1" out="$2"
  git::get_pr_diff "$pr_num" > "$out" 2>/dev/null || : > "$out"
}

# pr_meta: PR title/base/head/state plus the changed-file list, derived from
# git::get_pr and the diff itself (git::get_pr_diff) — never `gh pr view`.
context_part::pr_meta() {
  local pr_num="$1" out="$2"
  : > "$out"
  local pr_json
  pr_json=$(git::get_pr "$pr_num" 2>/dev/null) || pr_json=""
  [[ -n "$pr_json" ]] || return 0

  local pr_title pr_base pr_head pr_state
  pr_title=$(echo "$pr_json" | jq -r '.title')
  pr_base=$(echo "$pr_json" | jq -r '.baseRefName')
  pr_head=$(echo "$pr_json" | jq -r '.headRefName')
  pr_state=$(echo "$pr_json" | jq -r '.state')

  local changed_files
  changed_files=$(git::get_pr_diff "$pr_num" 2>/dev/null \
    | grep -E '^diff --git ' | sed -E 's#^diff --git a/(.*) b/.*#\1#') || changed_files=""

  {
    echo "# PR #$pr_num: $pr_title"
    echo ""
    echo "- Base: $pr_base"
    echo "- Head: $pr_head"
    echo "- State: $pr_state"
    echo ""
    echo "## Changed files"
    echo ""
    [[ -n "$changed_files" ]] && echo "$changed_files" | sed 's/^/- /'
  } > "$out"
}

# security_guidelines: optional repository security guidelines file
# (reviewer/pre.sh L174-179), reusing AUTODUCKS_REVIEW_SECURITY_GUIDELINES.
context_part::security_guidelines() {
  local out="$2"
  : > "$out"
  local guidelines="${AUTODUCKS_REVIEW_SECURITY_GUIDELINES:-.autoducks/security-guidelines.md}"
  if [[ -n "$guidelines" && -f "$guidelines" ]]; then
    cat "$guidelines" > "$out"
  fi
}

# plan: the tactical zone (the plan YAML) of the issue body. Empty when the
# body carries no tactical-zone markers yet (no plan exists) or the issue is
# absent.
context_part::plan() {
  local issue_num="$1" out="$2"
  : > "$out"
  local body_file design_file
  body_file=$(mktemp)
  design_file=$(mktemp)
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.body // empty' > "$body_file" || : > "$body_file"
  if [[ -s "$body_file" ]]; then
    split_body "$body_file" "$design_file" "$out" || true
  fi
  rm -f "$body_file" "$design_file"
}

# design.full: the whole design zone of the issue body — everything before
# the tactical-zone begin marker, or the full body when no markers exist yet.
context_part::design.full() {
  local issue_num="$1" out="$2"
  : > "$out"
  local body_file tactical_file
  body_file=$(mktemp)
  tactical_file=$(mktemp)
  its::get_issue "$issue_num" 2>/dev/null | jq -r '.body // empty' > "$body_file" || : > "$body_file"
  if [[ -s "$body_file" ]]; then
    split_body "$body_file" "$out" "$tactical_file" || true
  fi
  rm -f "$body_file" "$tactical_file"
}
