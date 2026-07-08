#!/usr/bin/env bash
# =============================================================================
# update-triggers.sh — bake the slash-command prefix and custom trigger
# aliases into the workflow guards
# =============================================================================
#
# GitHub Actions evaluates `jobs.*.if` with a file-blind expression engine, so
# the configurable slash-command prefix (`command` in .autoducks/autoducks.json,
# default `/quack`) and per-team custom aliases (declared under
# `triggers.<agent>[]`) cannot be resolved at run time — they must be baked
# into the workflow YAML. This script regenerates the affected guards from a
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
# After running, commit the modified .github/workflows/autoducks-*.yml (and
# the mirrored .autoducks/runtimes/github-actions/*.yml).
# =============================================================================

set -euo pipefail

# Must run from the repo root (where .autoducks/autoducks.json lives).
if [[ ! -f ".autoducks/autoducks.json" ]]; then
  echo "update-triggers: .autoducks/autoducks.json not found — run from the repo root" >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "update-triggers: jq required but not installed" >&2
  exit 1
fi

CONFIG=".autoducks/autoducks.json"
RUNTIME_DIR=".autoducks/runtimes/github-actions"
WORKFLOW_DIR=".github/workflows"

# Validate the entire triggers block up front (format + collisions). This is a
# hard error — a bad alias must never be baked into a guard.
AUTODUCKS_CONFIG="$CONFIG" bash .autoducks/core/config/generate-trigger-conditions.sh

# Slash-command prefix (validated; falls back to /quack on garbage)
CMD="$(jq -r '.command // "/quack"' "$CONFIG")"
[[ "$CMD" =~ ^/[a-z0-9-]+$ ]] || CMD="/quack"

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
    clause="startsWith(github.event.comment.body, '$CMD ${a[i]}')"
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

# ── Per-guard renderers (the full block, up to but not including runs-on) ──
render_architect() {
  local -a all=(architect design); mapfile -t c < <(read_custom architect); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " "))" "${all[@]}"
}

render_engineer() {
  local -a dv=(engineer tactics) ex=(execute work run)
  mapfile -t tc < <(read_custom engineer); dv+=("${tc[@]}")
  mapfile -t ec < <(read_custom execute);  ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
       (
EOF
  emit_group "         " "" "         " " ||" "${dv[@]}"
  cat <<'EOF'
         (
EOF
  emit_group "           " "(" "            " ") &&" "${ex[@]}"
  cat <<'EOF'
           !(github.event.issue.type.name == 'Task' ||
             contains(github.event.issue.labels.*.name, 'Task')) &&
           !contains(github.event.issue.labels.*.name, 'Tactics:done')
         )
       ))
EOF
}

render_maestro() {
  local -a ex=(execute work run); mapfile -t ec < <(read_custom execute); ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'pull_request' &&
       github.event.pull_request.merged == true &&
       (startsWith(github.event.pull_request.base.ref, 'feature/') ||
        startsWith(github.event.pull_request.base.ref, 'fix/'))) ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " ") &&" "${ex[@]}"
  cat <<'EOF'
       !(github.event.issue.type.name == 'Task' ||
         contains(github.event.issue.labels.*.name, 'Task')) &&
       contains(github.event.issue.labels.*.name, 'Tactics:done'))
EOF
}

render_developer() {
  local -a ex=(execute work run); mapfile -t ec < <(read_custom execute); ex+=("${ec[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " ") &&" "${ex[@]}"
  cat <<'EOF'
       (github.event.issue.type.name == 'Task' ||
        contains(github.event.issue.labels.*.name, 'Task')))
EOF
}

# The Reviewer fires on comments on both issues and PRs, so its guard
# deliberately omits the `pull_request == null` clause every other agent
# carries — do NOT reuse render_simple for this reason.
render_reviewer() {
  local -a all=(review); mapfile -t c < <(read_custom review); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s review'))\n" "$CMD"
  else
    emit_group "       " "(" "        " "))" "${all[@]}"
  fi
}

# fix / revert / close have no built-in aliases: bare single-clause guard
# when no custom aliases exist (byte-identical to the shipped template),
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
    printf "      startsWith(github.event.comment.body, '%s %s')\n" "$CMD" "$verb"
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
apply_file autoducks-architect.yml render_architect
apply_file autoducks-engineer.yml  render_engineer
apply_file autoducks-maestro.yml   render_maestro
apply_file autoducks-developer.yml render_developer
apply_file autoducks-reviewer.yml  render_reviewer
apply_file autoducks-fix.yml       render_simple fix
apply_file autoducks-revert.yml    render_simple revert
apply_file autoducks-close.yml     render_simple close

echo "Done. Commit the modified .github/workflows/ and .autoducks/runtimes/ files."
