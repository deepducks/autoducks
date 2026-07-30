#!/usr/bin/env bash
# =============================================================================
# update-triggers.sh — bake the slash-command prefix and custom trigger
# aliases into the workflow guards
# =============================================================================
#
# GitHub Actions evaluates `jobs.*.if` with a file-blind expression engine, so
# the configurable command namespace (`command` in .autoducks/autoducks.json,
# default `""` — bare short forms like `/architect`) and per-team custom
# aliases (declared under `triggers.<agent>[]`) cannot be resolved at run
# time — they must be baked into the workflow YAML. This script regenerates
# the affected guards from a deterministic template (built-in aliases +
# validated custom aliases) and writes BOTH the canonical runtime template
# and its .github/workflows/ mirror, so the setup runtime-sync check keeps
# passing.
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

# Command namespace (validated; falls back to empty — bare short forms — on
# garbage). namespace = command with a single optional leading '/' stripped.
NS="$(jq -r '.command // ""' "$CONFIG")"
[[ "$NS" =~ ^$|^/?[a-z0-9-]+$ ]] || NS=""
NS="${NS#/}"

# cmd_for TRIGGER — bake the command string for a trigger word:
#   namespace == "" ? "/<trigger>" : "/<namespace> <trigger>"
cmd_for() {
  if [[ -z "$NS" ]]; then
    printf '/%s' "$1"
  else
    printf '/%s %s' "$NS" "$1"
  fi
}

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
    clause="startsWith(github.event.comment.body, '$(cmd_for "${a[i]}")')"
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
#
# The guards below test label/type strings verbatim ('Task', 'Tactics:done',
# 'Autoducks:external') with no case-folding. That's deliberate, not an
# oversight: GitHub documents contains(), startsWith(), endsWith(), and == on
# strings as case-insensitive comparisons in Actions expressions —
# https://docs.github.com/en/actions/reference/evaluate-expressions-in-workflows-and-actions
# — so the expression layer already tolerates any casing these guards will
# ever see.
#
# The bash/jq layer elsewhere in this machinery does NOT inherit that
# property automatically; it has its own separate case-insensitive
# comparison (see the Labels section of .autoducks/design/AGENTS.md). The
# two are independent, deliberately redundant guarantees.
#
# Regardless of the expression layer's own behaviour, 'Task', 'Tactics:done'
# and 'Autoducks:external' are machinery-created labels/types — never
# hand-typed by a human — so normalization-at-source (setup.sh's
# rename-on-collision) is the load-bearing protection here either way.
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
#
# It also auto-fires when a final feature/fix PR is marked ready-for-review
# (base = integration branch, so task PRs — which target a feature/|fix/
# pipeline branch — are excluded here; pre.sh does the exact base check).
render_reviewer() {
  local -a all=(review); mapfile -t c < <(read_custom review); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'pull_request' &&
       github.event.action == 'ready_for_review' &&
       (startsWith(github.event.pull_request.head.ref, 'feature/') ||
        startsWith(github.event.pull_request.head.ref, 'fix/')) &&
       !startsWith(github.event.pull_request.base.ref, 'feature/') &&
       !startsWith(github.event.pull_request.base.ref, 'fix/') &&
       !contains(github.event.pull_request.body, 'autoducks:metarepo-managed') &&
       !contains(github.event.pull_request.labels.*.name, 'Autoducks:external')) ||
      (github.event_name == 'issue_comment' &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s'))\n" "$(cmd_for review)"
  else
    emit_group "       " "(" "        " "))" "${all[@]}"
  fi
}

# The Resolver auto-fires when a commit is pushed (synchronize) to an open,
# non-draft feature/fix PR (base = integration branch, excluding task PRs the
# same way the Reviewer does), plus the manual /resolve comment.
render_resolver() {
  local -a all=(resolve); mapfile -t c < <(read_custom resolve); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'pull_request' &&
       github.event.action == 'synchronize' &&
       github.event.pull_request.draft == false &&
       (startsWith(github.event.pull_request.head.ref, 'feature/') ||
        startsWith(github.event.pull_request.head.ref, 'fix/')) &&
       !startsWith(github.event.pull_request.base.ref, 'feature/') &&
       !startsWith(github.event.pull_request.base.ref, 'fix/')) ||
      (github.event_name == 'issue_comment' &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s'))\n" "$(cmd_for resolve)"
  else
    emit_group "       " "(" "        " "))" "${all[@]}"
  fi
}

# Rework and Defer fire on comments on both issues and PRs, just like the
# Reviewer, so their guards also omit the `pull_request == null` clause — do
# NOT reuse render_simple for this reason.
render_rework() {
  local -a all=(rework); mapfile -t c < <(read_custom rework); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.comment.author_association != 'MANNEQUIN' &&
       !contains(github.event.issue.body, 'autoducks:metarepo-managed') &&
       !contains(github.event.issue.labels.*.name, 'Autoducks:external') &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s'))\n" "$(cmd_for rework)"
  else
    emit_group "       " "(" "        " "))" "${all[@]}"
  fi
}

render_defer() {
  local -a all=(defer); mapfile -t c < <(read_custom defer); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s'))\n" "$(cmd_for defer)"
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
    printf "      startsWith(github.event.comment.body, '%s')\n" "$(cmd_for "$verb")"
  else
    emit_group "      " "(" "       " ")" "${all[@]}"
  fi
}

