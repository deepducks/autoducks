#!/usr/bin/env bash
# Update agent: pure-orchestration updater. No LLM step runs, no LLM
# credential is ever read or forwarded.
#
# Steps: resolve target (0) → decide (1) → pre-flight (2) → apply on a
# branch (3) → migrate (4) → detect drift (5) → verify (6) → deliver (7) →
# report (8).
#
# Env (from .github/workflows/autoducks-update.yml "Run update" step):
#   REPO, RUN_ID, REF (dispatch override, optional), MODE (dispatch
#   override, optional), DRY_RUN, COMMENTER, GH_TOKEN, GITHUB_EVENT_NAME,
#   GITHUB_STEP_SUMMARY, AUTODUCKS_PAT. ISSUE_NUM/COMMENT_ID are wired by the
#   workflow for comment-triggered runs and empty otherwise, so an empty
#   ISSUE_NUM still means "scheduled run" — the reads stay defensive, they are
#   simply no longer dead on the `/update` path.
set -euo pipefail
export AUTODUCKS_AGENT="update"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/config/semver.sh"
source "$AUTODUCKS_ROOT/core/config/changelog.sh"
source "$AUTODUCKS_ROOT/core/config/consumer-owned.sh"

REPO="${REPO:?REPO env var required}"
RUN_ID="${RUN_ID:-0}"
COMMENTER="${COMMENTER:-}"
ISSUE_NUM="${ISSUE_NUM:-}"
COMMENT_ID="${COMMENT_ID:-}"
DRY_RUN="${DRY_RUN:-false}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
TRIGGER="${GITHUB_EVENT_NAME:-schedule}"

SRC="$AUTODUCKS_UPDATE_SOURCE_REPO"
CHANNEL="$AUTODUCKS_UPDATE_CHANNEL"
PIN="$AUTODUCKS_UPDATE_PIN"
MODE="${MODE:-$AUTODUCKS_UPDATE_MODE}"
[[ "$MODE" =~ ^(pr|commit|off)$ ]] || MODE="$AUTODUCKS_UPDATE_MODE"

UPDATE_FAILURE_MARKER="<!-- autoducks:update-failure -->"
# Identifies the "a newer version is available" note already posted on an open
# update PR, per target SHA, so a weekly cycle does not repeat itself.
UPDATE_AVAILABLE_MARKER="<!-- autoducks:update-available:"

update::_strip_v() { printf '%s' "${1#v}"; }

# ── Step 0: resolve target ──────────────────────────────────────────────
update::default_branch() {
  gh api "repos/$SRC" --jq '.default_branch' 2>/dev/null || true
}

# update::highest_stable_tag → highest tag matching ^v[0-9]+\.[0-9]+\.[0-9]+$,
# sorted locally via semver::compare (not releases/latest, whose ordering is
# publication-time and could pick a backported patch over a newer minor).
update::highest_stable_tag() {
  local tags best="" t
  tags="$(gh api "repos/$SRC/tags" --paginate --jq '.[].name' 2>/dev/null || true)"
  while IFS= read -r t; do
    [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z "$best" ]] || [[ "$(semver::compare "$(update::_strip_v "$t")" "$(update::_strip_v "$best")")" == "1" ]]; then
      best="$t"
    fi
  done <<<"$tags"
  printf '%s' "$best"
}

# update::resolve_target PIN CHANNEL → prints REF on stdout. On the
# no-tags bootstrap path, also emits a loud ::warning:: to stderr.
update::resolve_target() {
  local pin="$1" channel="$2"
  if [[ -n "$pin" ]]; then
    printf '%s' "$pin"
    return 0
  fi
  if [[ "$channel" == "edge" ]]; then
    update::default_branch
    return 0
  fi
  local tag
  tag="$(update::highest_stable_tag)"
  if [[ -z "$tag" ]]; then
    echo "::warning::update: upstream ($SRC) has cut no releases yet — tracking edge during the bootstrap period." >&2
    update::default_branch
    return 0
  fi
  printf '%s' "$tag"
}

# ── Step 1: decide ───────────────────────────────────────────────────────
update::resolve_sha() {
  local ref="$1"
  gh api "repos/$SRC/commits/$ref" --jq '.sha' 2>/dev/null || true
}

update::fetch_version_at() {
  local sha="$1"
  curl -fsSL "https://raw.githubusercontent.com/$SRC/$sha/.autoducks/VERSION" 2>/dev/null | tr -d '[:space:]' || true
}

update::read_installed_field() {
  local field="$1" file="${2:-.autoducks/.installed.json}"
  [[ -f "$file" ]] || { printf ''; return 0; }
  jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null || true
}

