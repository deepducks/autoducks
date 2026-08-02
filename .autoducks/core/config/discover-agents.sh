#!/usr/bin/env bash
set -euo pipefail

# ── Custom agent definition discovery ────────────────────────────────
# Scans the *live working tree* (never $AUTODUCKS_PINNED_ROOT — the pinned
# snapshot contains only .autoducks) for user-authored agent definitions and
# emits a registry every downstream consumer (setup.sh, the trigger
# generator, the dispatcher) can share instead of re-parsing markdown itself.
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

RESERVED_NAMES=" $AUTODUCKS_BUILTIN_VERBS "
if [[ -f "$CONFIG" ]]; then
  for _a in "${AUTODUCKS_AGENTS[@]}"; do
    while IFS= read -r _alias; do
      [[ -z "$_alias" ]] && continue
      RESERVED_NAMES+="$_alias "
    done < <(jq -r --arg a "$_a" '.triggers[$a][]? // empty' "$CONFIG" 2>/dev/null)
  done
fi

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

if [[ -f "$CONFIG" ]]; then
  while IFS= read -r _extra; do
    [[ -z "$_extra" ]] && continue
    ROOT_DIRS+=("$_extra"); ROOT_KINDS+=("flat")
  done < <(jq -r '.custom_agents.roots[]? // empty' "$CONFIG" 2>/dev/null)
fi

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

