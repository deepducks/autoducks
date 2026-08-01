#!/usr/bin/env bash
# Shared "N is a duplicate of M" actions, in two strengths.
#
# The distinction is who asked. `/merge #M` is a human naming both issues by
# number, at a moment of their choosing, so it closes. The triage sweep is a
# scheduled job acting on an LLM's opinion about issues nobody pointed it at,
# so it annotates and leaves both the decision and its timing to a person.
# Closing on a guess is cheap to do and tedious to undo across a backlog, and
# the sweep could act on up to `max_closes_per_run` groups a night.
#
# Callers are responsible for the delivery_phase::started lock check BEFORE
# calling either of these — they react to a locked issue differently
# (merge.sh fails loudly; post.sh skips).

FOLD_DUPLICATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$FOLD_DUPLICATE_DIR/../config/label-utils.sh"

# fold_duplicate::reference DUP CANONICAL
# Lazily creates (or case-repairs) the `Duplicate` label, labels DUP, and
# points at CANONICAL from DUP — without closing anything. For the triage
# sweep. Non-fatal throughout: a flag that fails must not take the sweep down.
fold_duplicate::reference() {
  local dup="$1" canonical="$2"
  label::ensure "Duplicate" "CFD3D7" "Looks like a duplicate of another issue" 2>/dev/null || true
  its::add_label "$dup" "Duplicate" 2>/dev/null || true
  its::comment_issue "$dup" "This looks like a duplicate of #$canonical.

Left open on purpose — triage flags duplicates, it does not close them. Close whichever of the two is redundant once you have the context to decide, or run \`$(autoducks_command_for merge) #$canonical\` here to fold it." 2>/dev/null || true
}

# fold_duplicate::close DUP CANONICAL
# Labels DUP, closes it as not_planned with a cross-reference to CANONICAL,
# and best-effort links it as a sub-issue. For the explicit `/merge` path
# only. Idempotent and non-fatal: a re-run on an already-closed DUP is a
# harmless no-op.
fold_duplicate::close() {
  local dup="$1" canonical="$2"
  label::ensure "Duplicate" "CFD3D7" "Closed as a duplicate of another issue" 2>/dev/null || true
  its::add_label "$dup" "Duplicate" 2>/dev/null || true
  its::close_issue "$dup" "Duplicate of #$canonical." "not_planned" || true
  its::link_sub_issue "$dup" "$canonical" >/dev/null 2>&1 || true
}
