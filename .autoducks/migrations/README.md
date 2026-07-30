# Migrations

The updater runs every migration under this directory whose `<version>`
satisfies `installed.version < version <= target.version`, in ascending
semver order, when moving a consumer install from `installed.version` to
`target.version`.

## Contract

Each migration lives at `.autoducks/migrations/<version>/migrate.sh` and
must:

- Be **idempotent** — running it again against an already-migrated config
  makes no further change.
- Touch only **consumer-owned state** (in practice, `autoducks.json`; see
  `core/config/consumer-owned.sh` for the full list). Never edit vendored
  machinery.
- **Exit non-zero only on a condition a human must resolve.** A migration
  that can complete on its own should complete on its own, not fail because
  something was merely unusual.
- **Append human-readable prose to the report.** `AUTODUCKS_MIGRATION_REPORT`
  is set by the updater to the path of an append-only file; a migration that
  changes something appends a short, human-readable description of the
  change (a run that changes nothing appends nothing).
- **Never widen the security surface.** A migration may add a new
  `security.per_agent` entry, but must never remove an existing
  `security.deny` entry or broaden an existing `trusted_associations` list.

## Running a migration directly

```
AUTODUCKS_ROOT=/path/to/.autoducks \
AUTODUCKS_MIGRATION_REPORT=/tmp/migration-report.md \
  bash .autoducks/migrations/0.2.0/migrate.sh
```
