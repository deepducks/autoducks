# Changelog

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

## [0.1.0] - 2026-07-30

### Added
- Versioning substrate: `.autoducks/VERSION`, `.autoducks/CHANGELOG.md`, the
  shared `semver.sh` module, and the `changelog.sh` parser. The plugin
  `autoducksVersion` compat gate in `apply-plugins.sh` now reads a live host
  version from `.autoducks/VERSION` instead of staying advisory-only.
