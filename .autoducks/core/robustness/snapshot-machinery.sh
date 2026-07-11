#!/usr/bin/env bash
# =============================================================================
# snapshot-machinery.sh — pin the running `.autoducks` machinery to the
# pipeline's origin commit so an agent editing `.autoducks` on its own branch
# can never corrupt the machinery that runs its build (see bug #952).
# =============================================================================
#
# THE HAZARD. Every agent workflow does a single `actions/checkout` and then
# runs `.autoducks/**` scripts (and a composite action whose body path-reads
# `.autoducks/**`) from that one working tree. When an agent's task is to edit
# `.autoducks` (e.g. rewrite `post.sh`) and it is interrupted mid-edit, the
# post-agent steps execute the half-written machinery — which broke outcome
# reporting and silently froze a Maestro wave. Beyond a single run, machinery
# also drifts across waves/reviews as the pipeline commits its own `.autoducks`
# changes.
#
# THE FIX. This script — run ONCE, right after checkout, BEFORE the agent —
# materialises the whole `.autoducks` tree from a *pinned commit* into a
# throwaway dir under $RUNNER_TEMP and exports AUTODUCKS_PINNED_ROOT. Every
# later step then runs `bash "$AUTODUCKS_PINNED_ROOT/.autoducks/..."` and the
# LLM provider reads its prompt/settings from the same pin, so the machinery is
# frozen to a version the pipeline's own edits cannot touch. Git operations
# still run against the live working tree (CWD), which is exactly what we want:
# the agent's product edits land on the branch; only the *machinery* is pinned.
#
# THE PIN. `git merge-base HEAD origin/<base>` — the commit the pipeline's
# branch was cut from (where its PR was opened). autoducks never merges the
# base into a pipeline branch mid-flight, so this stays stable for the whole
# pipeline and is free of the pipeline's own `.autoducks` edits (those live on
# the branch, not the base). Pre-pipeline lanes (architect/engineer/product run
# on the base branch itself) resolve the pin to the base tip — i.e. current
# machinery — which is the correct behaviour when no pipeline exists yet.
#
# This script itself is the one bootstrap that runs from the live tree, but it
# runs pre-agent (clean) so it is never the corrupted copy.
#
# Inputs (env):
#   RUNNER_TEMP              — snapshot lives under here (falls back to /tmp)
#   AUTODUCKS_MACHINERY_BASE — override the base branch to pin against
#                              (default: .autoducks/autoducks.json defaults.base_branch, else "main")
#   GITHUB_ENV / GITHUB_OUTPUT — when set, AUTODUCKS_PINNED_ROOT / root are exported
# =============================================================================

set -euo pipefail

SNAP="${RUNNER_TEMP:-/tmp}/autoducks-snapshot"
rm -rf "$SNAP"
mkdir -p "$SNAP"

# Resolve the machinery base branch (the pipeline's cut-point lives on it).
BASE="${AUTODUCKS_MACHINERY_BASE:-}"
if [[ -z "$BASE" && -f .autoducks/autoducks.json ]] && command -v jq >/dev/null 2>&1; then
  BASE="$(jq -r '.defaults.base_branch // "main"' .autoducks/autoducks.json 2>/dev/null || echo main)"
fi
BASE="${BASE:-main}"

# Resolve the pin commit: merge-base of the checked-out ref and origin/<base>.
PIN=""
if git fetch --quiet origin "$BASE" 2>/dev/null; then
  PIN="$(git merge-base HEAD FETCH_HEAD 2>/dev/null || true)"
fi

pin_ok=0
if [[ -n "$PIN" ]] && git cat-file -e "${PIN}^{commit}" 2>/dev/null; then
  # `.autoducks` must exist at the pin (guards against a base older than autoducks).
  if git archive "$PIN" .autoducks 2>/dev/null | tar -x -C "$SNAP" 2>/dev/null \
     && [[ -f "$SNAP/.autoducks/autoducks.json" ]]; then
    pin_ok=1
  fi
fi

if [[ "$pin_ok" == "1" ]]; then
  echo "Pinned .autoducks machinery to ${PIN} (base ${BASE})."
else
  # Fallback: snapshot the current tree so callers always get a stable,
  # separate copy even when the pin can't be resolved (shallow clone, network
  # failure, base predating autoducks, non-git context).
  rm -rf "$SNAP/.autoducks"
  cp -a .autoducks "$SNAP/.autoducks"
  echo "::warning::snapshot-machinery: could not pin to a commit (base '${BASE}'); snapshotting the current working tree instead."
fi

# Export for later steps. AUTODUCKS_PINNED_ROOT is the dir CONTAINING .autoducks
# so callers use "$AUTODUCKS_PINNED_ROOT/.autoducks/..." and load-config's
# walk-up anchors on the pinned autoducks.json.
[[ -n "${GITHUB_ENV:-}" ]]    && echo "AUTODUCKS_PINNED_ROOT=$SNAP" >> "$GITHUB_ENV"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "root=$SNAP/.autoducks" >> "$GITHUB_OUTPUT"
echo "AUTODUCKS_PINNED_ROOT=$SNAP"
