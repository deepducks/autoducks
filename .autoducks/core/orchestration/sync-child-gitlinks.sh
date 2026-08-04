#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../config/load-config.sh"

# Advance the parent's gitlinks when a child moved on its own cycle.
# Inert outside metarepo mode (byte-identical single-repo behaviour).
#
# Why this exists (#170): a child repo with its own feature cycle advances without
# telling the parent. There is no child→parent bridge — no `repository_dispatch`,
# and the reconcile that does exist only ever fired when the *parent* moved:
# `repin-siblings` on a parent PR merging, `repin-on-base-push` on a direct push to
# the parent's default branch. A child advancing on its own reached neither, so the
# pin sat behind until a human noticed. Every submodule bump in this repo's history
# was made by hand; one session alone needed five.
#
# This is the mirror image of repin-open-parent-prs.sh. That one walks the open
# parent delivery PRs and reconciles each PR head after the default branch moved;
# this one reconciles the default branch itself against every declared submodule.
#
# The reconcile is the same one, unchanged (metarepo::reconcile_gitlinks): it only
# ever fast-forwards. A pin that is ahead of the child's default branch means a
# delivery has not merged yet and is left alone; a diverged or unreadable pin is
# reported and left for a human. So the worst case is that nothing moves.
#
# Required env: REPO.
#
# The branch reconciled is the pipeline's own base branch (`base_branch` in
# autoducks.json, exported by load-config.sh as AUTODUCKS_BASE_BRANCH), falling
# back to whatever the host reports as the repository default when the config
# leaves it empty. Note that load-config.sh overwrites AUTODUCKS_BASE_BRANCH from
# config, so a caller cannot steer this by exporting it — config wins, which is
# what you want: reconciling anything other than the branch the pipeline builds
# on would move a gitlink nobody is reading.

metarepo::enabled || exit 0

: "${REPO:?REPO env var required}"

log() { echo "[sync-child-gitlinks] $*" >&2; }
notice() { echo "::notice::sync-child-gitlinks: $*"; }

BRANCH="${AUTODUCKS_BASE_BRANCH:-}"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || true)"
fi
if [[ -z "$BRANCH" ]]; then
  echo "::warning::sync-child-gitlinks: cannot resolve the default branch of $REPO — nothing reconciled" >&2
  exit 0
fi

mapfile -t PATHS < <(metarepo::submodule_paths)
if [[ "${#PATHS[@]}" -eq 0 ]]; then
  notice "no submodules declared in .gitmodules — nothing to reconcile"
  exit 0
fi

log "reconciling '$BRANCH' against ${#PATHS[@]} child(ren): ${PATHS[*]}"
metarepo::reconcile_gitlinks "$BRANCH" "${PATHS[@]}"
