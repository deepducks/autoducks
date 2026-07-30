# Changelog

## [0.1.0] - 2026-07-30

### Added
- Versioning substrate: `.autoducks/VERSION`, `.autoducks/CHANGELOG.md`, the
  shared `semver.sh` module, and the `changelog.sh` parser. The plugin
  `autoducksVersion` compat gate in `apply-plugins.sh` now reads a live host
  version from `.autoducks/VERSION` instead of staying advisory-only.
