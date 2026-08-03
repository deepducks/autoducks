#!/usr/bin/env bash
set -euo pipefail

# ── "this run already reported its own failure" sentinel ─────────────
# The YAML `Failure watchdog` step in every agent workflow is a last-resort
# backstop for a *corrupted* post.sh: a hook that dies (or exits 0) without
# telling the issue anything, which would otherwise freeze a wave silently
# (#952). Its original condition keyed off `steps.post.outcome != 'success'`,
# which cannot tell that case apart from the far more common one where post.sh
# reported the failure correctly and *then* exited 1 by design — so every
# deliberate-failure path fired a bogus third comment contradicting the accurate
# report it had just posted (#117).
#
# The gate is therefore "did the hook report?", not "did the hook succeed".
# Every reporting helper marks the run here; the watchdog stays quiet whenever
# the mark is present. A hook that is genuinely corrupted never reaches a
# reporting helper, never sets the mark, and still trips the watchdog.
#
# $GITHUB_OUTPUT lines are captured by the runner as they are appended, so a
# mark written before a deliberate `exit 1` still reaches
# `steps.post.outputs.reported`. Outside GitHub Actions this is a no-op.

feedback::mark_reported() {
  [[ -n "${_AUTODUCKS_REPORTED:-}" ]] && return 0
  _AUTODUCKS_REPORTED=1
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  echo "reported=true" >> "$GITHUB_OUTPUT" 2>/dev/null || true
  return 0
}