# update::decide INSTALLED_SHA INSTALLED_VERSION TARGET_SHA TARGET_VERSION PIN
# → "up-to-date" | "downgrade" | "proceed"
update::decide() {
  local installed_sha="$1" installed_version="$2" target_sha="$3" target_version="$4" pin="$5"
  # The lockfile may hold an abbreviated SHA: without `gh`, install.sh derives it
  # from the tarball's top-level directory, which GitHub names
  # owner-repo-<abbrev>. resolve_sha always returns the full 40 characters, so
  # exact equality never matched and the first scheduled run on a curl-installed
  # repo opened an update PR whose only change was .installed.json itself.
  # Compare on the shorter length, which is unambiguous for any git object id.
  if [[ -n "$installed_sha" && -n "$target_sha" ]]; then
    local _n="${#installed_sha}"
    [[ "${#target_sha}" -lt "$_n" ]] && _n="${#target_sha}"
    if [[ "$_n" -ge 7 && "${installed_sha:0:$_n}" == "${target_sha:0:$_n}" ]]; then
      printf 'up-to-date'
      return 0
    fi
  fi
  if [[ -n "$installed_sha" && "$installed_sha" == "$target_sha" ]]; then
    printf 'up-to-date'
    return 0
  fi
  if [[ -n "$installed_version" && -n "$target_version" ]]; then
    if [[ "$(semver::bump_kind "$installed_version" "$target_version")" == "downgrade" && -z "$pin" ]]; then
      printf 'downgrade'
      return 0
    fi
  fi
  printf 'proceed'
}

# ── Step 2: pre-flight ───────────────────────────────────────────────────
# update::preflight MODE ENABLED TRIGGER → prints "STATUS<TAB>REASON".
# STATUS ∈ ok | mode-off | existing-pr | pipeline-conflict | no-identity.
# existing-pr / pipeline-conflict are soft stops (not failures); mode-off is
# a quiet no-op; no-identity is a hard failure.
update::preflight() {
  local mode="$1" enabled="$2" trigger="$3"

  if [[ "$mode" == "off" ]]; then
    printf 'mode-off\tupdate.mode is "off" — updates are disabled for this repo.'
    return 0
  fi
  if [[ "$enabled" == "false" && "$trigger" == "schedule" ]]; then
    printf 'mode-off\tupdate.enabled is false and this run was triggered by the schedule (comment `%s` to run it manually).' "$(autoducks_command_for update)"
    return 0
  fi

  local open_prs existing
  open_prs="$(git::list_open_prs "$AUTODUCKS_BASE_BRANCH" 2>/dev/null || echo '[]')"
  existing="$(printf '%s' "$open_prs" | jq -r '[.[] | select(.headRefName | startswith("autoducks/update-"))] | .[0].number // empty')"
  if [[ -n "$existing" ]]; then
    printf 'existing-pr\t%s' "$existing"
    return 0
  fi

  local pipeline_prs pr_num diff conflict=""
  pipeline_prs="$(git::list_open_prs "$AUTODUCKS_INTEGRATION_BRANCH" 2>/dev/null || echo '[]')"
  while IFS= read -r pr_num; do
    [[ -z "$pr_num" ]] && continue
    diff="$(git::get_pr_diff "$pr_num" 2>/dev/null || true)"
    if grep -qE '^\+\+\+ b/(\.autoducks/|\.github/workflows/autoducks-)' <<<"$diff"; then
      conflict="$pr_num"
      break
    fi
  done < <(printf '%s' "$pipeline_prs" | jq -r '.[].number')
  if [[ -n "$conflict" ]]; then
    printf 'pipeline-conflict\tPR #%s targeting `%s` touches `.autoducks/` or `.github/workflows/autoducks-*` — skipping this cycle to avoid racing an in-flight machinery change; will retry next cycle.' "$conflict" "$AUTODUCKS_INTEGRATION_BRANCH"
    return 0
  fi

  if [[ -z "${AUTODUCKS_APP_TOKEN:-}" && -z "${AUTODUCKS_PAT:-}" ]]; then
    printf 'no-identity\tNo identity capable of pushing workflow files is configured. Add the `AUTODUCKS_PAT` repository secret (a PAT with the `workflow` scope), or set the `AUTODUCKS_APP` repository variable to enable the autoducks GitHub App broker.'
    return 0
  fi

  printf 'ok\t'
}

# ── Step 3: apply, on a branch ───────────────────────────────────────────
update::branch_name() {
  local version="$1" sha="$2"
  printf 'autoducks/update-%s' "${version:-${sha:0:7}}"
}

update::snapshot_pre_update() {
  local dest="$1"
  mkdir -p "$dest"
  [[ -d .autoducks ]] && cp -a .autoducks "$dest/.autoducks"
}

# update::discard_branch BRANCH — remove the remote ref this agent created.
# Called on every path that gives up after apply_branch: the branch exists on
# the remote from that moment on, but the run only earns it by clearing
# migrations, drift and verify-machinery.
update::discard_branch() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || return 0
  git::delete_branch "$branch" 2>/dev/null || true
  echo "::notice::update: discarded $branch — the cycle did not reach a PR." >&2
}

