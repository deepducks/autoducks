#!/usr/bin/env bash
# ── Machinery comment marker ──────────────────────────────────────────────
# Every comment the machinery posts carries this. It is the only reliable way
# to recognise one: the author depends entirely on which credential the install
# uses. Under the default GITHUB_TOKEN comments come from `github-actions[bot]`,
# under AUTODUCKS_PAT they come from the PAT owner's own account, and under an
# App they come from `<app>[bot]`. Revert used to match the first of those three
# by name, so on a PAT install it recognised nothing, deleted nothing, and left
# every comment behind while still stripping the labels — an issue that looked
# reverted and was not (#183).
#
# HTML comment, so it renders as nothing. Matching is on the marker, never on
# the author, and never on comment prose.
#
# This lives in its own file so the two writers (its::comment_issue,
# its::update_comment) can source it directly. They used to stamp only
# `if declare -F comment_marker::stamp` — a silent fallback that posted an
# unstamped comment whenever the helper was not loaded, which is #183 again
# with no symptom at all. There is no fallback now: the function is always
# defined, so a comment cannot be posted without the marker.

export AUTODUCKS_COMMENT_MARKER="<!-- autoducks:comment -->"

# comment_marker::stamp BODY → BODY with the marker appended, idempotently.
# Callers pass a body through this on every write, including edits: an edit
# replaces the body wholesale, so a marker that is not re-applied is lost and
# the comment becomes invisible to revert.
comment_marker::stamp() {
  local body="$1"
  if [[ "$body" == *"$AUTODUCKS_COMMENT_MARKER"* ]]; then
    printf '%s' "$body"
  else
    printf '%s\n\n%s' "$body" "$AUTODUCKS_COMMENT_MARKER"
  fi
}
