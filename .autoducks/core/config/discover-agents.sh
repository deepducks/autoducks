#!/usr/bin/env bash
set -euo pipefail

# ── Custom agent definition discovery ────────────────────────────────
# Scans $AUTODUCKS_BASE_REF for user-authored agent definitions and emits a
# registry every downstream consumer (setup.sh, the trigger generator, the
# dispatcher) can share instead of re-parsing markdown itself. With no base
# ref set — a local `setup.sh` run — it falls back to the live working tree
# (never $AUTODUCKS_PINNED_ROOT — the pinned snapshot contains only
# .autoducks). See "Where definitions come from" below for why the ref wins.
#
# Usage:
#   discover-agents.sh list                 # -> registry JSON on stdout
#   discover-agents.sh get <name>            # -> one descriptor, exit 4 if not found
#
# Roots, highest precedence first (first match wins; later roots still
# appear in the registry with shadowed:true):
#   1. .autoducks/custom/agents/<name>/agent.md
#   2. .claude/agents/<name>.md
#   3. .agents/<name>.md
#   4. .github/agents/<name>.md
#   5. any additional root listed in custom_agents.roots[] in autoducks.json,
#      appended in order (flat <name>.md, same as roots 2-4)
#
# Frontmatter is read with a small, dependency-free reader restricted to
# scalars, inline `[a, b]` sequences and block `- item` sequences. It never
# `eval`s and never invokes a YAML interpreter that could execute tags;
# every recognized value is normalized to JSON via `jq -n --arg`/`--argjson`
# so no definition text is ever re-parsed as shell. Unknown frontmatter keys
# are ignored, not errors.
#
# Validation failures are refusals, not silent skips: each appends
# {source, reason} to errors[] and the scan continues.

if ! command -v jq &>/dev/null; then
  echo "discover-agents: jq required but not installed" >&2
  exit 1
fi

SUBCOMMAND="${1:-}"
GET_NAME=""
case "$SUBCOMMAND" in
  list) ;;
  get)
    GET_NAME="${2:-}"
    if [[ -z "$GET_NAME" ]]; then
      echo "Usage: discover-agents.sh get <name>" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: discover-agents.sh list | discover-agents.sh get <name>" >&2
    exit 1
    ;;
esac

# ── Repo root (live working tree, not the pinned machinery snapshot) ────
REPO_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
CONFIG="${AUTODUCKS_CONFIG:-$REPO_ROOT/.autoducks/autoducks.json}"

# ── Where definitions come from ──────────────────────────────────────
# ALWAYS the base branch, never the checked-out tree. A definition body
# becomes the agent's prompt and its frontmatter asks for tools, so it is
# executable content: on a PR the checkout is refs/pull/N/head, and running
# from there would mean executing code that nobody has reviewed.
#
# Reading from the base ref is what makes the design's "merged, reviewed repo
# content" premise true by construction rather than something checked after
# the fact. It is also why this lane needs no per-definition clamp and no
# per-definition verification: the definition and every custom_agents key
# have only ever one source, and it is the reviewed one.
#
# It is NOT a blanket tool ceiling. A definition that declares no tools falls
# through to .defaults.tools, which autoducks-agent.yml reads via
# load-agent-defaults.sh from the pinned machinery snapshot — reviewed, but a
# different source than this one.
#
# The consequence, stated plainly: an agent cannot be tried from the pull
# request that introduces it. Merge the definition first, then use it.
#
# AUTODUCKS_BASE_REF unset means no ref to read from — a local `setup.sh`
# run — and discovery falls back to the working tree for reporting only.
DEFINITION_REF="${AUTODUCKS_BASE_REF:-}"

# def_cat PATH — the file's contents as of DEFINITION_REF (or from disk when
# there is no ref).
def_cat() {
  if [[ -n "$DEFINITION_REF" ]]; then
    git -C "$REPO_ROOT" show "$DEFINITION_REF:$1" 2>/dev/null
  else
    cat "$REPO_ROOT/$1" 2>/dev/null
  fi
}

