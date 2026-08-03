#!/usr/bin/env bash
set -euo pipefail

# ── Pure, provider-agnostic check loop ──────────────────────────────
# Runs the configured post-implementation checks (lint/build/test/etc.) and
# captures the first failure for feedback. This module is intentionally
# read-only w.r.t. ITS/git: it never comments, never pushes, never opens a
# PR — it only runs shell commands and writes the captured output file.
# Callers (pre.sh/post.sh) own all side effects (D7 "who owns git").
#
# Public contract:
#   verify_loop::run_checks              → exit 0 all passed / 1 a check
#                                           failed / 2 setup(infra) error
#   verify_loop::enabled                 → exit 0 if checks are configured
#   verify_loop::feedback_body IT MAX    → stdout (marker-anchored comment)

# Single source of truth for the feedback-comment marker, so pre.sh (read)
# and post.sh (write) never drift apart on the literal string.
export AUTODUCKS_CHECK_FEEDBACK_MARKER="<!-- autoducks:check-feedback -->"

_verify_loop::config_file() {
  # Align with load-config.sh ($AUTODUCKS_ROOT/autoducks.json) so the command
  # list and the `enabled` gate always read the same file — including under the
  # pinned-machinery snapshot, where AUTODUCKS_ROOT is redirected (#989, #952).
  echo "${AUTODUCKS_CONFIG:-${AUTODUCKS_ROOT:-.autoducks}/autoducks.json}"
}

# _verify_loop::commands_json → stdout: JSON array of {name, run}
# Read directly from the config file via jq — never from env, since bash
# env vars can't faithfully hold an array of objects.
_verify_loop::commands_json() {
  local cfg; cfg=$(_verify_loop::config_file)
  [[ -f "$cfg" ]] || { echo "[]"; return 0; }
  jq -c '[(.checks.commands // [])[] | {name: (.name // "check"), run: .run}]' "$cfg" 2>/dev/null || echo "[]"
}

_verify_loop::output_file() {
  echo "${AUTODUCKS_CHECK_OUTPUT_FILE:-/tmp/check-output.md}"
}

# Byte budget for captured output embedded in the feedback comment — keeps a
# runaway log (e.g. an infinite test loop) from blowing up the comment body.
_verify_loop::byte_cap() {
  echo "${AUTODUCKS_CHECKS_OUTPUT_BYTES:-20000}"
}

