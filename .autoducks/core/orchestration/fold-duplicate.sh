#!/usr/bin/env bash
# Shared "fold N into M as a duplicate" action, used by both the
# deterministic /merge path (merge.sh) and the LLM-driven dedup half of
# the triage sweep (post.sh). Callers are responsible for the
# delivery_phase::started lock check BEFORE calling this — they react to
# a locked issue differently (merge.sh fails loudly; post.sh skips).

FOLD_DUPLICATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$FOLD_DUPLICATE_DIR/../config/label-utils.sh"

# fold_duplicate::close DUP CANONICAL
# Lazily creates (or case-repairs) the `Duplicate` label, labels DUP, closes
# it as not_planned with a cross-reference to CANONICAL, and best-effort
# links it as a sub-issue. Idempotent and non-fatal: a re-run on an
# already-closed DUP is a harmless no-op.
fold_duplicate::close() {
  local dup="$1" canonical="$2"
  label::ensure "Duplicate" "CFD3D7" "Closed as a duplicate of another issue" 2>/dev/null || true
  its::add_label "$dup" "Duplicate" 2>/dev/null || true
  its::close_issue "$dup" "Duplicate of #$canonical." "not_planned" || true
  its::link_sub_issue "$dup" "$canonical" >/dev/null 2>&1 || true
}
