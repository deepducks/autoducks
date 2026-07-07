#!/usr/bin/env bash
# =============================================================================
# update-triggers.sh — bake custom trigger aliases into the workflow guards
# =============================================================================
#
# GitHub Actions evaluates `jobs.*.if` with a file-blind expression engine, so
# per-team custom aliases (declared in .autoducks/autoducks.json under
# `triggers.<agent>[]`) cannot be resolved at run time — they must be baked into
# the workflow YAML. This script regenerates every affected guard from a
# deterministic template (built-in aliases + validated custom aliases) and
# writes BOTH the canonical runtime template and its .github/workflows/ mirror,
# so the setup runtime-sync check keeps passing.
#
# It is fully idempotent: each guard's `if: >-` block is regenerated wholesale
# from config, so running it twice produces byte-identical output.
#
# USAGE
#   bash scripts/update-triggers.sh
#
# After running, commit the modified .github/workflows/autoducks-*.yml (and the
# mirrored .autoducks/runtimes/github-actions/*.yml).
# =============================================================================

set -euo pipefail

# Run from repo root (where .autoducks/autoducks.json lives).
if [[ ! -f ".autoducks/autoducks.json" ]]; then
  echo "update-triggers: .autoducks/autoducks.json not found — run from repo root" >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "update-triggers: jq is required but not installed" >&2
  exit 1
fi

CONFIG=".autoducks/autoducks.json"
RUNTIME_DIR=".autoducks/runtimes/github-actions"
WORKFLOW_DIR=".github/workflows"

# Validate the entire triggers block up front (format + collisions). This is a
# hard error — a bad alias must never be baked into a guard.
AUTODUCKS_CONFIG="$CONFIG" bash .autoducks/core/config/generate-trigger-conditions.sh

RENDER_FILE="$(mktemp)"
trap 'rm -f "$RENDER_FILE"' EXIT

# ── Helpers ─────────────────────────────────────────────────────────
read_custom() { # $1 = config key → aliases, one per line
  jq -r --arg a "$1" '.triggers[$a][]? // empty' "$CONFIG"
}

# emit_group FIRST_INDENT FIRST_PREFIX CONT_INDENT LAST_SUFFIX ALIAS...
# Renders an OR-list of startsWith() clauses. The first clause is prefixed with
# FIRST_PREFIX (e.g. an opening paren); every clause but the last ends with
# " ||"; the last ends with LAST_SUFFIX (closing parens + trailing operator).
emit_group() {
  local fi="$1" fp="$2" ci="$3" ls="$4"; shift 4
  local a=("$@") n=$# i clause
  for ((i = 0; i < n; i++)); do
    clause="startsWith(github.event.comment.body, '/agents ${a[i]}')"
    if ((i == 0)); then
      printf '%s%s%s' "$fi" "$fp" "$clause"
    else
      printf '%s%s' "$ci" "$clause"
    fi
    if ((i == n - 1)); then
      printf '%s\n' "$ls"
    else
      printf ' ||\n'
    fi
  done
}

# ── Per-guard renderers (full `if:` block, up to but not including runs-on) ──
render_design() {
  local -a all=(design plan); mapfile -t c < <(read_custom design); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " ")) ||" "${all[@]}"
  cat <<'EOF'
      (github.event_name == 'issues' &&
       github.event.issue.author_association != 'MANNEQUIN' &&
       contains(github.event.issue.labels.*.name, 'Draft'))
EOF
}

render_tactical() {
  local -a dv=(devise drilldown specify) ex=(execute work run start)
  mapfile -t tc < <(read_custom tactical); dv+=("${tc[@]}")
  mapfile -t ec < <(read_custom execute);  ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event.issue.pull_request == null &&
      github.event.comment.author_association != 'MANNEQUIN' &&
      (
EOF
  emit_group "        " "" "        " " ||" "${dv[@]}"
  cat <<'EOF'
        (
EOF
  emit_group "          " "(" "           " ") &&" "${ex[@]}"
  cat <<'EOF'
          (github.event.issue.type.name == 'Feature' ||
           contains(github.event.issue.labels.*.name, 'Feature')) &&
          !contains(github.event.issue.labels.*.name, 'Ready')
        )
      )
EOF
}

render_wave() {
  local -a ex=(execute work run start); mapfile -t ec < <(read_custom execute); ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'pull_request' &&
       github.event.pull_request.merged == true &&
       startsWith(github.event.pull_request.base.ref, 'feature/')) ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " ") &&" "${ex[@]}"
  cat <<'EOF'
       (github.event.issue.type.name == 'Feature' ||
        contains(github.event.issue.labels.*.name, 'Feature')) &&
       contains(github.event.issue.labels.*.name, 'Ready'))
EOF
}

render_execute() {
  local -a ex=(execute work run start); mapfile -t ec < <(read_custom execute); ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " ") &&" "${ex[@]}"
  cat <<'EOF'
       !(github.event.issue.type.name == 'Feature' ||
         contains(github.event.issue.labels.*.name, 'Feature')))
EOF
}

# fix / revert / close have no built-in aliases: a bare single-clause guard when
# no custom aliases exist (byte-identical to the shipped template), or a
# parenthesized OR-group when custom aliases are present.
render_simple() { # $1 = canonical verb / config key
  local verb="$1"
  local -a all=("$verb"); mapfile -t c < <(read_custom "$verb"); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event.issue.pull_request == null &&
      github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "      startsWith(github.event.comment.body, '/agents %s')\n" "$verb"
  else
    emit_group "      " "(" "       " ")" "${all[@]}"
  fi
}

# ── Splice a rendered guard into a workflow file, then mirror it ─────
apply_file() { # $1 = basename, $2.. = render function + args
  local bn="$1"; shift
  local runtime="$RUNTIME_DIR/$bn"
  if [[ ! -f "$runtime" ]]; then
    echo "update-triggers: missing $runtime" >&2
    exit 1
  fi
  "$@" > "$RENDER_FILE"
  awk -v rf="$RENDER_FILE" '
    function emit() { while ((getline line < rf) > 0) print line; close(rf) }
    state == 0 && /^    if: >-$/ { emit(); state = 1; next }
    state == 1 && /^    runs-on:/ { state = 2; print; next }
    state == 1 { next }
    { print }
  ' "$runtime" > "$runtime.tmp"
  mv "$runtime.tmp" "$runtime"
  mkdir -p "$WORKFLOW_DIR"
  cp "$runtime" "$WORKFLOW_DIR/$bn"
  echo "  regenerated $bn"
}

echo "Regenerating trigger guards from $CONFIG ..."
apply_file autoducks-design.yml   render_design
apply_file autoducks-tactical.yml render_tactical
apply_file autoducks-wave.yml     render_wave
apply_file autoducks-execute.yml  render_execute
apply_file autoducks-fix.yml      render_simple fix
apply_file autoducks-revert.yml   render_simple revert
apply_file autoducks-close.yml    render_simple close

echo "Done. Commit the modified .github/workflows/ and .autoducks/runtimes/ files."