REPO_ROOT_REAL="$(realpath "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"

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

  local resolved
  resolved="$(realpath "$file" 2>/dev/null || echo "")"
  if [[ -z "$resolved" || "$resolved" != "$REPO_ROOT_REAL"/* ]]; then
    emit_error "$rel_source" "symlink-escape"
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
  local cfg="{}"
  if [[ -f "$CONFIG" ]]; then
    cfg="$(jq -c --arg n "$name" '.custom_agents.agents[$n] // {}' "$CONFIG" 2>/dev/null || echo '{}')"
  fi

  # The tool grant is read from the BASE ref's autoducks.json, never the
  # checked-out one. CONFIG resolves under $REPO_ROOT, which on a PR surface
  # is the PR head — so a contributor who touches nothing but autoducks.json
  # could add custom_agents.agents.<name>.tools = ["Bash"] for an already
  # merged, unmodified definition. The definition-file clamp below would not
  # fire (the file is byte-identical to base) and the escalation would land
  # through the higher-precedence input instead. Everything else the config
  # supplies (model, context, labels, …) is not a privilege and keeps reading
  # the live file.
  local cfg_tools_src="$cfg"
  if [[ -n "${AUTODUCKS_BASE_REF:-}" ]]; then
    local base_cfg
    base_cfg="$(git -C "$REPO_ROOT" show "$AUTODUCKS_BASE_REF:.autoducks/autoducks.json" 2>/dev/null \
      | jq -c --arg n "$name" '.custom_agents.agents[$n] // {}' 2>/dev/null || echo '{}')"
    [[ -n "$base_cfg" ]] || base_cfg='{}'
    cfg_tools_src="$base_cfg"
  fi

  # tools: config wins over frontmatter
  local tools_declared_json tools_effective_json cfg_tools_json
  tools_declared_json="$(arr_to_json "${FM_TOOLS_ARR[@]}")"
  cfg_tools_json="$(jq -c 'if has("tools") then (.tools | if type=="array" then . else (split(",") | map(gsub("^\\s+|\\s+$";""))) end) else empty end' <<<"$cfg_tools_src" 2>/dev/null || echo "")"
  if [[ -n "$cfg_tools_json" ]]; then
    tools_effective_json="$cfg_tools_json"
  else
    tools_effective_json="$tools_declared_json"
  fi

  # ── Unverified definitions cannot grant themselves tools ──────────────
  # The design's no-ceiling rule rests on definitions being merged, reviewed
  # repo content. On a PR surface that premise does not hold: the checkout is
  # refs/pull/N/head, so a contributor can ship `surface: pr` + `tools: [Bash]`
  # and have a maintainer's routine `/agent <name>` run it with contents:write
  # and the app token. Nothing about that content has been reviewed.
  #
  # So the grant is clamped to the lane's own defaults.json whenever the
  # definition does not appear, byte-identical, on the base ref. A definition
  # merged on the default branch is unaffected and keeps the full no-ceiling
  # behaviour; a new or edited one still runs — which is what makes testing an
  # agent from its own PR possible — just with the lane default tool set.
  local verified="unchecked"
  if [[ -n "${AUTODUCKS_BASE_REF:-}" ]]; then
    local rel="$rel_source"
    # `git diff` rather than comparing the raw blob against the working-tree
    # file: git applies the same clean/smudge filters to both sides. A raw
    # byte compare reports every file as changed in any repo using
    # core.autocrlf or a `text=auto eol=crlf` .gitattributes, which would
    # clamp every custom agent in that repo for no reason.
    if git -C "$REPO_ROOT" cat-file -e "$AUTODUCKS_BASE_REF:$rel" 2>/dev/null &&
       git -C "$REPO_ROOT" diff --quiet "$AUTODUCKS_BASE_REF" -- "$rel" 2>/dev/null; then
      verified="base"
    else
      verified="unverified"
      # Clamp to a dedicated `unverified_tools` set, NOT to the lane default.
      # The lane default is calibrated for definitions that have been through
      # review; it includes Write, Edit, WebFetch and WebSearch. An unverified
      # body is injected into the prompt verbatim, so clamping to that set
      # would still let attacker-authored text read the repository and encode
      # what it finds into a WebFetch URL. `unverified_tools` drops network
      # egress and filesystem writes; what remains is read and inspect.
      #
      # Residual risk, stated so the next reader does not over-trust this:
      # the definition BODY is still unreviewed content driving the prompt.
      # Clamped is not contained — it is a smaller blast radius.
      local lane_defaults="${AUTODUCKS_ROOT:-$REPO_ROOT/.autoducks}/agents/agent/defaults.json"
      local lane_tools_json=""
      [[ -f "$lane_defaults" ]] &&
        lane_tools_json="$(jq -c '.unverified_tools // .tools // []' "$lane_defaults" 2>/dev/null || echo "")"
      [[ -n "$lane_tools_json" ]] || lane_tools_json='[]'
      if [[ "$tools_effective_json" != "$lane_tools_json" ]]; then
        echo "::warning::discover-agents: '$name' ($rel) differs from $AUTODUCKS_BASE_REF — tool grant clamped to the lane default." >&2
      fi
      tools_effective_json="$lane_tools_json"
    fi
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
    --arg verified "$verified" \
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
      verified: $verified,
      body_bytes: $body_bytes
    }')"

  AGENTS_JSON+=("$desc")
}

# ── Scan roots in precedence order ───────────────────────────────────
shopt -s nullglob

for _ridx in "${!ROOT_DIRS[@]}"; do
  root="${ROOT_DIRS[$_ridx]}"
  kind="${ROOT_KINDS[$_ridx]}"
  precedence=$((_ridx + 1))
  abs_root="$REPO_ROOT/$root"
  [[ -d "$abs_root" ]] || continue

  declare -a candidates=()
  if [[ "$kind" == "nested" ]]; then
    candidates=("$abs_root"/*/agent.md)
  else
    candidates=("$abs_root"/*.md)
  fi
  (( ${#candidates[@]} == 0 )) && continue

  declare -a sorted=()
  while IFS= read -r _c; do
    sorted+=("$_c")
  done < <(printf '%s\n' "${candidates[@]}" | sort)

  for file in "${sorted[@]}"; do
    [[ -f "$file" ]] || continue
    rel_source="${file#"$REPO_ROOT"/}"
    if [[ "$kind" == "nested" ]]; then
      name="$(basename "$(dirname "$file")")"
    else
      name="$(basename "$file" .md)"
    fi
    process_definition "$file" "$rel_source" "$root" "$precedence" "$name"
  done
done

shopt -u nullglob

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