_verify_loop::repo_root() {
  if [[ -n "${AUTODUCKS_REPO_ROOT:-}" ]]; then
    echo "$AUTODUCKS_REPO_ROOT"
  elif git rev-parse --show-toplevel &>/dev/null; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

# _verify_loop::truncate_output FILE CAP → stdout
# Keeps head+tail, dropping the middle, so a truncated log still shows
# both the first error and the final failure summary.
_verify_loop::truncate_output() {
  local file="$1" cap="$2"
  local size
  size=$(wc -c <"$file" 2>/dev/null | tr -d ' ')
  [[ -z "$size" ]] && size=0
  if (( size <= cap )); then
    cat "$file"
    return 0
  fi
  local marker=$'\n[… truncated …]\n'
  local marker_len
  marker_len=$(printf '%s' "$marker" | wc -c | tr -d ' ')
  local half=$(( (cap - marker_len - 1) / 2 ))
  (( half < 0 )) && half=0
  head -c "$half" "$file"
  printf '%s' "$marker"
  tail -c "$half" "$file"
}

# _verify_loop::write_failure NAME SRC_FILE OUT_FILE
# Writes the failing check's name + (truncated) combined output as a
# markdown snippet, ready to be embedded verbatim by feedback_body.
_verify_loop::write_failure() {
  local name="$1" src_file="$2" out_file="$3"
  local cap; cap=$(_verify_loop::byte_cap)
  {
    printf '**Check failed:** `%s`\n\n```\n' "$name"
    _verify_loop::truncate_output "$src_file" "$cap"
    printf '\n```\n'
  } > "$out_file"
}

# _verify_loop::probe_git_hooks → stdout: JSON array (0 or 1 entries)
# Resolves AUTODUCKS_CHECKS_GIT_HOOKS into a concrete implicit check, or
# emits a ::warning:: and no-ops when nothing is discoverable — a missing
# hook config must never wedge every task.
_verify_loop::probe_git_hooks() {
  [[ "${AUTODUCKS_CHECKS_GIT_HOOKS:-false}" == "true" ]] || { echo "[]"; return 0; }

  local root; root=$(_verify_loop::repo_root)
  local cmd=""
  if [[ -f "$root/.pre-commit-config.yaml" ]] && command -v pre-commit &>/dev/null; then
    cmd="pre-commit run --all-files"
  elif [[ -x "$root/.githooks/pre-commit" ]]; then
    cmd="./.githooks/pre-commit"
  elif [[ -x "$root/.git/hooks/pre-commit" ]]; then
    cmd="./.git/hooks/pre-commit"
  fi

  if [[ -z "$cmd" ]]; then
    echo "::warning::verify-loop: AUTODUCKS_CHECKS_GIT_HOOKS is true but no .pre-commit-config.yaml (+pre-commit) or executable pre-commit hook was found; skipping" >&2
    echo "[]"
    return 0
  fi
  jq -n -c --arg name "git_hooks" --arg run "$cmd" '[{name: $name, run: $run}]'
}

# verify_loop::enabled → exit 0 when checks are configured, else 1
verify_loop::enabled() {
  [[ "${AUTODUCKS_CHECKS_ENABLED:-false}" == "true" ]] || return 1
  local commands; commands=$(_verify_loop::commands_json)
  local n; n=$(echo "$commands" | jq 'length' 2>/dev/null || echo 0)
  (( n > 0 )) && return 0
  [[ "${AUTODUCKS_CHECKS_GIT_HOOKS:-false}" == "true" ]] && return 0
  return 1
}

# verify_loop::run_checks → 0 all passed / 1 a check failed / 2 setup error
verify_loop::run_checks() {
  local out_file; out_file=$(_verify_loop::output_file)
  rm -f "$out_file"
  local root; root=$(_verify_loop::repo_root)

  # Setup runs first; its failure is infra (2), never blamed on the agent.
  if [[ -n "${AUTODUCKS_CHECKS_SETUP:-}" ]]; then
    local tmp status
    tmp=$(mktemp)
    status=0
    ( cd "$root" && bash -c "$AUTODUCKS_CHECKS_SETUP" ) 2>&1 | tee "$tmp" || status=$?
    if [[ "$status" -ne 0 ]]; then
      _verify_loop::write_failure "setup" "$tmp" "$out_file"
      rm -f "$tmp"
      return 2
    fi
    rm -f "$tmp"
  fi

  # git_hooks (if any) run before the configured commands, in order.
  local checks
  checks=$(jq -c -n --argjson a "$(_verify_loop::probe_git_hooks)" \
                     --argjson b "$(_verify_loop::commands_json)" \
                     '$a + $b')

  local count; count=$(echo "$checks" | jq 'length')
  local i
  for (( i = 0; i < count; i++ )); do
    local name run tmp status
    name=$(echo "$checks" | jq -r ".[$i].name")
    run=$(echo "$checks" | jq -r ".[$i].run")
    tmp=$(mktemp)
    status=0
    ( cd "$root" && bash -c "$run" ) 2>&1 | tee "$tmp" || status=$?
    if [[ "$status" -ne 0 ]]; then
      _verify_loop::write_failure "$name" "$tmp" "$out_file"
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
  done

  return 0
}

# verify_loop::feedback_body ITERATION MAX → stdout
verify_loop::feedback_body() {
  local iteration="$1" max="$2"
  local out_file; out_file=$(_verify_loop::output_file)
  local content=""
  [[ -f "$out_file" ]] && content=$(cat "$out_file")
  cat <<EOF
${AUTODUCKS_CHECK_FEEDBACK_MARKER}
**Automated checks failed** (attempt ${iteration}/${max})

${content}
EOF
}
