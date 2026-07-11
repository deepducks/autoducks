#!/usr/bin/env bash
# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_RESOLVE_CONTEXT_SH_LOADED:-}" ]] && return 0
readonly _RESOLVE_CONTEXT_SH_LOADED=1

# Per-agent context resolver: reads .context.<agent>.parts from autoducks.json
# (falling back to a built-in default manifest when absent), validates every
# requested part against the availability matrix, materializes each enabled
# part via context-parts.sh / design-sections.sh into the agent's canonical
# /tmp targets, and writes /tmp/context-manifest.json.
#
#   resolve_context <agent> <primary_issue_num> [feature_issue_num]
#
# <primary_issue_num> is the issue/PR the agent was dispatched on (the
# feature/bug issue for architect/engineer, the task issue for developer, the
# PR number for reviewer). <feature_issue_num> is the parent feature/bug
# issue that design/plan/task-criteria context is read from; it defaults to
# <primary_issue_num> (architect/engineer, where they're the same issue).

source "$AUTODUCKS_ROOT/core/context/context-parts.sh"
source "$AUTODUCKS_ROOT/core/orchestration/design-sections.sh"

# ── Availability matrix ─────────────────────────────────────────────────
_resolve_context::available_parts() {
  case "$1" in
    architect)
      echo "issue_title issue_description issue_comments issue_metadata"
      ;;
    engineer)
      echo "issue_title issue_description issue_comments issue_metadata design.problem_statement design.proposed_solution design.technical_design design.dependencies design.constraints design.out_of_scope design.full plan"
      ;;
    developer)
      echo "issue_title issue_description issue_comments issue_metadata design.problem_statement design.proposed_solution design.technical_design design.dependencies design.constraints design.out_of_scope design.full plan task_title task_description prior_feedback"
      ;;
    reviewer)
      echo "issue_title issue_description issue_comments issue_metadata design.problem_statement design.proposed_solution design.technical_design design.dependencies design.constraints design.out_of_scope design.full plan task_criteria pr_diff pr_meta security_guidelines"
      ;;
  esac
}

# ── Built-in default manifests (reproduce today's /tmp outputs) ────────
_resolve_context::default_parts() {
  case "$1" in
    architect) printf '%s\n' issue_title issue_description issue_comments ;;
    engineer)  printf '%s\n' issue_title issue_description issue_comments design.full ;;
    developer) printf '%s\n' issue_title issue_description prior_feedback ;;
    reviewer)  printf '%s\n' issue_title issue_description task_criteria design.full pr_diff pr_meta security_guidelines ;;
  esac
}

# Reads .context.<agent>.parts directly from autoducks.json — parallel to how
# authorize.sh reads .security.per_agent, NOT via load-config.sh's defaults
# merge. Falls back to the default manifest when the key or agent is absent.
# An explicit `"parts": []` is a deliberate "select nothing" and is honored
# as-is (it is not "absent").
_resolve_context::read_manifest() {
  local agent="$1"
  local config="$AUTODUCKS_ROOT/autoducks.json"
  local parts_json
  parts_json="$(jq -c --arg a "$agent" '.context[$a].parts? // empty' "$config" 2>/dev/null)" || parts_json=""
  if [[ -z "$parts_json" ]]; then
    _resolve_context::default_parts "$agent"
    return 0
  fi
  jq -r '.[]?' <<< "$parts_json" 2>/dev/null
}

_resolve_context::has() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

_resolve_context::bytes() {
  wc -c < "$1" | tr -d ' '
}

# Manifest accumulator for the current resolve_context call — reset at the
# top of resolve_context, appended to by the route_*/materialize_* helpers.
_RC_MANIFEST_PARTS=()

_resolve_context::record() {
  local id="$1" file="$2" bytes="$3"
  _RC_MANIFEST_PARTS+=("$(jq -nc --arg id "$id" --arg file "$file" --argjson bytes "$bytes" \
    '{id: $id, file: $file, bytes: $bytes}')")
}

