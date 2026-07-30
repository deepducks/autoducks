#!/usr/bin/env bash
# =============================================================================
# verify-machinery.sh — the single definition of "a valid machinery tree"
# =============================================================================
#
# Extracted so scripts/setup.sh (interactive checklist) and any future
# updater (non-interactive) can never disagree about what a valid machinery
# tree looks like. Sourceable as a library (each verify_machinery::check_*
# function is independently callable) and runnable as a standalone script
# (bash verify-machinery.sh runs all six and exits non-zero on any failure).
#
# CHECKS (run in order by verify_machinery::run_all)
#   1. bash -n every .autoducks/**/*.sh and scripts/*.sh
#   2. jq empty every .autoducks/**/*.json; YAML-parse every
#      .github/workflows/autoducks-*.yml (best-effort: skipped if PyYAML is
#      unavailable)
#   3. Runtime sync: every .autoducks/runtimes/github-actions/autoducks-*.yml
#      matches its .github/workflows/ mirror byte-for-byte, and no orphan
#      mirror (a .github/workflows/autoducks-*.yml with no runtime template)
#      remains
#   4. update-triggers.sh idempotence: regenerate the guards from the live
#      config into a scratch copy of the tree; the result must be
#      byte-identical to what's committed
#   5. Plugin compilation sync: recompute apply-plugins.sh's output into a
#      scratch dir (AUTODUCKS_APPLY_PLUGINS_OUTPUT_ROOT) and diff it against
#      the committed aggregators/compiled/* artifacts. The compiler itself
#      performs manifest/config/version-gate/merge-conflict validation and
#      dies with an actionable message on any of those — this check surfaces
#      that failure verbatim.
#   6. Tree integrity: .autoducks is non-empty and .autoducks/autoducks.json
#      still parses with the consumer's providers intact (a paranoia check
#      against a truncated tarball).
#
# Each check function prints zero or more machine-readable "TOKEN detail"
# lines to stdout (empty output on success) and returns 0 (pass) / 1 (fail).
# Callers that need the original human-facing wording (scripts/setup.sh
# checks 9 and 12) parse these tokens themselves rather than re-deriving the
# pass/fail logic.
#
# Read-only w.r.t. the real tree: every check that regenerates or compiles
# something does so into a throwaway scratch dir it creates and removes
# itself. No network calls.
#
# USAGE
#   source .autoducks/core/robustness/verify-machinery.sh   # as a library
#   bash .autoducks/core/robustness/verify-machinery.sh      # as a script
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly would error on second source otherwise)
if [[ -n "${_VERIFY_MACHINERY_SH_LOADED:-}" ]]; then
  return 0
fi
readonly _VERIFY_MACHINERY_SH_LOADED=1

if ! command -v jq &>/dev/null; then
  echo "verify-machinery: jq is required but not installed" >&2
  return 1 2>/dev/null
  exit 1
fi

# ── Locate .autoducks root / repo root (mirrors apply-plugins.sh's walk-up,
# so this module resolves correctly whether sourced from scripts/setup.sh,
# run standalone, or copied into a scratch tree for testing) ───────────────
_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_vm_dir="$_VM_SCRIPT_DIR"
_vm_depth=0
AUTODUCKS_ROOT=""
while [[ "$_vm_depth" -lt 10 ]]; do
  if [[ -f "$_vm_dir/autoducks.json" ]]; then
    AUTODUCKS_ROOT="$_vm_dir"
    break
  fi
  _vm_dir="$(dirname "$_vm_dir")"
  (( _vm_depth++ )) || true
done
if [[ -z "$AUTODUCKS_ROOT" ]]; then
  echo "verify-machinery: could not find autoducks.json (walked up from $_VM_SCRIPT_DIR)" >&2
  return 1 2>/dev/null
  exit 1
fi
REPO_ROOT="$(dirname "$AUTODUCKS_ROOT")"
RUNTIME_DIR="$REPO_ROOT/.autoducks/runtimes/github-actions"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

# ── Check 1: bash -n every .autoducks/**/*.sh and scripts/*.sh ─────────────
verify_machinery::check_syntax() {
  local ok=0 f
  while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { echo "SYNTAX ${f#"$REPO_ROOT"/}"; ok=1; }
  done < <(find "$AUTODUCKS_ROOT" -type f -name '*.sh' -print0)
  if [[ -d "$REPO_ROOT/scripts" ]]; then
    while IFS= read -r -d '' f; do
      bash -n "$f" 2>/dev/null || { echo "SYNTAX ${f#"$REPO_ROOT"/}"; ok=1; }
    done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print0)
  fi
  return "$ok"
}

# ── Check 2: JSON/YAML parseability ─────────────────────────────────────────
verify_machinery::check_json_yaml() {
  local ok=0 f
  while IFS= read -r -d '' f; do
    jq empty "$f" 2>/dev/null || { echo "JSON ${f#"$REPO_ROOT"/}"; ok=1; }
  done < <(find "$AUTODUCKS_ROOT" -type f -name '*.json' -print0)

  if command -v python3 &>/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    if [[ -d "$WORKFLOW_DIR" ]]; then
      while IFS= read -r -d '' f; do
        python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null \
          || { echo "YAML ${f#"$REPO_ROOT"/}"; ok=1; }
      done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f -name 'autoducks-*.yml' -print0)
    fi
  fi
  return "$ok"
}

