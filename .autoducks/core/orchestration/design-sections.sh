#!/usr/bin/env bash
# Guard against double-sourcing (readonly would error on second source otherwise)
[[ -n "${_DESIGN_SECTIONS_SH_LOADED:-}" ]] && return 0
readonly _DESIGN_SECTIONS_SH_LOADED=1

# Wire-format sentinels. These exact strings appear in Ready-state feature
# issues emitted by the Architect's post.sh and consumed by downstream pre.sh
# hooks. Do not change them — they are the stable on-disk format.
readonly DESIGN_SECTION_PROBLEM_STATEMENT_BEGIN='<!-- autoducks:design:problem_statement:begin -->'
readonly DESIGN_SECTION_PROBLEM_STATEMENT_END='<!-- autoducks:design:problem_statement:end -->'
readonly DESIGN_SECTION_PROPOSED_SOLUTION_BEGIN='<!-- autoducks:design:proposed_solution:begin -->'
readonly DESIGN_SECTION_PROPOSED_SOLUTION_END='<!-- autoducks:design:proposed_solution:end -->'
readonly DESIGN_SECTION_TECHNICAL_DESIGN_BEGIN='<!-- autoducks:design:technical_design:begin -->'
readonly DESIGN_SECTION_TECHNICAL_DESIGN_END='<!-- autoducks:design:technical_design:end -->'
readonly DESIGN_SECTION_DEPENDENCIES_BEGIN='<!-- autoducks:design:dependencies:begin -->'
readonly DESIGN_SECTION_DEPENDENCIES_END='<!-- autoducks:design:dependencies:end -->'
readonly DESIGN_SECTION_CONSTRAINTS_BEGIN='<!-- autoducks:design:constraints:begin -->'
readonly DESIGN_SECTION_CONSTRAINTS_END='<!-- autoducks:design:constraints:end -->'
readonly DESIGN_SECTION_OUT_OF_SCOPE_BEGIN='<!-- autoducks:design:out_of_scope:begin -->'
readonly DESIGN_SECTION_OUT_OF_SCOPE_END='<!-- autoducks:design:out_of_scope:end -->'

# Canonical section order (heading → id). Fixed — downstream pre.sh hooks
# iterate sections in this order.
readonly _DESIGN_SECTION_IDS=(
  problem_statement
  proposed_solution
  technical_design
  dependencies
  constraints
  out_of_scope
)
readonly _DESIGN_SECTION_HEADINGS=(
  "Problem Statement"
  "Proposed Solution"
  "Technical Design"
  "Dependencies"
  "Constraints"
  "Out of Scope"
)

# _design_sections::begin_re <id> / _design_sections::end_re <id>
# Whole-line marker regex for a section id (leading/trailing whitespace
# tolerated) so a marker string merely *mentioned* in prose or a code block
# can't be mistaken for a real sentinel and corrupt a split.
_design_sections::begin_re() {
  printf '^[[:space:]]*<!-- autoducks:design:%s:begin -->[[:space:]]*$' "$1"
}
_design_sections::end_re() {
  printf '^[[:space:]]*<!-- autoducks:design:%s:end -->[[:space:]]*$' "$1"
}

# design_sections::has_markers <body_file>
# Returns 0 if any section marker pair (begin+end for the same id) is
# present, 1 otherwise.
design_sections::has_markers() {
  local body_file="$1"
  local id
  for id in "${_DESIGN_SECTION_IDS[@]}"; do
    if grep -qE "$(_design_sections::begin_re "$id")" "$body_file" && \
       grep -qE "$(_design_sections::end_re "$id")" "$body_file"; then
      return 0
    fi
  done
  return 1
}

# design_sections::list <body_file>
# Prints the ids of sections whose marker pair is present, one per line, in
# canonical order. Always exits 0 (empty output when none are present).
design_sections::list() {
  local body_file="$1"
  local id
  for id in "${_DESIGN_SECTION_IDS[@]}"; do
    if grep -qE "$(_design_sections::begin_re "$id")" "$body_file" && \
       grep -qE "$(_design_sections::end_re "$id")" "$body_file"; then
      printf '%s\n' "$id"
    fi
  done
  return 0
}

