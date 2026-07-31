# Changelog

## [0.2.0] - 2026-07-31

### Added
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
