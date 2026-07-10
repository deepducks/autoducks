# autoducks

autoducks lets you run code agents on your CI/CD platform, triggered by issue comments, with any LLM provider. One command drives a full design → plan → execute pipeline: each agent checks its own Definition of Ready and automatically dispatches the missing prerequisite, so you always get a reviewed design and plan before code is written.

Full documentation lives at **<https://autoducks.openvibes.tech>**.

## Four agents, one pipeline

| Agent | Layer | What it does | Trigger phrases |
|-------|-------|--------------|-----------------|
| **Architect** | Design | Creates **or revises** the design of a feature/bug in the issue body | `/architect`, `/design` |
| **Engineer** | Tactics | Breaks the design into task issues organized in dependency waves | `/engineer`, `/tactics` |
| **Maestro** | Orchestration | Owns branches/PRs and dispatches execution waves in parallel | `/execute`, `/run`, `/work` |
| **Developer** | Build | Implements one task and merges its PR into the pipeline branch | (dispatched by the Maestro, or `execute` on a Task issue) |

The same `execute` comment routes to the right agent by issue state — you never have to know which workflow runs. On a raw issue it cascades through the whole pipeline automatically (Architect → Engineer → Maestro → Developers). You can also chain agents explicitly: `/architect #auto:engineer+execute`.

Utility agents: `/review` (review a finished PR against its design and acceptance criteria — read-only, never merges), `/rework` (distill unresolved review feedback into one follow-up task and revert the PR to draft), `/defer` (capture unresolved review feedback as a follow-up issue so the PR can be merged/closed now), `/triage` (groom the backlog: assign priorities, propose duplicate groupings — scheduled, on issue open, or on demand), `/merge` (deterministically close one issue as a duplicate of another), `/fix` (repair a failed task run), `/revert` (undo a feature, restore the human-authored issue), `/close` (tear everything down).

## Command syntax

```
/<trigger> [model:opus|sonnet|haiku] [effort:low|medium|high|max] [turns:N] [#auto:agent+agent]
```

Commands are short-form by default — no prefix needed. Trigger aliases, models, security, branches, and an optional namespace (`/quack <trigger>`, for repos that want one) are all configurable in `.autoducks/autoducks.json`.

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
/execute
```

The pipeline designs, plans, and implements it — opening a PR per task and a final PR for review. Prefer to review each stage? Run `/architect`, `/engineer`, and `/execute` one at a time.

## Where to go next

| Topic | Link |
|-------|------|
| What autoducks is and how it works | <https://autoducks.openvibes.tech/getting-started/introduction/> |
| Installation and setup | <https://autoducks.openvibes.tech/getting-started/installation/> |
| Your first run | <https://autoducks.openvibes.tech/getting-started/first-run/> |
| Agents overview | <https://autoducks.openvibes.tech/agents/> |
| Lifecycle of an issue | <https://autoducks.openvibes.tech/guides/pipeline-lifecycle/> |
| Chaining & overrides | <https://autoducks.openvibes.tech/guides/chaining-and-overrides/> |
| When things fail | <https://autoducks.openvibes.tech/guides/when-things-fail/> |
| Migrating from `/agents` | <https://autoducks.openvibes.tech/guides/migrating-from-agents/> |
| Slash command reference | <https://autoducks.openvibes.tech/reference/slash-commands/> |
| Configuration | <https://autoducks.openvibes.tech/reference/configuration/> |
| Labels | <https://autoducks.openvibes.tech/reference/labels/> |
| Branch naming | <https://autoducks.openvibes.tech/reference/branch-naming/> |
| Security | <https://autoducks.openvibes.tech/reference/security/> |
| Design philosophy | <https://autoducks.openvibes.tech/about/> |

## Contributing

Issues and PRs welcome.

> **Referencing issues in commits.** Closing keywords (`Fixes/Closes/Resolves #N`) are reserved for the delivery PR body the Maestro generates — they close the issue when the PR merges. For any other commit that merely *mentions* an issue (hotfixes, side-quests, work-in-progress), use a **non-closing** reference: `refs #N` or `re #N`. This prevents a stray commit from closing an in-flight feature/task issue on the default branch.

## License

MIT