update::apply_branch() {
  local base="$1" branch="$2" target_sha="$3" channel="$4"

  # create_branch POSTs a remote ref, and GitHub answers 422 "Reference already
  # exists" for one that is already there — non-zero under `set -euo pipefail`,
  # with no trap, so the run would die before any reporting function ran. A
  # branch left behind by an earlier aborted cycle (or by a maintainer closing
  # the update PR without merging, which never deletes the head) therefore
  # wedged every later run, silently and permanently.
  #
  # The autoducks/update-* namespace belongs to this agent: nothing else writes
  # it, and a stale one has no value because the target SHA is recomputed each
  # cycle. Clear it first, then create.
  # Through the frozen git:: interface, not `gh` directly: security-guidelines
  # rule 4 confines host calls to providers/, and the design's carve-out for
  # direct calls covers source_repo only. These target the consumer's own repo,
  # so on a non-GitHub provider the inlined version would hard-fail and leave
  # the stale ref that wedges the next cycle — the exact bug this block fixes.
  if git::branch_exists "$branch" 2>/dev/null; then
    echo "::notice::update: $branch already exists from an earlier cycle — replacing it." >&2
    git::delete_branch "$branch" 2>/dev/null || true
  fi

  git::create_branch "$base" "$branch"
  git fetch origin "$branch" --quiet
  git checkout -B "$branch" "origin/$branch" --quiet

  local installer="$RUNNER_TEMP/install.sh"
  curl -fsSL "https://raw.githubusercontent.com/$SRC/$target_sha/scripts/install.sh" -o "$installer"
  bash "$installer" --no-setup --ref "$target_sha" --source-repo "$SRC" --channel "$channel" \
    --lock-note "autoducks-update.yml#$RUN_ID"
}