# Materializes a single-file part id (context_part::<id> <issue_num> <out>)
# and records it. Covers every catalog id except issue_title/issue_description
# (composed together) and prior_feedback (appended, not written standalone).
_resolve_context::materialize_simple() {
  local id="$1" issue_num="$2" target="$3"
  "context_part::$id" "$issue_num" "$target"
  _resolve_context::record "$id" "$target" "$(_resolve_context::bytes "$target")"
}

# Composes issue_title/task_title + issue_description/task_description into
# the "# <title>\n\n<body>" format used by issue-request.md / task-spec.md.
# `cat` (not command substitution) preserves each part's own trailing
# newline so the byte-for-byte shape matches `jq -r '"# " + .title + ...'`.
_resolve_context::compose_hash_request() {
  local issue_num="$1" target="$2" raw_target="$3" title_id="$4" desc_id="$5"
  local title_tmp="" desc_tmp=""
  [[ -n "$title_id" ]] && { title_tmp="$(mktemp)"; "context_part::$title_id" "$issue_num" "$title_tmp"; }
  [[ -n "$desc_id" ]]  && { desc_tmp="$(mktemp)";  "context_part::$desc_id" "$issue_num" "$desc_tmp"; }

  {
    if [[ -n "$title_id" ]]; then
      printf '# '
      cat "$title_tmp"
      [[ -n "$desc_id" ]] && printf '\n'
    fi
    [[ -n "$desc_id" ]] && cat "$desc_tmp"
  } > "$target"

  if [[ -n "$title_id" ]]; then
    _resolve_context::record "$title_id" "$target" "$(_resolve_context::bytes "$title_tmp")"
  fi
  if [[ -n "$desc_id" ]]; then
    _resolve_context::record "$desc_id" "$target" "$(_resolve_context::bytes "$desc_tmp")"
    [[ -n "$raw_target" ]] && cp "$desc_tmp" "$raw_target"
  fi
  rm -f "$title_tmp" "$desc_tmp" 2>/dev/null || true
}

# Composes issue_title + issue_description into the reviewer's design-plan.md
# shape: `jq -r '.title,.body'` — title, newline, body, newline (no "# "
# prefix, no blank-line separator).
_resolve_context::compose_plain_request() {
  local issue_num="$1" target="$2" title_id="$3" desc_id="$4"
  local title_tmp="" desc_tmp=""
  [[ -n "$title_id" ]] && { title_tmp="$(mktemp)"; "context_part::$title_id" "$issue_num" "$title_tmp"; }
  [[ -n "$desc_id" ]]  && { desc_tmp="$(mktemp)";  "context_part::$desc_id" "$issue_num" "$desc_tmp"; }

  {
    [[ -n "$title_id" ]] && cat "$title_tmp"
    [[ -n "$desc_id" ]]  && cat "$desc_tmp"
  } > "$target"

  [[ -n "$title_id" ]] && _resolve_context::record "$title_id" "$target" "$(_resolve_context::bytes "$title_tmp")"
  [[ -n "$desc_id" ]]  && _resolve_context::record "$desc_id" "$target" "$(_resolve_context::bytes "$desc_tmp")"
  rm -f "$title_tmp" "$desc_tmp" 2>/dev/null || true
}

