# Changelog

## [0.5.7] - 2026-08-03

### Fixed
- fix(agent): Read belongs in the tool floor too (#1176)

## [0.5.6] - 2026-08-03

### Fixed
- fix(agent): a tool floor the definition cannot replace away (#1174)

## [0.5.5] - 2026-08-03

### Fixed
- fix(feedback): a max_turns retry hint for the agent lane (#1172)

## [0.5.4] - 2026-08-03

### Fixed
- fix(agent): honour surface: both, and stop double-posting refusals (#1170)

## [0.5.3] - 2026-08-02

### Security
- The custom-agent lane now reads agent definitions — and the `custom_agents`
  config keys that grant them tools — from the base branch, never from the
  checked-out tree. On a pull request the checkout is `refs/pull/N/head`, and a
  definition body becomes the agent's prompt, so the previous behaviour could
  execute unreviewed content with the repository's token. This applies to both
  discovery and prompt assembly. (#1168)

### Changed
- **Behaviour change for `/agent`:** a definition that exists only on a pull
  request is no longer discovered, so an agent cannot be tried from the pull
  request that introduces it. Merge the definition to the default branch first,
  then use it. A `/agent` run on a pull request still works and still takes that
  pull request as its context; only the definition comes from elsewhere. (#1168)
- Removed the machinery this replaces: the `verified` descriptor field, the tool
  clamp and its `unverified_tools` floor, the unverified-definition refusal, and
  the `custom_agents.allow_unverified` opt-in. None of these were part of a
  release, so no configuration needs migrating. (#1168)

## [0.5.2] - 2026-08-02

### Fixed
- fix(metarepo): fail the delivery check on a gitlink nothing can reach (#1166)
- fix(agent): land the custom-agent lane review rounds on top of v0.5.1 (#1165)

## [0.5.1] - 2026-08-02

### Fixed
- fix(release): publish on the tag push, and stop letting GitHub pick `latest` (#1163)
- fix(config,its): one roster, one marker — close the two ways they degrade (#1162)

## [0.5.0] - 2026-08-01

### Added
- feat(product): the triage sweep flags duplicates instead of closing them (#1159)

### Fixed
- fix(release): one changelog entry per merged PR, not one per parent (#1160)
- fix(smoke,design): assert the /architect re-run contract that actually ships (#1158)
- fix(product,smoke): stop triage re-classifying pipeline tasks (#183 follow-up) (#1157)
- fix(revert): recognise machinery comments by marker, not by author (#183) (#1156)
- fix(metarepo): let the parent own the child branch's lifetime (#182) (#1155)

## [0.4.0] - 2026-08-01

### Fixed
- fix(smoke): repair the plan test's array length checks and 👍 assertion (#1152)
- fix(smoke): handle the delegated code in both plan-test call sites (#1151)
- fix(feedback): a delegation is a handoff, not a success (#1150)
- fix(feedback): react on delegation, so a handoff stops looking like a hang (#1149)
- fix(release): let --dry-run run on a branch it cannot push to (#1148)

### Changed
- chore: ignore .claude/ so worktrees do not block a release (#1153)

## [0.3.0] - 2026-07-31

### Added
- feat(metarepo): sync the parent gitlink when a child advances (#1141)

### Fixed
- fix(release): give --pr and --tag, so the PR route actually exists (#1146)
- fix(metarepo): stop auto-merge from deleting the branch it is waiting on (#1145)
- fix(product,rework): pass bulk agent context to jq through files (#1144)
- fix(metarepo): stop asking for a submodule entry that states nothing (#1142)
- fix(release): refuse before mutating when main cannot be pushed directly (#1139)

### Changed
- Autoducks: deliver feature/82-custom-agents (#1143)
- Merge remote-tracking branch 'origin/main' into HEAD
- Merge origin/main into feature/82-custom-agents
- Implement issue #163
- Implement issue #162
- Implement issue #161
- Implement issue #160
- Implement issue #159
- Implement issue #158
- Implement issue #157
- Implement issue #156

## [0.2.0] - 2026-07-31

### Added
- Documented the `agent` lane in `.autoducks/design/AGENTS.md`: the `/agent
  <name>` positional command surface (including that `/agent sonnet` looks up
  an agent named `sonnet` rather than the `sonnet` model alias, and that a
  bare `/agent` posts the catalog), the new "Agent Lane" section among the
  utility agents, the `Agent:running`/`Agent:done` label pair, the
  `agent/<name>/<issue>-<slug>` branch namespace, and the
  `.autoducks/agents/agent/` directory entry alongside `discover-agents.sh`
  and `interpolate-artifacts.sh`.

**Update note:** every `autoducks.json` key the `agent` lane itself reads is
optional and inert when absent, so the `agent` lane contributes no migration
of its own for this version boundary (the `migrations/0.2.0/migrate.sh` that
ships in this release is unrelated — it back-fills the `update` config block
for the Update agent). Consuming repos do need one `scripts/install.sh` run,
one `update-triggers.sh` run, or one Update-agent pass to bake the `/agent`
trigger word into their workflow guards before `/agent` will respond — but
that pass is a one-time cost for the whole custom-agent lane, not something
repeated per custom agent added afterward.

- feat(metarepo): make submodules.<path>.protected an actual override

### Fixed
- fix(smoke): make the update smoke test actually run
- fix(update): the residual findings from the eighth #143 review
- fix(metarepo): validate metarepo.submodules against .gitmodules
- fix(config): derive the agent roster from one file
- fix(update): three findings from the seventh #143 review (#1137)
- fix(update): three findings from the sixth #143 review (#1136)
- fix(update): the four minor findings from the fifth #143 review (#1135)
- fix(update): drift detection must fail closed, and authenticate its fetch (#1134)
- fix(metarepo): do not recreate a child task branch on a delivered pin (#1133)
- fix(update): stop the update branch wedging later runs; fix install.sh channel semantics (#1132)
- fix(update): three findings from the second #143 review (#1131)
- fix(config): repo-wide agent defaults were silently discarded (#1126)
- fix(update): address the three delivery-path findings from the #143 review (#1130)
- fix(update): do not invoke the update agent when it is not installed (#1128)
- fix(102): reconcile two same-plan tasks that never saw each other
- fix(developer): carry the resolved feature branch from pre.sh into post.sh (#1125)

### Changed
- Autoducks: deliver feature/102-automatic-updates (update agent) (#1129)
- Merge remote-tracking branch 'origin/main' into feature/102-automatic-updates
- Implement issue #153
- Autoducks: deliver feature/102-automatic-updates (#1127)
- WIP: partial work from #141 (max_turns cutoff)
- Implement issue #140
- WIP: partial work from #140 (max_turns cutoff)
- Implement issue #139
- WIP: partial work from #139 (max_turns cutoff)
- WIP: partial work from #138 (max_turns cutoff)
- Implement issue #137
- Implement issue #136
- Implement issue #135
- WIP: partial work from #135 (max_turns cutoff)
- WIP: partial work from #134 (max_turns cutoff)

## [0.1.0] - 2026-07-30

### Added
- Versioning substrate: `.autoducks/VERSION`, `.autoducks/CHANGELOG.md`, the
  shared `semver.sh` module, and the `changelog.sh` parser. The plugin
  `autoducksVersion` compat gate in `apply-plugins.sh` now reads a live host
  version from `.autoducks/VERSION` instead of staying advisory-only.
