# autoducks

autoducks lets you run code agents on your CI/CD platform, triggered by issue comments, with any LLM provider. One command drives a full design → plan → execute pipeline: each agent checks its own Definition of Ready and automatically dispatches the missing prerequisite, so you always get a reviewed design and plan before code is written.

Full documentation lives at **<https://autoducks.openvibes.tech>**.

## Four agents, one pipeline

| Agent | Layer | What it does | Trigger phrases |
|-------|-------|--------------|-----------------|
| **Architect** | Design | Creates **or revises** the design of a feature/bug in the issue body | `/quack architect`, `/quack design` |
| **Engineer** | Tactics | Breaks the design into task issues organized in dependency waves | `/quack engineer`, `/quack tactics` |
| **Maestro** | Orchestration | Owns branches/PRs and dispatches execution waves in parallel | `/quack execute`, `/quack run`, `/quack work` |
| **Developer** | Build | Implements one task and merges its PR into the pipeline branch | (dispatched by the Maestro, or `execute` on a Task issue) |

The same `execute` comment routes to the right agent by issue state — you never have to know which workflow runs. On a raw issue it cascades through the whole pipeline automatically (Architect → Engineer → Maestro → Developers). You can also chain agents explicitly: `/quack architect #auto:engineer+execute`.

Utility agents: `/quack fix` (repair a failed task run), `/quack revert` (undo a feature, restore the human-authored issue), `/quack close` (tear everything down).

## Command syntax

```
/quack <trigger> [model:opus|sonnet|haiku] [effort:low|medium|high|max] [turns:N] [#auto:agent+agent]
```

The `/quack` prefix, trigger aliases, models, security, and branches are all configurable in `.autoducks/autoducks.json`.

## Pluggable by design

Three provider interfaces — ITS (issue tracking), Git, and LLM — keep agent logic decoupled from any specific vendor. The runtime layer that wires triggers to scripts is a separate concern.

Currently shipping with the **GitHub Actions** runtime, **GitHub** as ITS and Git, and **Claude** as the LLM. Other runtimes are planned.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/deepducks/autoducks/main/scripts/install.sh | bash
```

See the [installation guide](https://autoducks.openvibes.tech/getting-started/installation/) for prerequisites and setup checks.

## First command

Open an issue describing what you want, then comment:

```
/quack execute
```

The pipeline designs, plans, and implements it — opening a PR per task and a final PR for review. Prefer to review each stage? Run `/quack architect`, `/quack engineer`, and `/quack execute` one at a time.

## Where to go next

| Topic | Link |
|-------|------|
| What autoducks is and how it works | <https://autoducks.openvibes.tech/getting-started/introduction/> |
| Installation and setup | <https://autoducks.openvibes.tech/getting-started/installation/> |
| Your first feature | <https://autoducks.openvibes.tech/getting-started/first-feature/> |
| Agents overview | <https://autoducks.openvibes.tech/agents/> |
| Slash command reference | <https://autoducks.openvibes.tech/reference/slash-commands/> |
| Configuration | <https://autoducks.openvibes.tech/reference/configuration/> |
| Design philosophy | <https://autoducks.openvibes.tech/about/> |

> The documentation site still describes the previous topology (design/tactical/wave/execution, `/agents` commands) — it is being updated to this taxonomy. This README and `.autoducks/design/AGENTS.md` are current.

## Contributing

Issues and PRs welcome.

## License

MIT