# Product agent guard: fires unconditionally on schedule/workflow_dispatch,
# on newly opened issues (excluding bot-created Task/pipeline issues), and on
# issue comments matching /triage or /merge (built-in + custom aliases).
render_product() {
  local -a all=(triage); mapfile -t tc < <(read_custom triage); all+=("${tc[@]}")
  local -a mg=(merge);   mapfile -t mc < <(read_custom merge);  mg+=("${mc[@]}")
  all+=("${mg[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'schedule' ||
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issues' && github.event.action == 'opened' &&
       !(github.event.sender.type == 'Bot' &&
         (github.event.issue.type.name == 'Task' ||
          contains(github.event.issue.labels.*.name, 'Task')))) ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  emit_group "       " "(" "        " "))" "${all[@]}"
}

# Update agent guard: fires unconditionally on schedule/workflow_dispatch, and
# on issue comments matching /update (built-in + custom aliases). Scheduled
# shape mirrors render_product's — the schedule and workflow_dispatch event
# names bypass the comment clauses entirely.
render_update() {
  local -a all=(update); mapfile -t c < <(read_custom update); all+=("${c[@]}")
  cat <<'EOF'
    if: >-
      github.event_name == 'schedule' ||
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       github.event.comment.author_association != 'MANNEQUIN' &&
EOF
  if ((${#all[@]} == 1)); then
    printf "       startsWith(github.event.comment.body, '%s'))\n" "$(cmd_for update)"
  else
    emit_group "       " "(" "        " "))" "${all[@]}"
  fi
}

# ── Bake product.schedule into autoducks-product.yml's `schedule:` trigger ──
# GitHub's `on.schedule` cron is static YAML — it cannot read config at run
# time, so like the comment guards it must be baked in. `product.enabled ==
# false` removes the `schedule:` trigger entirely (the workflow still runs on
# workflow_dispatch/issue_comment/issues, just never on a timer).
patch_product_cron() {
  local bn="autoducks-product.yml"
  local runtime="$RUNTIME_DIR/$bn"
  if [[ ! -f "$runtime" ]]; then
    echo "update-triggers: missing $runtime" >&2
    exit 1
  fi
  local enabled cron
  # NOTE: jq's `//` alternative operator treats `false` like `null` — an
  # explicit `.product.enabled // true` would always resolve to `true`.
  enabled="$(jq -r 'if .product.enabled == false then "false" else "true" end' "$CONFIG")"
  cron="$(jq -r '.product.schedule // "0 9 * * *"' "$CONFIG")"
  if [[ "$enabled" == "false" ]]; then
    awk '
      /^  schedule:$/ { getline; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  elif grep -q '^  schedule:$' "$runtime"; then
    local cron_line="    - cron: '${cron}'"
    awk -v line="$cron_line" '
      /^    - cron:/ { print line; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  else
    # Re-enabling after a prior enabled:false run: the `schedule:` trigger
    # was removed outright, so reinsert it right after `on:` (its original
    # template position) rather than only rewriting an existing cron line.
    local cron_line="    - cron: '${cron}'"
    awk -v line="$cron_line" '
      /^on:$/ { print; print "  schedule:"; print line; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  fi
  mv "$runtime.tmp" "$runtime"
  mkdir -p "$WORKFLOW_DIR"
  cp "$runtime" "$WORKFLOW_DIR/$bn"
  echo "  baked product schedule ($bn)"
}

# ── Bake update.schedule into autoducks-update.yml's `schedule:` trigger ──
# Modeled line-for-line on patch_product_cron, including the re-insert-after-
# `on:` branch for re-enabling after a disabled run.
patch_update_cron() {
  local bn="autoducks-update.yml"
  local runtime="$RUNTIME_DIR/$bn"
  if [[ ! -f "$runtime" ]]; then
    echo "update-triggers: missing $runtime" >&2
    exit 1
  fi
  local enabled cron
  # NOTE: jq's `//` alternative operator treats `false` like `null` — an
  # explicit `.update.enabled // true` would always resolve to `true`.
  enabled="$(jq -r 'if .update.enabled == false then "false" else "true" end' "$CONFIG")"
  cron="$(jq -r '.update.schedule // "23 6 * * 1"' "$CONFIG")"
  if [[ "$enabled" == "false" ]]; then
    awk '
      /^  schedule:$/ { getline; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  elif grep -q '^  schedule:$' "$runtime"; then
    local cron_line="    - cron: '${cron}'"
    awk -v line="$cron_line" '
      /^    - cron:/ { print line; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  else
    # Re-enabling after a prior enabled:false run: the `schedule:` trigger
    # was removed outright, so reinsert it right after `on:` (its original
    # template position) rather than only rewriting an existing cron line.
    local cron_line="    - cron: '${cron}'"
    awk -v line="$cron_line" '
      /^on:$/ { print; print "  schedule:"; print line; next }
      { print }
    ' "$runtime" > "$runtime.tmp"
  fi
  mv "$runtime.tmp" "$runtime"
  mkdir -p "$WORKFLOW_DIR"
  cp "$runtime" "$WORKFLOW_DIR/$bn"
  echo "  baked update schedule ($bn)"
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
apply_file autoducks-resolver.yml  render_resolver
apply_file autoducks-rework.yml    render_rework
apply_file autoducks-defer.yml     render_defer
apply_file autoducks-fix.yml       render_simple fix
apply_file autoducks-revert.yml    render_simple revert
apply_file autoducks-close.yml     render_simple close
apply_file autoducks-product.yml   render_product
patch_product_cron
apply_file autoducks-update.yml    render_update
patch_update_cron

echo "Done. Commit the modified .github/workflows/ and .autoducks/runtimes/ files."