# def_config — autoducks.json as of DEFINITION_REF. Same reasoning: roots[]
# and the per-agent tool grants are privilege-bearing.
# Resolved once, here: every call site reads it in a command substitution, so
# assigning inside the function would only ever populate a subshell's copy.
if [[ -n "$DEFINITION_REF" ]]; then
  _DEF_CONFIG="$(git -C "$REPO_ROOT" show "$DEFINITION_REF:.autoducks/autoducks.json" 2>/dev/null || echo '{}')"
elif [[ -f "$CONFIG" ]]; then
  _DEF_CONFIG="$(cat "$CONFIG" 2>/dev/null || echo '{}')"
else
  _DEF_CONFIG='{}'
fi
[[ -n "$_DEF_CONFIG" ]] || _DEF_CONFIG='{}'
def_config() { printf '%s' "$_DEF_CONFIG"; }

# def_list ROOT KIND — "<mode> <repo-relative path>" for every definition
# under ROOT as of DEFINITION_REF, sorted by path, NUL-terminated. The mode is
# carried so a symlink (120000) can be refused: reading from a ref means there
# is no realpath to compare against the repo root.
#
# `ls-tree -z` is load-bearing, not a style choice. Without it core.quotePath
# (default true) C-quotes any path holding non-ASCII bytes, a quote, a
# backslash or a control character — `naïve.md` comes back as
# `"na\303\257ve.md"` — and the leading quote makes the entry match neither
# glob below, so it would be dropped silently. This file refuses; it does not
# skip. `-c core.quotePath=false` would only cover the non-ASCII case, and
# neither form protects the line-based reader from a path with a newline in
# it. -z gives raw bytes and a NUL record separator, which covers all of it.
def_list() {
  local root="$1" kind="$2"
  if [[ -n "$DEFINITION_REF" ]]; then
    git -C "$REPO_ROOT" ls-tree -r -z "$DEFINITION_REF" -- "$root" 2>/dev/null \
      | while IFS= read -r -d '' _rec; do
          # "<mode> <type> <sha>\t<path>" — split on the tab, then take the
          # mode off the front of the metadata half.
          local _meta="${_rec%%$'\t'*}" f="${_rec#*$'\t'}" mode
          mode="${_meta%% *}"
          if [[ "$kind" == "nested" ]]; then
            # exactly <root>/<name>/agent.md — no deeper nesting, matching the
            # -mindepth 2 -maxdepth 2 the local branch uses.
            [[ "$f" == "$root"/*/agent.md && "$f" != "$root"/*/*/* ]] || continue
          else
            [[ "$f" == "$root"/*.md && "$f" != "$root"/*/* ]] || continue
          fi
          printf '%s %s\0' "$mode" "$f"
        done | sort -z -k2
  else
    local depth_args=()
    if [[ "$kind" == "nested" ]]; then
      depth_args=(-mindepth 2 -maxdepth 2 -name 'agent.md')
    else
      depth_args=(-mindepth 1 -maxdepth 1 -name '*.md')
    fi
    # -print0 for the same reason as -z above: the record separator has to be
    # a byte that cannot occur in a path.
    find "$REPO_ROOT/$root" "${depth_args[@]}" -print0 2>/dev/null \
      | while IFS= read -r -d '' p; do
          local f="${p#"$REPO_ROOT/"}"
          if [[ -L "$REPO_ROOT/$f" ]]; then printf '120000 %s\0' "$f"; else printf '100644 %s\0' "$f"; fi
        done | sort -z -k2
  fi
}

# ── Reserved names: built-in verbs/synonyms plus every configured
# triggers.<agent>[] alias — a definition called architect.md must never
# shadow /architect. ──────────────────────────────────────────────────────
#
# AUTODUCKS_AGENTS / AUTODUCKS_BUILTIN_VERBS — see agent-roster.sh. This file
# used to carry its own copy of both lists, which is the drift #167 was filed
# about and it came back here: the copies were already a release behind,
# missing `agent`, so an agent.md definition was not reserved and could shadow
# /agent, and aliases configured under triggers.agent[] were not reserved
# either. Third consumer of the roster, third file that must not spell it out.
_DA_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DA_SH_DIR/agent-roster.sh"

