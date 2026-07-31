#!/usr/bin/env bash
# ── Agent / verb roster ─────────────────────────────────────────────
# Single source of truth for which agents exist and which verbs the
# machinery already owns.
#
# Two scripts need this list and used to carry their own copy:
# generate-trigger-conditions.sh bakes the alias guards into the workflow
# YAML at install time, and parse-directive.sh resolves an alias back to
# its canonical verb at run time. The copies drifted twice; the second
# time left `triage`, `merge` and `update` aliases validating at install,
# firing their workflow, and then emitting the raw alias as `command=`.
#
# Adding an agent means adding it here and nowhere else.

# Canonical agent names — one per `triggers.<agent>[]` key in autoducks.json.
AUTODUCKS_AGENTS=(architect engineer execute fix revert close review rework defer resolve triage merge update agent)

# Built-in synonyms, `<synonym>:<canonical>`. normalize_verb() resolves
# these before consulting the configured aliases.
AUTODUCKS_VERB_SYNONYMS=(design:architect tactics:engineer run:execute work:execute)

# Every verb the machinery already owns — canonical names plus synonyms.
# A custom alias may not collide with any of them.
AUTODUCKS_BUILTIN_VERBS="${AUTODUCKS_AGENTS[*]} ${AUTODUCKS_VERB_SYNONYMS[*]%%:*}"
