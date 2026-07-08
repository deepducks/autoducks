#!/usr/bin/env bash
# namespace = AUTODUCKS_COMMAND with a single optional leading '/' stripped
# autoducks_command_for <canonical-verb> → "/verb" (namespace empty) | "/<ns> verb" (namespace set)
autoducks_command_for() {
  local verb="$1" ns="${AUTODUCKS_COMMAND#/}"
  if [[ -z "$ns" ]]; then printf '/%s' "$verb"; else printf '/%s %s' "$ns" "$verb"; fi
}
