/**
 * JSON Schema for `.autoducks/autoducks.json`, additive against every field
 * shipped in this repository's own config (see `docs/.../reference/configuration.mdx`
 * for the prose reference). Every object tolerates unknown properties so
 * older configs, newer configs, and this task's additive keys (`version`,
 * `architect.auto`, `engineer.auto`, `reviewer.auto`) all round-trip without
 * validation errors. Each property's `type`/`enum`/`description`/`default`
 * doubles as the field metadata the `config` TUI (T7) reads to render itself.
 */
export const CONFIG_SCHEMA = {
  $schema: 'http://json-schema.org/draft-07/schema#',
  type: 'object',
  additionalProperties: true,
  properties: {
    version: {
      type: 'string',
      description: 'Pinned autoducks release tag written by `install`, e.g. "v1.2.3". Absent means an unpinned/legacy install.',
      pattern: '^v\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.-]+)?$',
    },
    command: {
      type: 'string',
      description: 'Slash-command namespace word, or "" for short-form commands.',
      pattern: '^$|^/?[a-z0-9-]+$',
      default: '',
    },
    providers: {
      type: 'object',
      additionalProperties: true,
      properties: {
        its: { type: 'string', description: 'Issue-tracking-system provider.', default: 'github' },
        git: { type: 'string', description: 'Git hosting provider.', default: 'github' },
        llm: { type: 'string', description: 'LLM provider.', default: 'claude' },
      },
    },
    defaults: {
      type: 'object',
      additionalProperties: true,
      properties: {
        model: { type: 'string', description: 'Default Claude model ID for LLM agents.', default: 'claude-sonnet-5' },
        effort: {
          type: 'string',
          enum: ['off', 'low', 'medium', 'high', 'max'],
          description: 'Default LLM reasoning effort.',
          default: 'high',
        },
        max_turns: { type: 'integer', minimum: 1, description: 'Maximum agentic turns per run.' },
        base_branch: { type: 'string', description: 'Branch pipeline branches are cut from.', default: 'main' },
        integration_branch: {
          type: 'string',
          description: 'Branch final pipeline PRs target (defaults to base_branch when unset).',
        },
        merge_method: {
          type: 'string',
          enum: ['auto', 'merge', 'squash', 'rebase'],
          description: 'Method for auto-merging task/fix PRs into the pipeline branch.',
          default: 'auto',
        },
      },
    },
    orchestrator: {
      type: 'object',
      additionalProperties: true,
      properties: {
        mode: {
          type: 'string',
          enum: ['waves', 'sequential'],
          description: 'Maestro dispatch topology. Also the "Orchestration Mode" auto.',
          default: 'waves',
        },
      },
    },
    reviewer: {
      type: 'object',
      additionalProperties: true,
      properties: {
        required_check: {
          type: 'boolean',
          description: 'Whether a required-check ruleset gates merges on the Reviewer verdict.',
          default: false,
        },
        check_name: { type: 'string', description: 'Check-run name emitted on final PRs.', default: 'Autoducks: Reviewer' },
        auto: {
          type: 'boolean',
          description: 'Auto Review: dispatch the Reviewer automatically. Additive key, defaults to today’s always-on behavior.',
          default: true,
        },
      },
    },
    resolver: {
      type: 'object',
      additionalProperties: true,
      properties: {
        auto: { type: 'boolean', description: 'Auto Resolve: dispatch the Resolver automatically.', default: true },
        opt_out_label: { type: 'string', description: 'Label that opts an issue out of auto-resolve.' },
      },
    },
    checks: {
      type: 'object',
      additionalProperties: true,
      properties: {
        enabled: {
          type: 'boolean',
          description: 'Auto Checks: run the Developer’s build-layer verification loop.',
          default: false,
        },
        setup: { type: 'string', description: 'Shell command that prepares the toolchain before checks run.', default: '' },
        commands: {
          type: 'array',
          description: 'Ordered checks, each run from the repo root via `bash -c`.',
          items: {
            type: 'object',
            required: ['run'],
            additionalProperties: true,
            properties: {
              name: { type: 'string' },
              run: { type: 'string' },
            },
          },
          default: [],
        },
        git_hooks: {
          type: 'boolean',
          description: 'Run a discovered pre-commit hook as an implicit first check.',
          default: false,
        },
        max_iterations: {
          type: 'integer',
          minimum: 1,
          maximum: 10,
          description: 'Cap on additional Developer attempts against a failing check.',
          default: 3,
        },
      },
    },
    product: {
      type: 'object',
      additionalProperties: true,
      properties: {
        enabled: {
          type: 'boolean',
          description: 'Auto Groom: run the Product Owner’s scheduled backlog sweep.',
          default: true,
        },
        schedule: { type: 'string', description: 'Cron expression for the backlog sweep.', default: '0 9 * * *' },
        priority_backend: {
          type: 'string',
          enum: ['auto', 'project', 'labels', 'off'],
          description: 'Priority storage backend `/triage` uses.',
          default: 'auto',
        },
        project_number: {
          type: ['integer', 'null'],
          description: 'Pins the Projects v2 board by number when a repo links more than one.',
          default: null,
        },
        priority_field: {
          type: 'string',
          description: 'Projects v2 single-select field name that represents priority.',
          default: 'Priority',
        },
        auto_merge_duplicates: {
          type: 'boolean',
          description: 'Whether `/triage` proposes and applies duplicate-issue closes.',
          default: true,
        },
        max_closes_per_run: {
          type: 'integer',
          minimum: 0,
          description: 'Caps how many duplicates a single `/triage` sweep can close.',
          default: 5,
        },
        confidence_threshold: {
          type: 'string',
          enum: ['high', 'medium', 'low'],
          description: 'Minimum confidence a proposed duplicate group must carry to be applied.',
          default: 'high',
        },
        max_issues_per_run: {
          type: 'integer',
          minimum: 1,
          description: 'Caps how many open issues a full backlog sweep pulls into the inbox.',
          default: 100,
        },
        provisional_classification: {
          type: 'boolean',
          description: 'Whether `/triage` classifies un-classified issues with the Bug/Feature label.',
          default: true,
        },
      },
    },
    triggers: {
      type: 'object',
      description: 'Per-team custom trigger aliases, keyed by agent.',
      additionalProperties: {
        type: 'array',
        items: { type: 'string' },
      },
    },
    architect: {
      type: 'object',
      additionalProperties: true,
      properties: {
        auto: {
          type: 'boolean',
          description: 'Auto Spec: dispatch the Architect automatically. Additive key, defaults to today’s always-on behavior.',
          default: true,
        },
      },
    },
    engineer: {
      type: 'object',
      additionalProperties: true,
      properties: {
        auto: {
          type: 'boolean',
          description: 'Auto Plan: dispatch the Engineer automatically. Additive key, defaults to today’s always-on behavior.',
          default: true,
        },
      },
    },
    context: {
      type: 'object',
      description: 'Which context parts each agent is fed, keyed by agent.',
      additionalProperties: {
        type: 'object',
        additionalProperties: true,
        properties: {
          parts: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    review: {
      type: 'object',
      additionalProperties: true,
      properties: {
        security_guidelines: {
          type: 'string',
          description: 'Path to a repository-specific security guidelines file.',
          default: '.autoducks/security-guidelines.md',
        },
        auto_rework: {
          type: 'boolean',
          description: 'Auto Rework: dispatch a headless /rework round on a request-changes verdict.',
          default: true,
        },
        max_iterations: {
          type: 'integer',
          minimum: 1,
          maximum: 10,
          description: 'Caps automatic Review → Rework rounds before handing off to a human.',
          default: 3,
        },
      },
    },
    security: {
      type: 'object',
      additionalProperties: true,
      properties: {
        trusted_associations: { type: 'array', items: { type: 'string' } },
        allow: { type: 'array', items: { type: 'string' } },
        deny: { type: 'array', items: { type: 'string' } },
        codeowners: { type: 'boolean', default: false },
        per_agent: {
          type: 'object',
          description: 'Per-agent overrides of the top-level security policy, keyed by agent.',
          additionalProperties: {
            type: 'object',
            additionalProperties: true,
            properties: {
              trusted_associations: { type: 'array', items: { type: 'string' } },
            },
          },
        },
      },
    },
  },
} as const;