# design_sections::extract <body_file> <id> <out_file>
# Writes the section's content (the lines strictly between its begin/end
# markers) to <out_file>. If the section is absent or malformed (only one
# marker present, or end before begin), writes an empty file. Always
# returns 0 — extraction never errors, callers can rely on <out_file>
# existing either way.
design_sections::extract() {
  local body_file="$1"
  local id="$2"
  local out_file="$3"

  local begin_re end_re
  begin_re="$(_design_sections::begin_re "$id")"
  end_re="$(_design_sections::end_re "$id")"

  local has_begin has_end
  has_begin=$(grep -cE "$begin_re" "$body_file" || true)
  has_end=$(grep -cE "$end_re" "$body_file" || true)

  if [[ "$has_begin" -eq 0 || "$has_end" -eq 0 ]]; then
    : > "$out_file"
    return 0
  fi

  local begin_line end_line
  begin_line=$(grep -nE "$begin_re" "$body_file" | head -1 | cut -d: -f1)
  end_line=$(grep -nE "$end_re" "$body_file" | head -1 | cut -d: -f1)

  if [[ "$begin_line" -ge "$end_line" ]]; then
    : > "$out_file"
    return 0
  fi

  awk -v begin_re="$begin_re" -v end_re="$end_re" '
    $0 ~ begin_re { found=1; next }
    $0 ~ end_re   { exit }
    found { print }
  ' "$body_file" > "$out_file"

  return 0
}

# design_sections::wrap <spec_file> <out_file>
# Maps each recognized heading line — `## <Heading>` or a stand-alone
# `**<Heading>**` — to its marker-wrapped block, for all six canonical
# sections. Any prose above the first recognized heading is preserved
# verbatim as the design preamble. A body with zero recognized headings
# passes through unchanged.
design_sections::wrap() {
  local spec_file="$1"
  local out_file="$2"

  local total_lines
  total_lines=$(awk 'END{print NR}' "$spec_file")

  local -a hit_lines=()
  local -a hit_ids=()

  local i id heading
  for i in "${!_DESIGN_SECTION_IDS[@]}"; do
    id="${_DESIGN_SECTION_IDS[$i]}"
    heading="${_DESIGN_SECTION_HEADINGS[$i]}"

    local ln
    while IFS=: read -r ln; do
      [[ -n "$ln" ]] && { hit_lines+=("$ln"); hit_ids+=("$id"); }
    done < <(grep -nE "^[[:space:]]*##[[:space:]]+${heading}[[:space:]]*\$" "$spec_file" | cut -d: -f1 || true)

    while IFS=: read -r ln; do
      [[ -n "$ln" ]] && { hit_lines+=("$ln"); hit_ids+=("$id"); }
    done < <(grep -nE "^[[:space:]]*\*\*${heading}\*\*[[:space:]]*\$" "$spec_file" | cut -d: -f1 || true)
  done

  if [[ ${#hit_lines[@]} -eq 0 ]]; then
    cp "$spec_file" "$out_file"
    return 0
  fi

  # Sort heading occurrences by line number (stable order for wrap output)
  local -a order
  mapfile -t order < <(
    for idx in "${!hit_lines[@]}"; do
      printf '%s %s\n' "${hit_lines[$idx]}" "$idx"
    done | sort -n -k1,1
  )

  : > "$out_file"

  local first_line="${order[0]%% *}"
  if [[ "$first_line" -gt 1 ]]; then
    sed -n "1,$((first_line - 1))p" "$spec_file" >> "$out_file"
  fi

  local n=${#order[@]}
  local k
  for ((k = 0; k < n; k++)); do
    local entry="${order[$k]}"
    local ln="${entry%% *}"
    local idx="${entry##* }"
    local sec_id="${hit_ids[$idx]}"

    # content_start begins at the heading line itself (not ln + 1) so the
    # human-visible `## Heading` / `**Heading**` text is preserved inside the
    # marker pair — markers are invisible HTML comments, so the heading still
    # renders normally in the published issue body.
    local content_start=$ln
    local content_end
    if (( k + 1 < n )); then
      local next_entry="${order[$((k + 1))]}"
      content_end=$(( ${next_entry%% *} - 1 ))
    else
      content_end="$total_lines"
    fi

    {
      printf '<!-- autoducks:design:%s:begin -->\n' "$sec_id"
      if (( content_end >= content_start )); then
        sed -n "${content_start},${content_end}p" "$spec_file"
      fi
      printf '<!-- autoducks:design:%s:end -->\n' "$sec_id"
    } >> "$out_file"
  done

  return 0
}
