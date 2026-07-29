#!/usr/bin/env bash
# Decides which credential claude-code-action receives, and wires a custom
# Anthropic-compatible endpoint into the job environment when one is configured.
#
# Inputs (env):  BASE_URL, AUTH_TOKEN, API_KEY, OAUTH_TOKEN
# Outputs:       api_key, oauth_token  -> $GITHUB_OUTPUT
#                ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN -> $GITHUB_ENV
#
# Why $GITHUB_ENV and not the step's env:. claude-code-action reads
# ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN straight from the job environment —
# neither is an action input — and its own env: block shadows anything set on
# the calling step, so $GITHUB_ENV is the only route that reaches the Claude CLI
# subprocess.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

if [[ -z "${BASE_URL:-}" ]]; then
  # Default endpoint: hand the repo's credentials through untouched.
  {
    echo "api_key=${API_KEY:-}"
    echo "oauth_token=${OAUTH_TOKEN:-}"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

: "${GITHUB_ENV:?GITHUB_ENV must be set}"
echo "ANTHROPIC_BASE_URL=$BASE_URL" >> "$GITHUB_ENV"

if [[ -n "${AUTH_TOKEN:-}" ]]; then
  echo "::add-mask::$AUTH_TOKEN"
  echo "ANTHROPIC_AUTH_TOKEN=$AUTH_TOKEN" >> "$GITHUB_ENV"
fi

# A subscription OAuth token is only valid against api.anthropic.com, and Claude
# Code prefers it over the API key — passing it alongside a custom endpoint sends
# the wrong credential to the gateway. The custom endpoint wins: drop the token.
KEY="${API_KEY:-}"
if [[ -z "$KEY" ]]; then
  # claude-code-action's base action refuses to start without ANTHROPIC_API_KEY
  # or an OAuth token, so the bearer credential doubles as the API key when the
  # gateway was configured with only ANTHROPIC_AUTH_TOKEN.
  KEY="${AUTH_TOKEN:-}"
fi
if [[ -n "$KEY" ]]; then
  echo "::add-mask::$KEY"
fi

{
  echo "api_key=$KEY"
  echo "oauth_token="
} >> "$GITHUB_OUTPUT"
