#!/usr/bin/env bash
# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_TACTICAL_ZONE_SH_LOADED:-}" ]] && return 0
readonly _TACTICAL_ZONE_SH_LOADED=1

# Wire-format sentinels. These exact strings appear in every Ready-state feature issue.
# Do not change them — they are the stable on-disk format.
readonly TACTICAL_ZONE_BEGIN='<!-- autoducks:tactical:begin -->'
readonly TACTICAL_ZONE_END='<!-- autoducks:tactical:end -->'

# split_body <body_file> <design_zone_out> <tactical_zone_out>
#
# Reads <body_file>, writes:
#   design zone  — everything before the begin marker
#   tactical zone — content strictly between the two markers
#
# Return codes:
#   0 — both markers found; split succeeded
#   1 — no markers found; design_zone_out gets the full body; tactical_zone_out is empty
#   2 — malformed (only one marker present, or end before begin); logs to stderr
split_body() {
  local body_file="$1"
  local design_out="$2"
  local tactical_out="$3"

  # Match markers only as whole lines (leading/trailing whitespace tolerated) so a
  # marker string merely *mentioned* in prose or a code block inside the design or
  # tactical content can't be mistaken for a real sentinel and corrupt the split.
  local has_begin has_end
  has_begin=$(grep -cE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' "$body_file" || true)
  has_end=$(grep -cE '^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$' "$body_file" || true)

  if [[ "$has_begin" -eq 0 && "$has_end" -eq 0 ]]; then
    cp "$body_file" "$design_out"
    : > "$tactical_out"
    return 1
  fi

  if [[ "$has_begin" -eq 0 || "$has_end" -eq 0 ]]; then
    printf 'tactical-zone: malformed body — only one marker present (begin=%s, end=%s)\n' \
      "$has_begin" "$has_end" >&2
    return 2
  fi

  local begin_line end_line
  begin_line=$(grep -nE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' "$body_file" | head -1 | cut -d: -f1)
  end_line=$(grep -nE '^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$' "$body_file" | head -1 | cut -d: -f1)

  if [[ "$begin_line" -ge "$end_line" ]]; then
    printf 'tactical-zone: malformed body — end marker (line %s) is not after begin marker (line %s)\n' \
      "$end_line" "$begin_line" >&2
    return 2
  fi

  # Design zone: every line before the begin marker (marker matched as a whole line,
  # leading/trailing whitespace tolerated)
  awk '/^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$/{exit} {print}' "$body_file" > "$design_out"

  # Tactical zone: lines strictly between the two markers
  awk '
    /^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$/ { found=1; next }
    /^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$/   { exit }
    found { print }
  ' "$body_file" > "$tactical_out"

  return 0
}

# assemble_body <design_zone_file> <tactical_zone_file> <output_file>
#
# Writes the assembled body:
#   <design zone (trailing blank lines normalised)>
#   \n
#   <!-- autoducks:tactical:begin -->
#   <tactical zone>
#   <!-- autoducks:tactical:end -->
#
# Markers are always emitted at column 0.
# Trailing blank lines in the design zone are stripped so the blank-line
# separator between zones stays exactly one blank line across revisions.
assemble_body() {
  local design_file="$1"
  local tactical_file="$2"
  local output_file="$3"

  {
    # Write design zone with trailing blank lines removed (prevents separator drift
    # across revision cycles — the separator \n before the begin marker provides
    # exactly one blank line every time).
    awk '
      /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
      { printf "%s", blanks; blanks = ""; print }
    ' "$design_file"
    printf '\n%s\n' "$TACTICAL_ZONE_BEGIN"
    # `awk '{print}'` guarantees the content ends with exactly one newline, so a
    # tactical zone lacking a trailing newline can't glue itself onto the END
    # marker (which must stay on its own line at column 0). Skip for an empty
    # zone so begin/end stay adjacent.
    if [[ -s "$tactical_file" ]]; then
      awk '{print}' "$tactical_file"
    fi
    printf '%s\n' "$TACTICAL_ZONE_END"
  } > "$output_file"
}

# body_has_markers <body_file>
# Returns 0 if both markers are present, 1 otherwise.
body_has_markers() {
  local body_file="$1"
  grep -qE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' "$body_file" && \
  grep -qE '^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$'   "$body_file"
}

# tactical_zone::task_refs <yaml_block>
# Prints the integer task refs from a plan YAML block's waves[].tasks arrays,
# one per line. T-prefixed placeholder refs (new tasks not yet minted) are
# skipped — only pre-existing integer issue numbers are emitted.
#
# yq-free by design: the mikefarah `yq` binary is not guaranteed on every
# runner or in the unit-test harness (CI only ensures `jq`), whereas awk/grep
# always are. Handles both inline (`tasks: [1, 2]`) and block-sequence
# (`tasks:` / `  - 1`) forms, matching what `yq '.waves[].tasks[]'` did.
# Always exits 0 (empty output when there are no integer refs) so callers
# running under `set -euo pipefail` don't abort on an empty plan.
tactical_zone::task_refs() {
  awk '
    /^[[:space:]]*tasks:[[:space:]]*\[/ {
      s=$0; sub(/^[^[]*\[/,"",s); sub(/\].*/,"",s)
      n=split(s,a,","); for(i=1;i<=n;i++){gsub(/[[:space:]]/,"",a[i]); if(a[i]!="") print a[i]}
      intasks=0; next
    }
    /^[[:space:]]*tasks:[[:space:]]*$/ { intasks=1; next }
    intasks && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
      v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); gsub(/[[:space:]]/,"",v); if(v!="") print v; next
    }
    intasks { intasks=0 }
  ' <<< "$1" | grep -E '^[0-9]+$' || true
}
