#!/usr/bin/env bash
# consumer-owned.sh — the single list of paths (relative to .autoducks/) that
# hold consumer state rather than vendored machinery. install.sh's
# stash/restore loop, the updater's drift comparison, and setup.sh all source
# this file so the three can never disagree about what belongs to the
# consumer.
#
# Safe to source standalone: no load-config.sh dependency (install.sh sources
# this before a local .autoducks/ tree necessarily exists on disk — it reads
# it out of the freshly downloaded tree instead), no set -e/-u of its own so
# it never changes the sourcing shell's options, just a plain array.

# shellcheck disable=SC2034 # consumed by every script that sources this file
AUTODUCKS_CONSUMER_OWNED=(
  "autoducks.json"
  "providers/llm/claude/settings.json"
  "custom"
  "plugins"
  "security-guidelines.md"
)