# ── Check 3: runtime↔mirror sync, both directions ───────────────────────────
# MISSING/DIFF: a runtime template with no (or a stale) .github/workflows/
# mirror — setup's original check 9. ORPHAN: a .github/workflows/autoducks-*.yml
# mirror with no runtime template — the direction setup never tested.
#
# Upstream-only workflows are the one legitimate exception to ORPHAN. They live
# in .github/workflows/ of this repository alone and must never reach a consumer,
# so they are deliberately absent from RUNTIME_DIR — which install.sh copies
# wholesale (`cp .autoducks/runtimes/github-actions/autoducks-*.yml`). Without
# this list, adding such a workflow makes the check fail on a clean tree, since
# the `autoducks-` prefix is what ORPHAN keys on. (ci-unit-tests.yml escapes it
# only by not carrying the prefix.)
_VERIFY_UPSTREAM_ONLY_WORKFLOWS=(
  "autoducks-release.yml"   # publishes this repo's own releases; consumers never release autoducks
)

verify_machinery::_is_upstream_only() {
  local bn="$1" w
  for w in "${_VERIFY_UPSTREAM_ONLY_WORKFLOWS[@]}"; do
    [[ "$bn" == "$w" ]] && return 0
  done
  return 1
}

verify_machinery::check_runtime_sync() {
  local ok=0 runtime target bn
  if [[ -d "$RUNTIME_DIR" ]]; then
    for runtime in "$RUNTIME_DIR"/autoducks-*.yml; do
      [[ -f "$runtime" ]] || continue
      bn="$(basename "$runtime")"
      target="$WORKFLOW_DIR/$bn"
      if [[ ! -f "$target" ]]; then
        echo "MISSING .github/workflows/$bn .autoducks/runtimes/github-actions/$bn"
        ok=1
      elif ! diff -q "$runtime" "$target" &>/dev/null; then
        echo "DIFF .github/workflows/$bn .autoducks/runtimes/github-actions/$bn"
        ok=1
      fi
    done
  fi
  if [[ -d "$WORKFLOW_DIR" ]]; then
    for target in "$WORKFLOW_DIR"/autoducks-*.yml; do
      [[ -f "$target" ]] || continue
      bn="$(basename "$target")"
      verify_machinery::_is_upstream_only "$bn" && continue
      runtime="$RUNTIME_DIR/$bn"
      if [[ ! -f "$runtime" ]]; then
        echo "ORPHAN .github/workflows/$bn .autoducks/runtimes/github-actions/$bn"
        ok=1
      fi
    done
  fi
  return "$ok"
}

# ── Check 4: update-triggers.sh idempotence ─────────────────────────────────
# Regenerates the guards from the live config into a scratch copy of the
# tree and diffs the result against what was there before the run. Never
# touches the real .github/workflows or .autoducks/runtimes — only the
# scratch copy, which is removed before returning.
verify_machinery::check_idempotence() {
  local updater="$REPO_ROOT/scripts/update-triggers.sh"
  local gen="$AUTODUCKS_ROOT/core/config/generate-trigger-conditions.sh"
  if [[ ! -f "$updater" || ! -f "$gen" || ! -d "$RUNTIME_DIR" || ! -d "$WORKFLOW_DIR" ]]; then
    echo "IDEMPOTENCE_UNAVAILABLE"
    return 1
  fi

  local scratch before ok=0
  scratch="$(mktemp -d)"
  before="$(mktemp -d)"
  mkdir -p "$scratch/.autoducks/core/config" "$scratch/.autoducks/runtimes" \
           "$scratch/.github" "$scratch/scripts"
  cp "$AUTODUCKS_ROOT/autoducks.json" "$scratch/.autoducks/"
  cp "$gen" "$scratch/.autoducks/core/config/"
  cp -R "$RUNTIME_DIR" "$scratch/.autoducks/runtimes/"
  cp -R "$WORKFLOW_DIR" "$scratch/.github/"
  cp "$updater" "$scratch/scripts/"
  cp -R "$scratch/.github/workflows" "$before/workflows"
  cp -R "$scratch/.autoducks/runtimes/github-actions" "$before/runtimes"

  if ! ( cd "$scratch" && bash scripts/update-triggers.sh ) >/dev/null 2>&1; then
    echo "GENERATOR_FAILED"
    rm -rf "$scratch" "$before"
    return 1
  fi

  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#"$scratch"/.github/workflows/}"
    diff -q "$f" "$before/workflows/$rel" &>/dev/null \
      || { echo "DRIFT .github/workflows/$rel"; ok=1; }
  done < <(find "$scratch/.github/workflows" -type f -print0)
  while IFS= read -r -d '' f; do
    rel="${f#"$scratch"/.autoducks/runtimes/github-actions/}"
    diff -q "$f" "$before/runtimes/$rel" &>/dev/null \
      || { echo "DRIFT .autoducks/runtimes/github-actions/$rel"; ok=1; }
  done < <(find "$scratch/.autoducks/runtimes/github-actions" -type f -print0)

  rm -rf "$scratch" "$before"
  return "$ok"
}

