# playwright-browser

An official reference/starter plugin. It exists to demonstrate the full
plugin package format end to end — it is **not enabled by default** (the
shipped `.autoducks/autoducks.json` keeps `"plugins": []`) and ships purely
as a fixture to build your own plugin from, or to sanity-check the compiler
against.

It exercises both plugin capabilities:

- **(A) Workflow step injection + MCP/tools.** `hooks/developer-pre/action.yml`
  installs a Chromium toolchain (`playwright install --with-deps chromium`)
  before the Developer agent runs; `claude/mcp.json` registers a Playwright
  MCP server; `plugin.json`'s `allowedTools` grants the agent the
  `mcp__playwright__*` tools it needs to drive that server.
- **(B) A Claude Code hook.** `claude/hooks.json` registers a `PreToolUse`
  hook that logs every `mcp__playwright__*` tool call before it runs — a
  minimal, non-blocking audit trail.

## What it grants

Enabling this plugin (scoped to the `developer` target only) gives the
Developer agent:

- A `PreToolUse` hook step in `.github/workflows/autoducks-developer.yml`'s
  `developer-pre` point that runs `npx playwright install --with-deps
  chromium` — it downloads and executes third-party binaries during the
  workflow run.
- A registered `playwright` MCP server (`npx @playwright/mcp@latest
  --headless`) — another third-party binary, invoked by Claude Code itself
  during the agent step, with network access to whatever pages it navigates
  to.
- The `mcp__playwright__browser_navigate`, `browser_click`, `browser_type`,
  `browser_snapshot`, and `browser_take_screenshot` tools, i.e. the ability
  to drive a real browser from the agent's turn.
- A `PreToolUse` hook command (`jq ... >&2`) that runs on every matching tool
  call, inline in the same job.

## Trust implications

**Installing a plugin means trusting its author with your CI token.** Every
hook step and MCP server here runs inside the same GitHub Actions job as the
Developer agent, with the same `GH_TOKEN` and repository checkout — there is
no additional sandboxing. Before enabling any plugin (this one included),
read every `hooks/*/action.yml`, `claude/mcp.json`, and `claude/hooks.json`
in the package the way you'd review any other CI change: the vendoring model
(`.autoducks/plugins/<name>/`) puts the plugin's exact code under version
control specifically so it's diffable and reviewable, not fetched opaquely
at run time.

## Enabling it

```jsonc
// .autoducks/autoducks.json
{
  // ...
  "plugins": [
    {
      "name": "playwright-browser",
      "source": "./examples/plugins/playwright-browser"
    }
  ]
}
```

Then run `.autoducks/core/config/apply-plugins.sh` to compile it into
`.github/actions/autoducks/developer-pre/` and
`.autoducks/providers/llm/claude/compiled/developer.settings.json` /
`developer.allowed-tools`.