# Aliases come from the base config as well: reservation is what stops a
# definition from shadowing a real verb, so reading it from the checked-out
# tree would let a PR head delete an alias and free the name it protected.
RESERVED_NAMES=" $AUTODUCKS_BUILTIN_VERBS "
for _a in "${AUTODUCKS_AGENTS[@]}"; do
  while IFS= read -r _alias; do
    [[ -z "$_alias" ]] && continue
    RESERVED_NAMES+="$_alias "
  done < <(def_config | jq -r --arg a "$_a" '.triggers[$a][]? // empty' 2>/dev/null)
done

is_reserved() {
  case "$RESERVED_NAMES" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Roots, precedence order ──────────────────────────────────────────
declare -a ROOT_DIRS=()
declare -a ROOT_KINDS=()   # "nested" (<root>/<name>/agent.md) | "flat" (<root>/<name>.md)

ROOT_DIRS+=(".autoducks/custom/agents"); ROOT_KINDS+=("nested")
ROOT_DIRS+=(".claude/agents");           ROOT_KINDS+=("flat")
ROOT_DIRS+=(".agents");                  ROOT_KINDS+=("flat")
ROOT_DIRS+=(".github/agents");           ROOT_KINDS+=("flat")

# No `-f "$CONFIG"` guard: the roots come from def_config, so gating them on
# the *live* file existing would drop configured roots whenever the checkout
# has no autoducks.json — and would let deleting that file on a PR head
# change discovery.
while IFS= read -r _extra; do
  [[ -z "$_extra" ]] && continue
  # Trailing slashes have to go: the ref branch matches paths with `[[ ]]`
  # globbing, where "extra-agents//*.md" never matches "extra-agents/x.md".
  # The old filesystem glob tolerated the double slash, so a config that used
  # to work would silently stop discovering anything.
  while [[ "$_extra" == */ && "$_extra" != "/" ]]; do _extra="${_extra%/}"; done
  ROOT_DIRS+=("$_extra"); ROOT_KINDS+=("flat")
done < <(def_config | jq -r '.custom_agents.roots[]? // empty' 2>/dev/null)

# ── Small restricted string helpers (no eval, no external parser) ────
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_strip_quotes() {
  local s="$1"
  if (( ${#s} >= 2 )) && [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
    s="${s:1:${#s}-2}"
  elif (( ${#s} >= 2 )) && [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

arr_to_json() {
  if (( $# == 0 )); then
    echo "[]"
  else
    jq -cn '$ARGS.positional' --args "$@"
  fi
}

# resolve_model_alias VALUE — mirrors parse-directive.sh's model: handling:
# opus/sonnet/haiku expand to the full model id, claude-* passes through
# unchanged, anything else is dropped (ignored, not fatal).
resolve_model_alias() {
  local v="$1"
  case "$v" in
    "")       printf '' ;;
    opus)     printf 'claude-opus-5' ;;
    sonnet)   printf 'claude-sonnet-5' ;;
    haiku)    printf 'claude-haiku-4-5' ;;
    claude-*) printf '%s' "$v" ;;
    *)        printf '' ;;
  esac
}

# ── Frontmatter parser ───────────────────────────────────────────────
# Sets (globals, reset on every call): FM_NAME, FM_DESCRIPTION, FM_MODEL,
# FM_EFFORT, FM_MAX_TURNS, FM_SURFACE, FM_TOOLS_SET, FM_TOOLS_ARR,
# FM_CONTEXT_SET, FM_CONTEXT_ARR, FM_LABELS_SET, FM_LABELS_ARR, BODY_TEXT.
parse_definition() {
  local file="$1"
  FM_NAME=""; FM_DESCRIPTION=""; FM_MODEL=""; FM_EFFORT=""; FM_MAX_TURNS=""; FM_SURFACE=""
  FM_TOOLS_SET=0; FM_TOOLS_ARR=()
  FM_CONTEXT_SET=0; FM_CONTEXT_ARR=()
  FM_LABELS_SET=0; FM_LABELS_ARR=()

  local -a _LINES=()
  mapfile -t _LINES < "$file"

  local fm_start=-1 fm_end=-1 _i
  if [[ "${_LINES[0]:-}" =~ ^---[[:space:]]*$ ]]; then
    fm_start=0
    for (( _i=1; _i<${#_LINES[@]}; _i++ )); do
      if [[ "${_LINES[$_i]}" =~ ^---[[:space:]]*$ ]]; then
        fm_end=$_i
        break
      fi
    done
  fi

  local body_start=0
  if (( fm_start == 0 && fm_end > 0 )); then
    body_start=$((fm_end + 1))
    _parse_frontmatter_block _LINES "$fm_end"
  fi

  if (( body_start < ${#_LINES[@]} )); then
    BODY_TEXT="$(printf '%s\n' "${_LINES[@]:$body_start}")"
  else
    BODY_TEXT=""
  fi
}

# _parse_frontmatter_block <lines-array-name> <fm_end-index>
_parse_frontmatter_block() {
  local -n _fpb_lines="$1"
  local fm_end="$2"
  local j=1

  while (( j < fm_end )); do
    local line="${_fpb_lines[$j]}"

    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
      j=$((j + 1)); continue
    fi
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      j=$((j + 1)); continue
    fi

    local key="${BASH_REMATCH[1]}"
    local rest
    rest="$(_trim "${BASH_REMATCH[2]}")"
    local vtype val
    local -a varr=()

    if [[ -z "$rest" ]]; then
      local k=$((j + 1))
      while (( k < fm_end )); do
        local l="${_fpb_lines[$k]}"
        if [[ "$l" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
          varr+=("$(_strip_quotes "$(_trim "${BASH_REMATCH[1]}")")")
          k=$((k + 1))
        else
          break
        fi
      done
      if (( ${#varr[@]} > 0 )); then
        vtype="array"
      else
        vtype="scalar"; val=""
      fi
      j=$k
    elif [[ "$rest" == \[*\] ]]; then
      vtype="array"
      local inner="${rest#\[}"
      inner="${inner%\]}"
      local -a parts=()
      IFS=',' read -ra parts <<< "$inner"
      local p
      for p in "${parts[@]}"; do
        varr+=("$(_strip_quotes "$(_trim "$p")")")
      done
      j=$((j + 1))
    else
      vtype="scalar"
      val="$(_strip_quotes "$rest")"
      j=$((j + 1))
    fi

    case "$key" in
      name)        [[ "$vtype" == scalar ]] && FM_NAME="$val" ;;
      description) [[ "$vtype" == scalar ]] && FM_DESCRIPTION="$val" ;;
      model)       [[ "$vtype" == scalar ]] && FM_MODEL="$val" ;;
      effort)      [[ "$vtype" == scalar ]] && FM_EFFORT="$val" ;;
      max_turns)   [[ "$vtype" == scalar ]] && FM_MAX_TURNS="$val" ;;
      surface)     [[ "$vtype" == scalar ]] && FM_SURFACE="$val" ;;
      tools)
        FM_TOOLS_SET=1
        FM_TOOLS_ARR=()
        if [[ "$vtype" == array ]]; then
          FM_TOOLS_ARR=("${varr[@]}")
        else
          local -a _tparts=()
          IFS=',' read -ra _tparts <<< "$val"
          local tp
          for tp in "${_tparts[@]}"; do
            tp="$(_trim "$tp")"
            [[ -n "$tp" ]] && FM_TOOLS_ARR+=("$tp")
          done
        fi
        ;;
      context)
        if [[ "$vtype" == array ]]; then
          FM_CONTEXT_SET=1
          FM_CONTEXT_ARR=("${varr[@]}")
        fi
        ;;
      labels)
        if [[ "$vtype" == array ]]; then
          FM_LABELS_SET=1
          FM_LABELS_ARR=("${varr[@]}")
        fi
        ;;
      *) : ;;  # unknown key — ignored, not an error
    esac
  done
}

# ── Registry accumulators ────────────────────────────────────────────
declare -a AGENTS_JSON=()
declare -a ERRORS_JSON=()
declare -A WINNER_SEEN=()

emit_error() {
  local source="$1" reason="$2"
  ERRORS_JSON+=("$(jq -cn --arg source "$source" --arg reason "$reason" '{source:$source, reason:$reason}')")
}


# process_definition <file> <rel_source> <root> <precedence> <name>
process_definition() {
  local file="$1" rel_source="$2" root="$3" precedence="$4" name="$5"

  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    emit_error "$rel_source" "invalid-name"
    return
  fi

  if is_reserved "$name"; then
    emit_error "$rel_source" "reserved-name"
    return
  fi

  local size
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  if (( size > 65536 )); then
    emit_error "$rel_source" "too-large"
    return
  fi

  parse_definition "$file"

  local body_trimmed
  body_trimmed="$(printf '%s' "$BODY_TEXT" | tr -d '[:space:]')"
  if [[ -z "$body_trimmed" ]]; then
    emit_error "$rel_source" "empty-body"
    return
  fi

  if [[ -n "$FM_NAME" && "$FM_NAME" != "$name" ]]; then
    echo "::warning::discover-agents: frontmatter name '$FM_NAME' does not match filename '$name' in $rel_source; using '$name'" >&2
  fi

  local body_bytes
  body_bytes="$(printf '%s' "$BODY_TEXT" | wc -c | tr -d '[:space:]')"

  # ── Config merge: custom_agents.agents.<name> ──────────────────────
  # One config source, the same ref the definition came from.
  local cfg="{}"
  cfg="$(def_config | jq -c --arg n "$name" '.custom_agents.agents[$n] // {}' 2>/dev/null || echo '{}')"
  [[ -n "$cfg" ]] || cfg='{}'

  # tools: config wins over frontmatter
  local tools_declared_json tools_effective_json cfg_tools_json
  tools_declared_json="$(arr_to_json "${FM_TOOLS_ARR[@]}")"
  cfg_tools_json="$(jq -c 'if has("tools") then (.tools | if type=="array" then . else (split(",") | map(gsub("^\\s+|\\s+$";""))) end) else empty end' <<<"$cfg" 2>/dev/null || echo "")"
  if [[ -n "$cfg_tools_json" ]]; then
    tools_effective_json="$cfg_tools_json"
  else
    tools_effective_json="$tools_declared_json"
  fi

  # model: frontmatter wins over config, both alias-resolved
  local cfg_model_raw model_effective
  cfg_model_raw="$(jq -r '.model // empty' <<<"$cfg" 2>/dev/null || echo "")"
  if [[ -n "$FM_MODEL" ]]; then
    model_effective="$(resolve_model_alias "$FM_MODEL")"
  else
    model_effective="$(resolve_model_alias "$cfg_model_raw")"
  fi

  # effort: frontmatter wins over config
  local cfg_effort effort_effective
  cfg_effort="$(jq -r '.effort // empty' <<<"$cfg" 2>/dev/null || echo "")"
  effort_effective="$FM_EFFORT"
  [[ -z "$effort_effective" ]] && effort_effective="$cfg_effort"

  # max_turns: frontmatter wins over config
  local cfg_max_turns max_turns_effective
  cfg_max_turns="$(jq -r '.max_turns // empty' <<<"$cfg" 2>/dev/null || echo "")"
  max_turns_effective="$FM_MAX_TURNS"
  [[ -z "$max_turns_effective" ]] && max_turns_effective="$cfg_max_turns"
  [[ "$max_turns_effective" =~ ^[0-9]+$ ]] || max_turns_effective=""

  # context: frontmatter wins over config
  local context_json
  if (( FM_CONTEXT_SET == 1 )); then
    context_json="$(arr_to_json "${FM_CONTEXT_ARR[@]}")"
  else
    context_json="$(jq -c '.context // empty' <<<"$cfg" 2>/dev/null || echo "")"
    [[ -z "$context_json" ]] && context_json="[]"
  fi

  local labels_json
  labels_json="$(arr_to_json "${FM_LABELS_ARR[@]}")"

  local surface_effective="${FM_SURFACE:-issue}"
  [[ -z "$surface_effective" ]] && surface_effective="issue"

  local shadowed="false"
  if [[ -n "${WINNER_SEEN[$name]:-}" ]]; then
    shadowed="true"
  else
    WINNER_SEEN[$name]=1
  fi

  local desc
  desc="$(jq -cn \
    --arg name "$name" \
    --arg description "$FM_DESCRIPTION" \
    --arg source "$rel_source" \
    --arg root "$root" \
    --argjson precedence "$precedence" \
    --argjson shadowed "$shadowed" \
    --arg model "$model_effective" \
    --arg effort "$effort_effective" \
    --arg max_turns "$max_turns_effective" \
    --argjson tools_declared "$tools_declared_json" \
    --argjson tools_effective "$tools_effective_json" \
    --argjson context "$context_json" \
    --arg surface "$surface_effective" \
    --argjson labels "$labels_json" \
    --argjson body_bytes "$body_bytes" \
    '{
      name: $name,
      description: (if $description == "" then null else $description end),
      source: $source,
      root: $root,
      precedence: $precedence,
      shadowed: $shadowed,
      model: (if $model == "" then null else $model end),
      effort: (if $effort == "" then null else $effort end),
      max_turns: (if $max_turns == "" then null else ($max_turns | tonumber) end),
      tools_declared: $tools_declared,
      tools_effective: $tools_effective,
      context: $context,
      surface: $surface,
      labels: $labels,
      body_bytes: $body_bytes
    }')"

  AGENTS_JSON+=("$desc")
}

# ── Scan roots in precedence order ───────────────────────────────────
_DEF_TMP="$(mktemp -d)"
trap 'rm -rf "$_DEF_TMP"' EXIT

for _ridx in "${!ROOT_DIRS[@]}"; do
  root="${ROOT_DIRS[$_ridx]}"
  kind="${ROOT_KINDS[$_ridx]}"
  precedence=$((_ridx + 1))

  # NUL-delimited: def_list emits raw paths, so no separator can appear inside
  # one. Splitting mode off the front by hand keeps the rest of the record —
  # spaces and all — intact as the path.
  while IFS= read -r -d '' _rec; do
    mode="${_rec%% *}"
    rel_source="${_rec#* }"
    [[ -n "$rel_source" ]] || continue

    if [[ "$kind" == "nested" ]]; then
      name="$(basename "$(dirname "$rel_source")")"
    else
      name="$(basename "$rel_source" .md)"
    fi

    # A symlink is content the ref does not actually vouch for — it points
    # somewhere else, possibly outside the tree. Refuse rather than follow.
    if [[ "$mode" == "120000" ]]; then
      emit_error "$rel_source" "symlink-escape"
      continue
    fi

    file="$_DEF_TMP/def.md"
    # Only a genuine read failure is "unreadable". An empty file is NOT
    # short-circuited here: process_definition checks the name against the
    # reserved list before it looks at content, and a reserved name must be
    # refused as reserved-name whatever the file holds. It reaches the same
    # empty-body verdict a moment later, in the right order.
    if ! def_cat "$rel_source" > "$file" 2>/dev/null; then
      emit_error "$rel_source" "unreadable"
      continue
    fi

    process_definition "$file" "$rel_source" "$root" "$precedence" "$name"
  done < <(def_list "$root" "$kind")
done

# ── Assemble + emit ───────────────────────────────────────────────────
json_array_of() {
  local -n _arr="$1"
  if (( ${#_arr[@]} == 0 )); then
    echo "[]"
  else
    printf '%s\n' "${_arr[@]}" | jq -s -c '.'
  fi
}

AGENTS_ARR_JSON="$(json_array_of AGENTS_JSON)"
ERRORS_ARR_JSON="$(json_array_of ERRORS_JSON)"
REGISTRY_JSON="$(jq -cn --argjson agents "$AGENTS_ARR_JSON" --argjson errors "$ERRORS_ARR_JSON" '{agents:$agents, errors:$errors}')"

case "$SUBCOMMAND" in
  list)
    printf '%s\n' "$REGISTRY_JSON"
    exit 0
    ;;
  get)
    MATCH="$(jq -c --arg n "$GET_NAME" '.agents[] | select(.name == $n and .shadowed == false)' <<<"$REGISTRY_JSON" | head -1)"
    if [[ -z "$MATCH" ]]; then
      exit 4
    fi
    printf '%s\n' "$MATCH"
    exit 0
    ;;
esac