# ── Check 5: plugin compilation sync ────────────────────────────────────────
# Moved verbatim from setup.sh's former check 12 (dry-run compile, artifact
# diff, orphan-artifact sweep). requiresSecrets manual-checklist surfacing is
# NOT included here — that stays in setup.sh as a setup-only concern.
verify_machinery::check_plugin_sync() {
  local compiler="$AUTODUCKS_ROOT/core/config/apply-plugins.sh"
  if [[ ! -f "$compiler" ]]; then
    echo "COMPILER_MISSING $compiler"
    return 1
  fi

  local dryrun_root compile_log ok=0
  dryrun_root="$(mktemp -d)"
  compile_log="$(mktemp)"

  if AUTODUCKS_APPLY_PLUGINS_OUTPUT_ROOT="$dryrun_root" bash "$compiler" >"$compile_log" 2>&1; then
    local f rel agg
    while IFS= read -r -d '' f; do
      rel="${f#"$dryrun_root"/}"
      if [[ ! -f "$REPO_ROOT/$rel" ]]; then
        echo "MISSING $rel"
        ok=1
      elif ! diff -q "$f" "$REPO_ROOT/$rel" &>/dev/null; then
        echo "STALE $rel"
        ok=1
      fi
    done < <(find "$dryrun_root" -type f -print0)

    for agg in "$REPO_ROOT"/.github/actions/autoducks/*/action.yml; do
      [[ -f "$agg" ]] || continue
      head -n1 "$agg" | grep -qF "GENERATED BY autoducks apply-plugins.sh" || continue
      rel="${agg#"$REPO_ROOT"/}"
      if [[ ! -f "$dryrun_root/$rel" ]]; then
        echo "ORPHAN $rel"
        ok=1
      fi
    done
    for f in "$REPO_ROOT"/.autoducks/providers/llm/claude/compiled/*.settings.json \
             "$REPO_ROOT"/.autoducks/providers/llm/claude/compiled/*.allowed-tools; do
      [[ -f "$f" ]] || continue
      rel="${f#"$REPO_ROOT"/}"
      if [[ ! -f "$dryrun_root/$rel" ]]; then
        echo "ORPHAN $rel"
        ok=1
      fi
    done
  else
    echo "COMPILER_FAILED $(tail -n 3 "$compile_log" | tr '\n' ' ')"
    ok=1
  fi

  rm -rf "$dryrun_root"
  rm -f "$compile_log"
  return "$ok"
}

# ── Check 6: tree integrity ──────────────────────────────────────────────────
# A paranoia check against a truncated tarball: the tree must be non-empty
# and .autoducks/autoducks.json must still parse with a `providers` block
# whose its/git/llm entries are non-empty strings.
verify_machinery::check_tree_integrity() {
  local count
  count="$(find "$AUTODUCKS_ROOT" -type f | wc -l | tr -d ' ')"
  if [[ "${count:-0}" -lt 1 ]]; then
    echo "EMPTY_TREE"
    return 1
  fi

  local cfg="$AUTODUCKS_ROOT/autoducks.json"
  if [[ ! -f "$cfg" ]] || ! jq empty "$cfg" 2>/dev/null; then
    echo "CONFIG_UNPARSEABLE"
    return 1
  fi

  local key
  for key in its git llm; do
    jq -e --arg k "$key" '(.providers // {})[$k] // "" | length > 0' "$cfg" >/dev/null 2>&1 \
      || { echo "PROVIDERS_INCOMPLETE $key"; return 1; }
  done
  return 0
}

# ── Runner: all six checks, one line each, stable identifier + pass/fail ───
verify_machinery::run_all() {
  local -a checks=(
    "1:bash-syntax:verify_machinery::check_syntax"
    "2:json-yaml:verify_machinery::check_json_yaml"
    "3:runtime-sync:verify_machinery::check_runtime_sync"
    "4:update-triggers-idempotence:verify_machinery::check_idempotence"
    "5:plugin-compilation-sync:verify_machinery::check_plugin_sync"
    "6:tree-integrity:verify_machinery::check_tree_integrity"
  )
  local total=0 failed=0 entry num id fn output status line

  for entry in "${checks[@]}"; do
    IFS=':' read -r num id fn <<<"$entry"
    total=$((total + 1))
    if output="$("$fn")"; then
      status=0
    else
      status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
      echo "[$num/6] $id: PASS"
    else
      failed=$((failed + 1))
      echo "[$num/6] $id: FAIL"
      if [[ -n "$output" ]]; then
        while IFS= read -r line; do
          [[ -n "$line" ]] && echo "    $line"
        done <<<"$output"
      fi
    fi
  done

  echo ""
  echo "verify-machinery: $((total - failed))/$total checks passed"
  [[ "$failed" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if verify_machinery::run_all; then
    exit 0
  else
    exit 1
  fi
fi
