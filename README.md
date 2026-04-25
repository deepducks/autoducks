# autoducks

autoducks lets you run code agents on your CI/CD platform, triggered by issue comments, with any LLM provider. Start with a single agent for task execution and add more layers as your needs grow — no need to adopt the full pipeline at once.

Full documentation lives at **<https://autoducks.openvibes.tech>**.

## Layered agents, opt-in

Four agents compose into a pipeline. Each layer is independently usable.

| Layer | What it adds | Command |
|-------|--------------|---------|
| **Execution** | Implements a task from an issue, opens a PR | `/agents execute` |
| **+ Tactical** | Breaks a feature spec into numbered task issues | `/agents devise` |
| **+ Wave Orchestrator** | Runs tasks in parallel, respecting dependencies | automatic |
| **+ Design** | Writes the spec from a rough idea | `/agents design` |

A team that writes detailed issue specs can run Execution alone. A team working on small tasks can skip Tactical and Waves. Use as many or as few as you need.

## Pluggable by design

Three provider interfaces — ITS (issue tracking), Git, and LLM — keep agent logic decoupled from any specific vendor. The runtime layer that wires triggers to scripts is a separate concern.

Currently shipping with the **GitHub Actions** runtime, **GitHub** as ITS and Git, and **Claude** as the LLM. Other runtimes are planned.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/deepducks/autoducks/main/scripts/install.sh | bash
```

See the [installation guide](https://autoducks.openvibes.tech/getting-started/installation/) for prerequisites and setup checks.

## First command

Open an issue describing a small change, then comment:

```
/agents execute
```

An LLM agent reads the issue, writes the code, and opens a PR. That's the recommended starting point — you can adopt the rest of the pipeline later.

## Where to go next

| Topic | Link |
|-------|------|
| What autoducks is and how it works | <https://autoducks.openvibes.tech/getting-started/introduction/> |
| Installation and setup | <https://autoducks.openvibes.tech/getting-started/installation/> |
| Your first feature | <https://autoducks.openvibes.tech/getting-started/first-feature/> |
| Agents overview | <https://autoducks.openvibes.tech/agents/> |
| Execution agent | <https://autoducks.openvibes.tech/agents/execution/> |
| Tactical agent | <https://autoducks.openvibes.tech/agents/tactical/> |
| Wave orchestrator | <https://autoducks.openvibes.tech/agents/wave-orchestrator/> |
| Design agent | <https://autoducks.openvibes.tech/agents/design/> |
| Utility commands (`fix`, `revert`, `close`) | <https://autoducks.openvibes.tech/agents/utilities/> |
| Slash command reference | <https://autoducks.openvibes.tech/reference/slash-commands/> |
| Configuration | <https://autoducks.openvibes.tech/reference/configuration/> |
| Runtimes | <https://autoducks.openvibes.tech/reference/runtimes/> |
| Branch naming | <https://autoducks.openvibes.tech/reference/branch-naming/> |
| Design philosophy | <https://autoducks.openvibes.tech/about/> |

## Contributing

Issues and PRs welcome.

## License

MIT