# ── Step 4: migrations ───────────────────────────────────────────────────
# update::pending_migrations INSTALLED_VERSION TARGET_VERSION MIGRATIONS_DIR
# → one version per line, ascending semver order, installed < v <= target.
update::pending_migrations() {
  local installed_version="$1" target_version="$2" dir="$3"
  [[ -d "$dir" ]] || return 0
  local -a versions=()
  local d v
  for d in "$dir"/*/; do
    [[ -f "${d}migrate.sh" ]] || continue
    v="$(basename "$d")"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -n "$installed_version" ]] && [[ "$(semver::compare "$installed_version" "$v")" != "-1" ]]; then
      continue
    fi
    if [[ -n "$target_version" ]]; then
      local cmp; cmp="$(semver::compare "$v" "$target_version")"
      [[ "$cmp" == "-1" || "$cmp" == "0" ]] || continue
    fi
    versions+=("$v")
  done
  [[ "${#versions[@]}" -eq 0 ]] && return 0

  local -a sorted=()
  for v in "${versions[@]}"; do
    local i inserted=0
    for ((i = 0; i < ${#sorted[@]}; i++)); do
      if [[ "$(semver::compare "$v" "${sorted[$i]}")" == "-1" ]]; then
        sorted=("${sorted[@]:0:$i}" "$v" "${sorted[@]:$i}")
        inserted=1
        break
      fi
    done
    [[ "$inserted" -eq 0 ]] && sorted+=("$v")
  done
  printf '%s\n' "${sorted[@]}"
}

# update::run_migrations INSTALLED_VERSION TARGET_VERSION MIGRATIONS_DIR REPORT_FILE
# Runs each pending migration with AUTODUCKS_ROOT set to the migrations
# directory's parent. Returns 1 on the first non-zero exit (before any
# branch is pushed); the failing version is appended to the report and
# named on stderr.
update::run_migrations() {
  local installed_version="$1" target_version="$2" dir="$3" report="$4"
  local root; root="$(cd "$dir/.." && pwd)"
  local v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if ! AUTODUCKS_ROOT="$root" AUTODUCKS_MIGRATION_REPORT="$report" bash "$dir/$v/migrate.sh"; then
      echo "::error::update: migration $v failed" >&2
      printf '\n**Migration %s failed — aborting before any PR was opened.**\n' "$v" >>"$report"
      return 1
    fi
  done < <(update::pending_migrations "$installed_version" "$target_version" "$dir")
  return 0
}

# ── Step 5: drift detection ──────────────────────────────────────────────
_UPDATE_GENERATED_PATHS=(
  "providers/llm/claude/compiled"
  ".installed.json"
)

update::_drift_excluded() {
  local rel="$1" p
  for p in "${AUTODUCKS_CONSUMER_OWNED[@]}" "${_UPDATE_GENERATED_PATHS[@]}"; do
    [[ "$rel" == "$p" || "$rel" == "$p"/* ]] && return 0
  done
  return 1
}

# update::drift_diff PRE_AUTODUCKS_DIR SNAPSHOT_AUTODUCKS_DIR → one drifted
# path per line, relative to `.autoducks/`, excluding AUTODUCKS_CONSUMER_OWNED
# and generated paths.
update::drift_diff() {
  local pre="$1" snapshot="$2"
  [[ -d "$pre" ]] || return 0
  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#"$pre"/}"
    update::_drift_excluded "$rel" && continue
    if [[ ! -f "$snapshot/$rel" ]] || ! cmp -s "$f" "$snapshot/$rel"; then
      printf '%s\n' "$rel"
    fi
  done < <(find "$pre" -type f -print0 | sort -z)
}

# update::detect_drift PREVIOUS_SHA PRE_UPDATE_SNAPSHOT_DIR → one drifted
# path per line. Downloads the previously-installed SHA's tarball, runs the
# consumer's update-triggers.sh/apply-plugins.sh against it so baked
# if:/schedule: regions and compiled plugin artifacts are comparable, then
# diffs it against the working tree's pre-update state.
# Exit codes carry what stdout cannot: 0 = comparison ran (stdout is the drifted
# paths, empty meaning none), 2 = could not be determined.
#
# The distinction is a safety gate, not bookkeeping. The fetch below used to be
# anonymous and swallowed with `|| true`, so a rate limit — the likely outcome of
# an unauthenticated API call on a busy runner — produced an empty tarball, no
# extracted tree, no call to drift_diff, and therefore no output: identical to
# "the consumer changed nothing". `on_drift: abort` then never fired and
# auto_merge_eligible saw has_drift=0, so an update could merge itself over a
# consumer's local machinery edits without anyone seeing a word about it.
update::detect_drift() {
  local previous_sha="$1" pre_update_dir="$2"
  [[ -n "$previous_sha" ]] || return 0
  local scratch; scratch="$(mktemp -d)"

  # Authenticate: this is the same API the rest of the agent uses with a token,
  # and the one call that was left anonymous is the one whose failure is silent.
  local _auth=()
  [[ -n "${GH_TOKEN:-}" ]] && _auth=(-H "Authorization: Bearer $GH_TOKEN")
  if ! curl -fsSL "${_auth[@]}" \
       "https://api.github.com/repos/$SRC/tarball/$previous_sha" -o "$scratch/prev.tar.gz" 2>/dev/null; then
    echo "::warning::update: could not fetch $SRC@${previous_sha:0:7} to compare against — local machinery drift is UNKNOWN for this run." >&2
    rm -rf "$scratch"
    return 2
  fi
  if ! tar tzf "$scratch/prev.tar.gz" >/dev/null 2>&1; then
    echo "::warning::update: the previous-machinery tarball for ${previous_sha:0:7} is not readable — local machinery drift is UNKNOWN for this run." >&2
    rm -rf "$scratch"
    return 2
  fi

  if [[ -s "$scratch/prev.tar.gz" ]]; then
    mkdir -p "$scratch/prev"
    tar xzf "$scratch/prev.tar.gz" -C "$scratch/prev" --strip-components=1 2>/dev/null || true

    # Regenerate with the CONSUMER's config, not upstream's. update-triggers.sh
    # bakes if:/schedule: regions and apply-plugins.sh compiles plugin artifacts
    # from autoducks.json — so running them against the tarball's own config
    # produces a reference tree describing upstream's settings, and every
    # consumer whose config differs (a different cron, another trigger phrase,
    # any enabled plugin) sees the whole regenerated surface reported as local
    # drift. Under `on_drift: abort` that is a hard block on updating a repo
    # whose only sin is being configured.
    #
    # The pre-update snapshot is the consumer's own tree, so its autoducks.json
    # is the right input. Copy it in before regenerating; if it is missing, skip
    # regeneration entirely rather than fall back to upstream's — a smaller,
    # honest diff beats a confidently wrong one.
    if [[ -f "$pre_update_dir/.autoducks/autoducks.json" && -d "$scratch/prev/.autoducks" ]]; then
      cp "$pre_update_dir/.autoducks/autoducks.json" "$scratch/prev/.autoducks/autoducks.json"
      ( cd "$scratch/prev" 2>/dev/null && [[ -f scripts/update-triggers.sh ]] && bash scripts/update-triggers.sh >/dev/null 2>&1 || true )
      ( cd "$scratch/prev" 2>/dev/null && [[ -f .autoducks/core/config/apply-plugins.sh ]] && bash .autoducks/core/config/apply-plugins.sh >/dev/null 2>&1 || true )
    fi
  fi
  if [[ ! -d "$scratch/prev/.autoducks" ]]; then
    echo "::warning::update: the previous-machinery tarball carried no .autoducks/ — local machinery drift is UNKNOWN for this run." >&2
    rm -rf "$scratch"
    return 2
  fi
  update::drift_diff "$pre_update_dir/.autoducks" "$scratch/prev/.autoducks"
  rm -rf "$scratch"
}

# update::drift_section PRE_UPDATE_DIR PATHS_FILE → PR-body markdown listing
# each drifted path with its pre-update blob SHA.
update::drift_section() {
  local pre_update_dir="$1" paths_file="$2"
  local rel sha
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    sha="$(git hash-object "$pre_update_dir/.autoducks/$rel" 2>/dev/null || echo "unknown")"
    printf -- '- `%s` (pre-update blob `%s`)\n' "$rel" "$sha"
  done <"$paths_file"
}

# ── Step 6: verify before proposing ──────────────────────────────────────
update::run_verify() {
  local output_file="$1"
  bash ".autoducks/core/robustness/verify-machinery.sh" >"$output_file" 2>&1
}

# ── Step 7: deliver ──────────────────────────────────────────────────────
# update::pr_body FROM_VERSION TO_VERSION CHANNEL PIN FROM_SHA TO_SHA \
#   MIGRATION_REPORT_FILE DRIFT_SECTION_FILE VERIFY_OUTPUT_FILE PREVIOUS_SHA
update::pr_body() {
  local from_version="$1" to_version="$2" channel="$3" pin="$4" from_sha="$5" to_sha="$6" \
    migration_report_file="$7" drift_section_file="$8" verify_output_file="$9" previous_sha="${10}"

  local body=""
  body+="## Version"$'\n\n'
  body+="\`${from_version:-unversioned}\` → \`${to_version}\`  ·  channel: \`${channel}\`"
  [[ -n "$pin" ]] && body+="  ·  pin: \`${pin}\`"
  body+=$'\n\n'"From \`${from_sha:-unknown}\` to \`${to_sha}\`."$'\n\n'

  # changelog::_file resolves against $AUTODUCKS_ROOT, and this agent runs from
  # AUTODUCKS_PINNED_ROOT — the snapshot taken *before* the update. That copy
  # predates every version being reported on, so changelog::range came back
  # empty and changelog::has_breaking always returned false. The consequences
  # ran past a missing section: with has_breaking always false, the ⚠️ Breaking
  # changes block never rendered and auto_merge_eligible saw a clean bill, so a
  # release whose changelog declares breaking changes could merge to the
  # default branch unattended.
  #
  # The applied tree is the checkout, and apply_branch has already written the
  # new machinery into it by the time the body is built, so read from there.
  local _applied_root="${GITHUB_WORKSPACE:-$PWD}/.autoducks"
  [[ -f "$_applied_root/CHANGELOG.md" ]] || _applied_root="${AUTODUCKS_ROOT:-.autoducks}"

  local changelog="" _breaking=1
  if [[ -n "$from_version" && -n "$to_version" ]]; then
    changelog="$(AUTODUCKS_ROOT="$_applied_root" changelog::range "$from_version" "$to_version" 2>/dev/null || true)"
    AUTODUCKS_ROOT="$_applied_root" changelog::has_breaking "$from_version" "$to_version" 2>/dev/null && _breaking=0
  fi
  body+="## Changelog"$'\n\n'
  body+="${changelog:-_No changelog entries found._}"$'\n\n'

  if [[ "$_breaking" -eq 0 ]]; then
    body+="## ⚠️ Breaking changes"$'\n\n'
    body+="This update includes breaking changes — review the changelog above before merging."$'\n\n'
  fi

  body+="## Migrations applied"$'\n\n'
  if [[ -s "$migration_report_file" ]]; then
    body+="$(cat "$migration_report_file")"$'\n\n'
  else
    body+="_No migrations were required._"$'\n\n'
  fi

  if [[ -s "$drift_section_file" ]]; then
    body+="## ⚠️ Local machinery changes overwritten"$'\n\n'
    body+="$(cat "$drift_section_file")"$'\n\n'
  fi

  body+="## Verification"$'\n\n'
  if [[ -s "$verify_output_file" ]]; then
    body+='```'$'\n'"$(cat "$verify_output_file")"$'\n''```'$'\n\n'
  else
    body+="_No verification output captured._"$'\n\n'
  fi

  body+="## Rollback"$'\n\n'
  if [[ -n "$previous_sha" ]]; then
    body+="Set \`update.pin\` to \`${previous_sha}\` in \`autoducks.json\` and re-run \`$(autoducks_command_for update)\`, or revert this PR."
  else
    body+="Revert this PR."
  fi
  printf '%s' "$body"
}

# update::auto_merge_eligible AUTO_MERGE_CFG BUMP_KIND HAS_BREAKING(0/1) HAS_DRIFT(0/1)
#
# Took a CHECKS_OK argument until it was removed: verify-machinery failure
# discards the branch and exits, so the value was provably 1 at the only call
# site and the gate read as a live safety check that could never fire. The real
# gate is GitHub's — see the call site.
update::auto_merge_eligible() {
  local cfg="$1" bump="$2" has_breaking="$3" has_drift="$4"
  [[ "$cfg" == "off" ]] && return 1
  [[ "$has_breaking" == "1" ]] && return 1
  [[ "$has_drift" == "1" ]] && return 1
  case "$cfg" in
    patch) [[ "$bump" == "patch" ]] ;;
    minor) [[ "$bump" == "patch" || "$bump" == "minor" ]] ;;
    *) return 1 ;;
  esac
}

update::deliver_commit() {
  local branch="$1" base="$2" version="$3"
  git::configure_identity
  git add -A
  git commit -m "chore(autoducks): update machinery to v${version}" --quiet
  git::push_branch "$branch"
}

# ── Step 8: reporting ────────────────────────────────────────────────────
update::tracking_issue_find() {
  local results
  results="$(its::search_issues "$UPDATE_FAILURE_MARKER" 2>/dev/null || echo '[]')"
  printf '%s' "$results" | jq -r --arg m "$UPDATE_FAILURE_MARKER" \
    '[.[] | select((.body // "") | contains($m))] | .[0].number // empty'
}

# update::tracking_issue_report BODY → posts/edits the reusable failure
# tracking issue (marker-based) unless AUTODUCKS_UPDATE_NOTIFY_ISSUE is set,
# in which case it comments there instead.
update::tracking_issue_report() {
  local body="$1"
  if [[ -n "$AUTODUCKS_UPDATE_NOTIFY_ISSUE" ]]; then
    its::comment_issue "$AUTODUCKS_UPDATE_NOTIFY_ISSUE" "$body" || true
    return 0
  fi
  local existing full
  existing="$(update::tracking_issue_find)"
  full="${body}"$'\n\n'"${UPDATE_FAILURE_MARKER}"
  if [[ -n "$existing" ]]; then
    its::update_issue_body "$existing" "$full" || true
    its::comment_issue "$existing" "$body" || true
  else
    local tmp; tmp="$(mktemp)"
    printf '%s' "$full" >"$tmp"
    its::create_issue "Autoducks update is failing" "$tmp" "Autoducks:update" "" "" || true
    rm -f "$tmp"
  fi
}

update::tracking_issue_close_if_open() {
  [[ -n "$AUTODUCKS_UPDATE_NOTIFY_ISSUE" ]] && return 0
  local existing
  existing="$(update::tracking_issue_find)"
  [[ -n "$existing" ]] && its::close_issue "$existing" "Resolved by a successful update run." "completed" || true
  return 0
}

# update::report_failure REASON — Step 8 failure path. Comment-triggered
# runs fail the triggering issue's status comment; scheduled runs go to
# update.notify_issue when set, else the reusable tracking issue.
update::report_failure() {
  local reason="$1"
  echo "::error::update: $reason" >&2
  if [[ -n "$ISSUE_NUM" ]]; then
    react_to_comment "$COMMENT_ID" "confused"
    status_comment::fail "$ISSUE_NUM" "$reason"
    return 0
  fi
  echo "### ❌ Autoducks update failed"$'\n\n'"$reason" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  local body="⚠️ **Scheduled autoducks update failed.**

$reason

📄 [View the run logs](https://github.com/$REPO/actions/runs/$RUN_ID)."
  update::tracking_issue_report "$body"
}

# update::report_soft_stop REASON — a soft stop (existing-pr / pipeline-conflict
# / mode-off): not a failure, just reported and nothing further happens.
update::report_soft_stop() {
  local reason="$1"
  echo "::notice::update: $reason" >&2
  if [[ -n "$ISSUE_NUM" ]]; then
    status_comment::finish "$ISSUE_NUM" "$reason"
    react_to_comment "$COMMENT_ID" "+1"
    return 0
  fi
  echo "### ℹ️ Autoducks update"$'\n\n'"$reason" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# update::report_success SUMMARY PR_URL — Step 8 success path. Scheduled
# success produces zero comment noise: the summary goes to
# GITHUB_STEP_SUMMARY (the PR body already carries the full detail).
update::report_success() {
  local summary="$1" pr_url="${2:-}"
  echo "### ✅ Autoducks update"$'\n\n'"$summary" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  update::tracking_issue_close_if_open
  if [[ -n "$ISSUE_NUM" ]]; then
    status_comment::finish "$ISSUE_NUM" "$summary"
    react_to_comment "$COMMENT_ID" "+1"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
update::main() {
  [[ -n "$ISSUE_NUM" ]] && { react_to_comment "$COMMENT_ID" "eyes"; status_comment::start "$ISSUE_NUM"; }

  local target_ref
  if [[ -n "${REF:-}" ]]; then
    target_ref="$REF"
  else
    target_ref="$(update::resolve_target "$PIN" "$CHANNEL")"
  fi

  local target_sha target_version
  target_sha="$(update::resolve_sha "$target_ref")"
  if [[ -z "$target_sha" ]]; then
    update::report_failure "Could not resolve \`$target_ref\` on \`$SRC\` to a commit SHA."
    exit 1
  fi
  target_version="$(update::fetch_version_at "$target_sha")"

  local installed_sha installed_version previous_sha previous_version
  installed_sha="$(update::read_installed_field sha)"
  installed_version="$(update::read_installed_field version)"
  previous_sha="$installed_sha"
  previous_version="$installed_version"

  local decision
  decision="$(update::decide "$installed_sha" "$installed_version" "$target_sha" "$target_version" "$PIN")"
  case "$decision" in
    up-to-date)
      # A scheduled run has no ISSUE_NUM, so report_soft_stop was skipped and the
      # cycle ended with no trace anywhere — "ran and found nothing" and "never
      # ran" looked the same to anyone checking. The step summary is the one
      # surface a scheduled run always has.
      [[ -n "$ISSUE_NUM" ]] && update::report_soft_stop "Already up to date at \`$target_sha\` (v${installed_version:-unversioned})."
      echo "::notice::update: already up to date at ${target_sha:0:7} (v${installed_version:-unversioned}) — nothing to do."
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && \
        printf '### Autoducks update\n\nAlready up to date at `%s` (v%s).\n' \
          "${target_sha:0:7}" "${installed_version:-unversioned}" >>"$GITHUB_STEP_SUMMARY"
      exit 0
      ;;
    downgrade)
      update::report_soft_stop "Target v${target_version} is older than the installed v${installed_version} and \`update.pin\` is not set — refusing to downgrade. Set \`update.pin\` to roll back deliberately."
      exit 0
      ;;
  esac

  local preflight status reason
  preflight="$(update::preflight "$MODE" "$AUTODUCKS_UPDATE_ENABLED" "$TRIGGER")"
  status="${preflight%%$'\t'*}"
  reason="${preflight#*$'\t'}"
  case "$status" in
    mode-off)
      update::report_soft_stop "$reason"
      exit 0
      ;;
    existing-pr)
      # Only say it once per version. The scheduled cycle re-runs weekly while an
      # update PR sits open, and this posted the same line every time — a PR left
      # open for a quarter collected a dozen identical comments.
      local _seen=""
      _seen="$(its::list_comments "$reason" 2>/dev/null \
        | jq -r --arg m "$UPDATE_AVAILABLE_MARKER$target_sha" \
            '[.[] | select((.body // "") | contains($m))] | length' 2>/dev/null || echo 0)"
      if [[ "${_seen:-0}" == "0" ]]; then
        its::comment_issue "$reason" "A newer version is now available: v${target_version} (\`$target_sha\`).

${UPDATE_AVAILABLE_MARKER}${target_sha}" || true
      fi
      update::report_soft_stop "An update PR is already open (#$reason) — commented the newly-available version there instead of opening a second one."
      exit 0
      ;;
    pipeline-conflict)
      update::report_soft_stop "$reason"
      exit 0
      ;;
    no-identity)
      update::report_failure "$reason"
      exit 1
      ;;
  esac

  local branch; branch="$(update::branch_name "$target_version" "$target_sha")"
  local pre_update_dir; pre_update_dir="$(mktemp -d)"
  update::snapshot_pre_update "$pre_update_dir"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "::notice::update: DRY_RUN=true — would update to v${target_version} (\`$target_sha\`) on branch \`$branch\`." >&2
    update::report_soft_stop "Dry run: would update to v${target_version} (\`$target_sha\`) on branch \`$branch\`."
    exit 0
  fi

  update::apply_branch "$AUTODUCKS_BASE_BRANCH" "$branch" "$target_sha" "$CHANNEL"

  local migration_report; migration_report="$(mktemp)"
  if ! update::run_migrations "$installed_version" "$target_version" ".autoducks/migrations" "$migration_report"; then
    update::discard_branch "$branch"
    update::report_failure "Migration to v${target_version} failed — see the run log. The update branch was discarded."
    exit 1
  fi

  local drift_paths drift_section drift_unknown=0 drift_rc=0
  drift_paths="$(mktemp)"
  update::detect_drift "$previous_sha" "$pre_update_dir" >"$drift_paths" || drift_rc=$?
  # Any non-zero means "could not determine". 2 is the documented signal, but an
  # unexpected code has to fail closed as well: the previous form tested $? inside
  # a `|| { ... }` group, so a third exit code made the group itself fail and
  # set -e killed the run before any update::report_* call could fire — the exact
  # silent failure the Observability constraint exists to prevent.
  if [[ "$drift_rc" -ne 0 ]]; then drift_unknown=1; fi

  # "Could not determine" is not "none". Treated as none, a rate-limited fetch
  # would let on_drift=abort pass and auto-merge overwrite a consumer's local
  # machinery edits silently — the one outcome the drift feature exists to
  # prevent. So it fails closed: abort where abort is configured, and never
  # auto-merge on an unknown.
  if [[ "$drift_unknown" -eq 1 ]]; then
    if [[ "$AUTODUCKS_UPDATE_ON_DRIFT" == "abort" ]]; then
      update::report_failure "Local machinery drift could not be determined for this run (the previous machinery tree could not be fetched or read) and \`update.on_drift\` is \`abort\` — the update branch was discarded. Re-run once upstream is reachable."
      update::discard_branch "$branch"
      exit 1
    fi
  elif [[ -s "$drift_paths" ]]; then
    if [[ "$AUTODUCKS_UPDATE_ON_DRIFT" == "abort" ]]; then
      local first_file; first_file="$(head -1 "$drift_paths")"
      update::report_failure "Local machinery changes were detected in \`$first_file\`$( [[ "$(wc -l <"$drift_paths")" -gt 1 ]] && printf ' (and %d more)' "$(( $(wc -l <"$drift_paths") - 1 ))" ) and \`update.on_drift\` is \`abort\` — the update branch was discarded."
      update::discard_branch "$branch"
      exit 1
    fi
  fi
  drift_section="$(mktemp)"
  if [[ "$drift_unknown" -eq 1 ]]; then
    # Say so in the PR body. A reviewer who sees no drift section reasonably
    # concludes there was none; silence here would be the same lie the exit
    # code was added to stop telling.
    printf '## ⚠️ Local machinery drift: UNKNOWN\n\nThe previously installed machinery could not be fetched or read, so this run could not tell whether local edits are being overwritten. Review the diff before merging.\n\n' >"$drift_section"
  else
    update::drift_section "$pre_update_dir" "$drift_paths" >"$drift_section"
  fi

  local verify_output; verify_output="$(mktemp)"
  if ! update::run_verify "$verify_output"; then
    update::discard_branch "$branch"
    update::report_failure "\`verify-machinery.sh\` failed after applying v${target_version}:

$(cat "$verify_output")

No PR was opened and no commit was made; the update branch was discarded."
    exit 1
  fi

  local bump_kind=""
  [[ -n "$installed_version" && -n "$target_version" ]] && bump_kind="$(semver::bump_kind "$installed_version" "$target_version")"
  # Same stale-root trap as update::pr_body, and the more dangerous half: this
  # value gates auto_merge_eligible. Read against the pinned pre-update snapshot
  # it was always 0, so a release declaring breaking changes satisfied the
  # "no breaking changes" precondition and could auto-merge to the default
  # branch with nobody looking.
  local _breaking_root="${GITHUB_WORKSPACE:-$PWD}/.autoducks"
  [[ -f "$_breaking_root/CHANGELOG.md" ]] || _breaking_root="${AUTODUCKS_ROOT:-.autoducks}"
  local has_breaking=0
  if [[ -n "$installed_version" && -n "$target_version" ]] \
     && AUTODUCKS_ROOT="$_breaking_root" changelog::has_breaking "$installed_version" "$target_version" 2>/dev/null; then
    has_breaking=1
  fi
  # An unknown counts as drift for the auto-merge gate. auto_merge_eligible's
  # question is "is it safe to merge this without a human looking", and the
  # honest answer when drift could not be evaluated is no.
  local has_drift=0
  [[ -s "$drift_paths" ]] && has_drift=1
  [[ "$drift_unknown" -eq 1 ]] && has_drift=1

  local body; body="$(update::pr_body "$installed_version" "$target_version" "$CHANNEL" "$PIN" \
    "$installed_sha" "$target_sha" "$migration_report" "$drift_section" "$verify_output" "$previous_sha")"

  local title="chore(autoducks): update machinery to v${target_version}"

  if [[ "$MODE" == "commit" ]]; then
    # commit mode is a delivery *method*, not an exemption. The constraints say a
    # major bump never merges unattended at any setting, and a drifted or
    # unevaluated tree must be seen before it is overwritten — bump_kind,
    # has_breaking and has_drift are all computed just above and were simply not
    # consulted here, so `mode: commit` pushed a 2.0.0 straight to the default
    # branch and dropped the drift report with it.
    if [[ "$bump_kind" == "major" || "$has_breaking" == "1" || "$has_drift" == "1" ]]; then
      local _why="a major bump"
      [[ "$bump_kind" != "major" && "$has_breaking" == "1" ]] && _why="a breaking changelog entry"
      [[ "$bump_kind" != "major" && "$has_breaking" != "1" ]] && _why="local machinery drift (or drift that could not be evaluated)"
      echo "::notice::update: mode is 'commit' but this update carries $_why — opening a PR instead of pushing to $AUTODUCKS_BASE_BRANCH." >&2
    else
      update::deliver_commit "$branch" "$AUTODUCKS_BASE_BRANCH" "$target_version"
      git push origin "HEAD:refs/heads/$AUTODUCKS_BASE_BRANCH"
      # deliver_commit pushes the branch because the PR path needs it; this path
      # does not. Without this the branch outlives the cycle — apply_branch clears
      # a stale ref on the next run, so it self-healed, but a commit-mode repo
      # carried one visible orphan branch between cycles.
      git::delete_branch "$branch" 2>/dev/null || true
      update::report_success "Pushed \`$title\` directly to \`$AUTODUCKS_BASE_BRANCH\` (mode: commit)."
      exit 0
    fi
  fi

  update::deliver_commit "$branch" "$AUTODUCKS_BASE_BRANCH" "$target_version"
  local pr_number
  pr_number="$(git::create_pr "$branch" "$AUTODUCKS_BASE_BRANCH" "$title" "$body" "false")"

  its::add_label "$pr_number" "Autoducks:update" || true
  if [[ "$bump_kind" == "major" || "$has_breaking" == "1" ]]; then
    its::add_label "$pr_number" "Autoducks:breaking" || true
  fi

  # A verify-machinery failure discards the branch and exits, so there is no path
  # here on which the machinery check failed — auto_merge_eligible used to take a
  # checks_ok argument that was provably 1, a gate that read live but could never
  # fire. The real gate belongs to GitHub: arm auto-merge and let the repo's own
  # required checks hold it. Step 6 verified the machinery; this is about the
  # consumer's CI, which had no say before.
  local merged="not merged"
  if update::auto_merge_eligible "$AUTODUCKS_UPDATE_AUTO_MERGE" "$bump_kind" "$has_breaking" "$has_drift"; then
    if git::merge_pr "$pr_number" auto; then
      merged="auto-merge armed"
    else
      merged="not merged (auto-merge unavailable — merge manually once checks pass)"
    fi
  fi

  update::report_success "Opened PR #$pr_number: \`$title\` ($merged)." "https://github.com/$REPO/pull/$pr_number"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  update::main
fi