# design.full / design.<section> / plan — shared by engineer, developer and
# reviewer. design.full always wins over individually-selected design.<section>
# parts (logged ::notice::); when the feature body carries no design-section
# markers at all, any design.<section> selection degrades to the full design
# zone (also logged ::notice::) so no agent ever runs with an empty design.
_resolve_context::route_design() {
  local feature="$1"; shift
  local -a sel=("$@")

  local design_full_requested=0
  local -a design_section_ids=()
  local have_plan=0
  local part
  for part in "${sel[@]}"; do
    case "$part" in
      design.full) design_full_requested=1 ;;
      design.*)    design_section_ids+=("${part#design.}") ;;
      plan)        have_plan=1 ;;
    esac
  done

  if [[ ${#design_section_ids[@]} -gt 0 ]]; then
    local body_file
    body_file="$(mktemp)"
    its::get_issue "$feature" 2>/dev/null | jq -r '.body // empty' > "$body_file" || : > "$body_file"

    if ! design_sections::has_markers "$body_file"; then
      echo "::notice::resolve_context: issue #$feature's body has no design-section markers — falling back to the full design zone."
      design_full_requested=1
      design_section_ids=()
    elif [[ "$design_full_requested" -eq 1 ]]; then
      echo "::notice::resolve_context: design.full overrides the individually-selected design.<section> parts."
      design_section_ids=()
    fi

    local id out
    for id in "${design_section_ids[@]}"; do
      out="/tmp/design-$id.md"
      design_sections::extract "$body_file" "$id" "$out"
      _resolve_context::record "design.$id" "$out" "$(_resolve_context::bytes "$out")"
    done
    rm -f "$body_file"
  fi

  [[ "$design_full_requested" -eq 1 ]] && _resolve_context::materialize_simple design.full "$feature" /tmp/design-zone.md
  [[ "$have_plan" -eq 1 ]] && _resolve_context::materialize_simple plan "$feature" /tmp/tactical-zone-current.md
  return 0
}

# ── Per-agent target-file routing ───────────────────────────────────────

_resolve_context::route_architect() {
  local primary="$1"; shift
  local -a sel=("$@")

  local title_id="" desc_id=""
  _resolve_context::has issue_title "${sel[@]}" && title_id="issue_title"
  _resolve_context::has issue_description "${sel[@]}" && desc_id="issue_description"
  if [[ -n "$title_id" || -n "$desc_id" ]]; then
    _resolve_context::compose_hash_request "$primary" /tmp/issue-request.md /tmp/issue-body-raw.md "$title_id" "$desc_id"
  fi

  if _resolve_context::has issue_comments "${sel[@]}"; then
    local comments_tmp
    comments_tmp="$(mktemp)"
    context_part::issue_comments "$primary" "$comments_tmp"
    {
      echo ""
      echo "## Reviewer feedback / adjustments (steer the revision)"
      echo ""
      cat "$comments_tmp"
    } >> /tmp/issue-request.md
    _resolve_context::record issue_comments /tmp/issue-request.md "$(_resolve_context::bytes "$comments_tmp")"
    rm -f "$comments_tmp"
  fi

  _resolve_context::has issue_metadata "${sel[@]}" && _resolve_context::materialize_simple issue_metadata "$primary" /tmp/issue-meta.md
  return 0
}

_resolve_context::route_engineer() {
  local primary="$1" feature="$2"; shift 2
  local -a sel=("$@")

  local title_id="" desc_id=""
  _resolve_context::has issue_title "${sel[@]}" && title_id="issue_title"
  _resolve_context::has issue_description "${sel[@]}" && desc_id="issue_description"
  if [[ -n "$title_id" || -n "$desc_id" ]]; then
    _resolve_context::compose_hash_request "$primary" /tmp/issue-request.md /tmp/issue-body-raw.md "$title_id" "$desc_id"
  fi

  _resolve_context::has issue_comments "${sel[@]}" && _resolve_context::materialize_simple issue_comments "$primary" /tmp/issue-comments.md
  _resolve_context::has issue_metadata "${sel[@]}" && _resolve_context::materialize_simple issue_metadata "$primary" /tmp/issue-meta.md

  _resolve_context::route_design "$feature" "${sel[@]}"
  return 0
}

_resolve_context::route_developer() {
  local primary="$1" feature="$2"; shift 2
  local -a sel=("$@")

  local title_id="" desc_id=""
  _resolve_context::has issue_title "${sel[@]}" && title_id="issue_title"
  _resolve_context::has task_title "${sel[@]}" && title_id="task_title"
  _resolve_context::has issue_description "${sel[@]}" && desc_id="issue_description"
  _resolve_context::has task_description "${sel[@]}" && desc_id="task_description"
  if [[ -n "$title_id" || -n "$desc_id" ]]; then
    _resolve_context::compose_hash_request "$primary" /tmp/task-spec.md "" "$title_id" "$desc_id"
  fi

  if _resolve_context::has prior_feedback "${sel[@]}"; then
    local fb_tmp
    fb_tmp="$(mktemp)"
    context_part::prior_feedback "$primary" "$fb_tmp"
    cat "$fb_tmp" >> /tmp/task-spec.md
    _resolve_context::record prior_feedback /tmp/task-spec.md "$(_resolve_context::bytes "$fb_tmp")"
    rm -f "$fb_tmp"
  fi

  _resolve_context::has issue_comments "${sel[@]}" && _resolve_context::materialize_simple issue_comments "$feature" /tmp/issue-comments.md
  _resolve_context::has issue_metadata "${sel[@]}" && _resolve_context::materialize_simple issue_metadata "$feature" /tmp/issue-meta.md

  _resolve_context::route_design "$feature" "${sel[@]}"
  return 0
}

_resolve_context::route_reviewer() {
  local primary="$1" feature="$2"; shift 2   # primary = PR number
  local -a sel=("$@")

  local title_id="" desc_id=""
  _resolve_context::has issue_title "${sel[@]}" && title_id="issue_title"
  _resolve_context::has issue_description "${sel[@]}" && desc_id="issue_description"
  if [[ -n "$title_id" || -n "$desc_id" ]]; then
    _resolve_context::compose_plain_request "$feature" /tmp/design-plan.md "$title_id" "$desc_id"
  fi

  _resolve_context::has issue_comments "${sel[@]}" && _resolve_context::materialize_simple issue_comments "$feature" /tmp/issue-comments.md
  _resolve_context::has issue_metadata "${sel[@]}" && _resolve_context::materialize_simple issue_metadata "$feature" /tmp/issue-meta.md
  _resolve_context::has task_criteria "${sel[@]}" && _resolve_context::materialize_simple task_criteria "$feature" /tmp/task-criteria.md
  _resolve_context::has pr_diff "${sel[@]}" && _resolve_context::materialize_simple pr_diff "$primary" /tmp/pr-diff.patch
  _resolve_context::has pr_meta "${sel[@]}" && _resolve_context::materialize_simple pr_meta "$primary" /tmp/pr-meta.md
  _resolve_context::has security_guidelines "${sel[@]}" && _resolve_context::materialize_simple security_guidelines "$primary" /tmp/security-guidelines.md

  _resolve_context::route_design "$feature" "${sel[@]}"
  return 0
}

# ── Entry point ──────────────────────────────────────────────────────────
resolve_context() {
  local agent="$1" primary="$2" feature="${3:-$2}"

  case "$agent" in
    architect|engineer|developer|reviewer) ;;
    *)
      echo "resolve_context: unknown agent '$agent' — expected one of: architect engineer developer reviewer." >&2
      return 1
      ;;
  esac

  _RC_MANIFEST_PARTS=()

  local -a requested=()
  mapfile -t requested < <(_resolve_context::read_manifest "$agent")

  local available_str
  available_str=" $(_resolve_context::available_parts "$agent") "
  local part
  for part in "${requested[@]}"; do
    [[ -z "$part" ]] && continue
    if [[ "$available_str" != *" $part "* ]]; then
      echo "resolve_context: context part '$part' is unknown or not available to agent '$agent'. Fix: remove/replace it in \`.context.$agent.parts\` in \$AUTODUCKS_ROOT/autoducks.json — available parts for '$agent':$available_str" >&2
      return 1
    fi
  done

  case "$agent" in
    architect) _resolve_context::route_architect "$primary" "${requested[@]}" ;;
    engineer)  _resolve_context::route_engineer  "$primary" "$feature" "${requested[@]}" ;;
    developer) _resolve_context::route_developer "$primary" "$feature" "${requested[@]}" ;;
    reviewer)  _resolve_context::route_reviewer  "$primary" "$feature" "${requested[@]}" ;;
  esac

  local manifest_json="[]"
  if [[ ${#_RC_MANIFEST_PARTS[@]} -gt 0 ]]; then
    manifest_json="$(printf '%s\n' "${_RC_MANIFEST_PARTS[@]}" | jq -s '.')"
  fi
  jq -n --arg agent "$agent" --argjson parts "$manifest_json" '{agent: $agent, parts: $parts}' > /tmp/context-manifest.json
}
