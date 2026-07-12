import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { CheckResult } from '../types.js';
import { detectRepo, gh } from './gh.js';

/** Where a check runs and, if already known, which repo it targets. */
export interface CheckContext {
  /** Root of the target consumer repo (defaults to `process.cwd()`). */
  cwd?: string;
  /** `OWNER/REPO`; resolved via `gh repo view` against `cwd` if omitted. */
  repo?: string;
}

interface LabelSpec {
  name: string;
  color: string;
  description: string;
}

/** Mirrors `scripts/setup.sh`'s static `LABELS` array (`scripts/setup.sh:78-87`). */
const STATIC_LABELS: LabelSpec[] = [
  { name: 'Feature', color: '6F42C1', description: 'Orchestration feature issue' },
  { name: 'Bug', color: 'D73A4A', description: 'Autoducks bug pipeline' },
  { name: 'Task', color: '1D76DB', description: 'Autoducks task issue' },
  { name: 'Draft', color: 'CCCCCC', description: 'Draft issue, not yet designed' },
  { name: 'smoke-test', color: 'FFA500', description: 'Smoke test marker' },
  { name: 'Priority:Critical', color: 'B60205', description: 'Autoducks triage priority: Critical' },
  { name: 'Priority:High', color: 'D93F0B', description: 'Autoducks triage priority: High' },
  { name: 'Priority:Medium', color: 'FBCA04', description: 'Autoducks triage priority: Medium' },
  { name: 'Priority:Low', color: '0E8A16', description: 'Autoducks triage priority: Low' },
  { name: 'Duplicate', color: 'CFD3D7', description: 'Closed as a duplicate of another issue' },
];

const RULESET_NAME = 'autoducks-reviewer-required';

interface AutoducksJsonConfig {
  reviewer?: { required_check?: boolean; check_name?: string };
  defaults?: { integration_branch?: string; base_branch?: string };
  security?: unknown;
}

function resolveCwd(ctx: CheckContext): string {
  return ctx.cwd ?? process.cwd();
}

/** Resolves `OWNER/REPO`, preferring an explicit `ctx.repo` over `gh repo view`. */
export async function resolveRepo(ctx: CheckContext): Promise<string | undefined> {
  if (ctx.repo) return ctx.repo;
  return detectRepo(ctx.cwd);
}

function failNoRepo(id: string, title: string): CheckResult {
  return {
    id,
    title,
    status: 'fail',
    message: 'Could not determine the target repository.',
    remediation: 'Pass --repo OWNER/REPO, or run inside a repository with a configured git remote.',
  };
}

async function readAutoducksConfig(ctx: CheckContext): Promise<AutoducksJsonConfig | undefined> {
  try {
    const raw = await readFile(join(resolveCwd(ctx), '.autoducks', 'autoducks.json'), 'utf8');
    return JSON.parse(raw) as AutoducksJsonConfig;
  } catch {
    return undefined;
  }
}

/**
 * Parses the `NAME|COLOR|DESCRIPTION` bash array entries out of
 * `progress-labels.sh` so its label set can never drift from this list.
 */
export function parseProgressLabels(source: string): LabelSpec[] {
  const extractEntries = (varName: string): string[] => {
    const match = source.match(new RegExp(`${varName}=\\(([\\s\\S]*?)\\n\\)`));
    if (!match) return [];
    return Array.from(match[1].matchAll(/"([^"]*)"/g)).map((m) => m[1]);
  };

  const toLabelSpecs = (entries: string[]): LabelSpec[] =>
    entries.map((entry) => {
      const [name, color, description] = entry.split('|');
      return { name, color, description };
    });

  return [...toLabelSpecs(extractEntries('AUTODUCKS_PROGRESS_LABELS')), ...toLabelSpecs(extractEntries('AUTODUCKS_MODE_LABELS'))];
}

/** The full required-label set: the static list plus every sourced progress/mode label. */
export async function requiredLabels(ctx: CheckContext): Promise<LabelSpec[]> {
  const scriptPath = join(resolveCwd(ctx), '.autoducks', 'core', 'feedback', 'progress-labels.sh');
  const source = await readFile(scriptPath, 'utf8');
  return [...STATIC_LABELS, ...parseProgressLabels(source)];
}

function parseGhList(stdout: string): Set<string> {
  return new Set(
    stdout
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean),
  );
}

/** Idempotent auto-fix for check 2: creates every label in `labels` that's missing. */
export async function fixLabels(
  ctx: CheckContext,
  repo: string,
  labels: LabelSpec[],
): Promise<{ created: string[]; failed: string[] }> {
  const created: string[] = [];
  const failed: string[] = [];
  for (const label of labels) {
    const result = await gh(['label', 'create', label.name, '--color', label.color, '--description', label.description], {
      cwd: ctx.cwd,
      repo,
    });
    if (result.code === 0) created.push(label.name);
    else failed.push(label.name);
  }
  return { created, failed };
}

// --- Check 1: gh CLI auth (fatal) -------------------------------------------

export async function checkGhAuth(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'gh-auth';
  const title = 'GitHub CLI authentication';
  const result = await gh(['auth', 'status'], { cwd: ctx.cwd });
  if (result.code === 0) {
    return { id, title, status: 'pass', message: 'gh CLI is authenticated.' };
  }
  return {
    id,
    title,
    status: 'fail',
    message: 'gh CLI is not authenticated.',
    remediation: 'gh auth login',
  };
}

// --- Check 2: required labels (auto-creates missing ones) ------------------

export async function checkLabels(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'labels';
  const title = 'Required labels';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const required = await requiredLabels(ctx);
  const listResult = await gh(['label', 'list', '--json', 'name', '--jq', '.[].name'], { cwd: ctx.cwd, repo });
  const existing = parseGhList(listResult.stdout);
  const missing = required.filter((label) => !existing.has(label.name));

  if (missing.length === 0) {
    return { id, title, status: 'pass', message: `All ${required.length} required labels exist.` };
  }

  const { created, failed } = await fixLabels(ctx, repo, missing);
  if (failed.length === 0) {
    return { id, title, status: 'pass', message: `Created missing labels: ${created.join(', ')}.` };
  }
  return {
    id,
    title,
    status: 'fail',
    message: `Failed to create labels: ${failed.join(', ')}.`,
    remediation: failed.map((name) => `gh label create "${name}" --repo ${repo}`).join('; '),
  };
}

// --- Check 3: ANTHROPIC_API_KEY secret (+ optional AUTODUCKS_ORG_TOKEN) ----

export async function checkSecrets(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'secrets';
  const title = 'Required secrets';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const listResult = await gh(['secret', 'list', '--json', 'name', '--jq', '.[].name'], { cwd: ctx.cwd, repo });
  const names = parseGhList(listResult.stdout);
  const hasKey = names.has('ANTHROPIC_API_KEY');
  const hasOrgToken = names.has('AUTODUCKS_ORG_TOKEN');
  const orgTokenNote = hasOrgToken
    ? 'Optional AUTODUCKS_ORG_TOKEN is also set.'
    : 'Optional AUTODUCKS_ORG_TOKEN is not set (only needed for team-based features).';

  if (!hasKey) {
    return {
      id,
      title,
      status: 'manual',
      message: `Secret ANTHROPIC_API_KEY is missing. ${orgTokenNote}`,
      remediation: `Get your API key from https://console.anthropic.com/, then run: gh secret set ANTHROPIC_API_KEY --repo ${repo}`,
    };
  }
  return { id, title, status: 'pass', message: `Secret ANTHROPIC_API_KEY is configured. ${orgTokenNote}` };
}

/** Sets a repo secret from `value` via stdin; the value is never passed as an argv arg. */
export async function fixSecret(ctx: CheckContext, name: string, value: string): Promise<boolean> {
  const repo = await resolveRepo(ctx);
  if (!repo) return false;
  const result = await gh(['secret', 'set', name], { cwd: ctx.cwd, repo, input: value, redact: [value] });
  return result.code === 0;
}

// --- Check 4: Actions workflow permissions ----------------------------------

export async function checkActionsPermissions(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'actions-permissions';
  const title = 'Actions workflow permissions';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const result = await gh(
    [
      'api',
      `repos/${repo}/actions/permissions/workflow`,
      '--jq',
      '.default_workflow_permissions + "|" + (.can_approve_pull_request_reviews | tostring)',
    ],
    { cwd: ctx.cwd },
  );
  const value = result.stdout.trim();

  if (result.code !== 0 || !value) {
    return { id, title, status: 'manual', message: 'Could not check workflow permissions (may need org admin).' };
  }
  if (value === 'write|true') {
    return { id, title, status: 'pass', message: 'Workflow permissions: write + can create PRs.' };
  }
  return {
    id,
    title,
    status: 'manual',
    message: `Workflow permissions are '${value}', expected 'write|true'.`,
    remediation: `gh api repos/${repo}/actions/permissions/workflow -X PUT -f default_workflow_permissions=write -F can_approve_pull_request_reviews=true`,
  };
}

/** Idempotent auto-fix for check 4: applies the write + auto-approve-PR permissions. */
export async function fixActionsPermissions(ctx: CheckContext): Promise<boolean> {
  const repo = await resolveRepo(ctx);
  if (!repo) return false;
  const result = await gh(
    [
      'api',
      `repos/${repo}/actions/permissions/workflow`,
      '-X',
      'PUT',
      '-f',
      'default_workflow_permissions=write',
      '-F',
      'can_approve_pull_request_reviews=true',
    ],
    { cwd: ctx.cwd },
  );
  return result.code === 0;
}

// --- Check 5: Claude Code GitHub App (confirmed-manual + best-effort re-probe) --

/** Best-effort probe for the app installation; no public API confirms this reliably. */
export async function reprobeGithubApp(ctx: CheckContext): Promise<boolean> {
  const repo = await resolveRepo(ctx);
  if (!repo) return false;
  const result = await gh(['api', `repos/${repo}/installation`], { cwd: ctx.cwd });
  return result.code === 0;
}

export async function checkGithubApp(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'github-app';
  const title = 'Claude Code GitHub App';
  const installed = await reprobeGithubApp(ctx);
  if (installed) {
    return { id, title, status: 'pass', message: 'Claude Code GitHub App appears to be installed.' };
  }
  return {
    id,
    title,
    status: 'manual',
    message: "Verify the Claude Code GitHub App is installed on this repository.",
    remediation: "Install at https://github.com/apps/claude, making sure 'All repositories' or this repo is selected.",
  };
}

// --- Check 6: sub-issues API availability -----------------------------------

export async function checkSubIssuesApi(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'sub-issues-api';
  const title = 'Sub-issues API availability';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const listResult = await gh(['issue', 'list', '--state', 'all', '--limit', '1', '--json', 'number', '--jq', '.[0].number // empty'], {
    cwd: ctx.cwd,
    repo,
  });
  const firstIssue = listResult.stdout.trim();
  if (!firstIssue) {
    return {
      id,
      title,
      status: 'manual',
      message: 'Sub-issues API check skipped — repository has no issues to probe.',
      remediation: "Re-run setup after your first issue exists, or trust the Engineer agent's runtime probe.",
    };
  }

  const probe = await gh(['api', `repos/${repo}/issues/${firstIssue}/sub_issues`, '--include', '-H', 'Accept: application/vnd.github+json'], {
    cwd: ctx.cwd,
  });
  const statusLine = probe.stdout.split('\n')[0] ?? '';
  const httpCode = statusLine.trim().split(/\s+/)[1] ?? '';

  if (/^2/.test(httpCode)) {
    return { id, title, status: 'pass', message: `Sub-issues API is available on ${repo}.` };
  }
  if (httpCode === '401' || httpCode === '403') {
    return {
      id,
      title,
      status: 'manual',
      message: `Sub-issues API responded ${httpCode}.`,
      remediation: "Token needs 'issues:write' scope.",
    };
  }
  if (httpCode === '404' || httpCode === '410') {
    return {
      id,
      title,
      status: 'manual',
      message: `Sub-issues API responded ${httpCode} — the feature is not enabled for this repository.`,
      remediation: "Not fatal: the Engineer agent falls back to the markdown-based '## Progress' checklist.",
    };
  }
  return { id, title, status: 'manual', message: `Sub-issues API probe was inconclusive (HTTP ${httpCode || 'none'}).` };
}

// --- Check 7: org issue types (advisory) ------------------------------------

export async function checkIssueTypes(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'issue-types';
  const title = 'Issue types (Feature, Task)';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const org = repo.split('/')[0];
  const result = await gh(['api', `orgs/${org}/issue-types`], { cwd: ctx.cwd });
  if (result.code !== 0 || !result.stdout.trim()) {
    return {
      id,
      title,
      status: 'manual',
      message: `Could not list issue types for org '${org}' (not an org, or no admin access).`,
      remediation: `Routing is label-first (Feature/Task labels are applied automatically); native issue types are a visual enhancement. If '${org}' is an org, ask an admin to define them at https://github.com/organizations/${org}/settings/issue-types.`,
    };
  }

  let names: string[] = [];
  try {
    const parsed = JSON.parse(result.stdout) as Array<{ name?: string }>;
    names = parsed.map((entry) => entry.name ?? '');
  } catch {
    names = [];
  }
  const missing = ['Feature', 'Task'].filter((name) => !names.includes(name));
  if (missing.length === 0) {
    return { id, title, status: 'pass', message: `Issue types 'Feature' and 'Task' exist in org '${org}'.` };
  }
  return {
    id,
    title,
    status: 'manual',
    message: `Missing issue types in org '${org}': ${missing.join(', ')}.`,
    remediation: `Create them at https://github.com/organizations/${org}/settings/issue-types. Workflows keep running without this.`,
  };
}

// --- Check 8: public-repo security posture (advisory) -----------------------

export async function checkPublicRepoSecurity(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'public-repo-security';
  const title = 'Public-repo security posture';
  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const visResult = await gh(['repo', 'view', repo, '--json', 'visibility', '--jq', '.visibility'], { cwd: ctx.cwd });
  const visibility = visResult.stdout.trim();
  if (visibility !== 'PUBLIC') {
    return {
      id,
      title,
      status: 'pass',
      message: `Repository visibility is '${visibility || 'unknown'}' — public security posture check does not apply.`,
    };
  }

  const config = await readAutoducksConfig(ctx);
  if (config?.security != null) {
    return { id, title, status: 'pass', message: 'security block present in .autoducks/autoducks.json.' };
  }
  return {
    id,
    title,
    status: 'manual',
    message: "Repository is PUBLIC but .autoducks/autoducks.json has no 'security' block.",
    remediation:
      'Defaults will allow only OWNER/MEMBER/COLLABORATOR to trigger agents. Review https://autoducks.openvibes.tech/reference/security/ to tighten or loosen.',
  };
}

// --- Check 9: runtime workflow sync ------------------------------------------

export async function checkRuntimeSync(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'runtime-sync';
  const title = 'Runtime workflow sync';
  const cwd = resolveCwd(ctx);
  const runtimeDir = join(cwd, '.autoducks', 'runtimes', 'github-actions');

  let entries: string[];
  try {
    entries = (await readdir(runtimeDir)).filter((name) => name.startsWith('autoducks-') && name.endsWith('.yml')).sort();
  } catch {
    return { id, title, status: 'fail', message: `Could not read runtime directory: ${runtimeDir}` };
  }

  const missing: string[] = [];
  const mismatched: string[] = [];
  for (const name of entries) {
    const targetPath = join(cwd, '.github', 'workflows', name);
    let targetContent: Buffer;
    try {
      targetContent = await readFile(targetPath);
    } catch {
      missing.push(name);
      continue;
    }
    const runtimeContent = await readFile(join(runtimeDir, name));
    if (!runtimeContent.equals(targetContent)) mismatched.push(name);
  }

  if (missing.length === 0 && mismatched.length === 0) {
    return { id, title, status: 'pass', message: `All ${entries.length} runtimes synced to .github/workflows/.` };
  }

  const problems = [
    ...missing.map((name) => `missing .github/workflows/${name}`),
    ...mismatched.map((name) => `out of sync: .github/workflows/${name}`),
  ];
  const remediation = [...missing, ...mismatched]
    .map((name) => `cp .autoducks/runtimes/github-actions/${name} .github/workflows/${name}`)
    .join(' && ');
  return { id, title, status: 'fail', message: problems.join('; '), remediation };
}

// --- Check 10: reviewer required-check ruleset (idempotent upsert) ----------

interface RulesetUpsertResult {
  ok: boolean;
  action: 'created' | 'updated';
}

/** Idempotent auto-fix for check 10: creates or updates the reviewer ruleset. */
export async function upsertReviewerRuleset(
  ctx: CheckContext,
  repo: string,
  opts: { checkName: string; gateBranch: string },
): Promise<RulesetUpsertResult> {
  const payload = JSON.stringify({
    name: RULESET_NAME,
    target: 'branch',
    enforcement: 'active',
    conditions: { ref_name: { include: [`refs/heads/${opts.gateBranch}`], exclude: [] } },
    rules: [
      {
        type: 'required_status_checks',
        parameters: {
          strict_required_status_checks_policy: false,
          required_status_checks: [{ context: opts.checkName }],
        },
      },
    ],
  });

  const listResult = await gh(['api', `repos/${repo}/rulesets`, '--jq', `.[] | select(.name=="${RULESET_NAME}") | .id`], {
    cwd: ctx.cwd,
  });
  const existingId = listResult.stdout.trim().split('\n')[0];

  if (existingId) {
    const putResult = await gh(['api', `repos/${repo}/rulesets/${existingId}`, '--method', 'PUT', '--input', '-'], {
      cwd: ctx.cwd,
      input: payload,
    });
    return { ok: putResult.code === 0, action: 'updated' };
  }

  const postResult = await gh(['api', `repos/${repo}/rulesets`, '--method', 'POST', '--input', '-'], {
    cwd: ctx.cwd,
    input: payload,
  });
  return { ok: postResult.code === 0, action: 'created' };
}

export async function checkReviewerRuleset(ctx: CheckContext = {}): Promise<CheckResult> {
  const id = 'reviewer-ruleset';
  const title = 'Reviewer required-check ruleset';
  const config = await readAutoducksConfig(ctx);
  const requiredCheck = config?.reviewer?.required_check === true;

  if (!requiredCheck) {
    return {
      id,
      title,
      status: 'pass',
      message: 'Reviewer required-check disabled (reviewer.required_check=false) — nothing to enforce.',
    };
  }

  const repo = await resolveRepo(ctx);
  if (!repo) return failNoRepo(id, title);

  const checkName = config?.reviewer?.check_name ?? 'Autoducks: Reviewer';
  const gateBranch = config?.defaults?.integration_branch ?? config?.defaults?.base_branch ?? 'main';
  const result = await upsertReviewerRuleset(ctx, repo, { checkName, gateBranch });

  if (result.ok) {
    return {
      id,
      title,
      status: 'pass',
      message: `Ruleset '${RULESET_NAME}' ${result.action} — '${checkName}' required on '${gateBranch}'.`,
    };
  }
  return {
    id,
    title,
    status: 'manual',
    message: `Could not ${result.action === 'created' ? 'create' : 'update'} the reviewer ruleset (needs repo admin).`,
    remediation: `Require the '${checkName}' status check on '${gateBranch}' via Settings → Rules, or re-run setup with an admin token.`,
  };
}

// --- runAll -------------------------------------------------------------

/**
 * Every check in order. Open-ended: append future setup checks here and
 * they're automatically picked up by `runAll()`.
 */
export const ALL_CHECKS: Array<(ctx: CheckContext) => Promise<CheckResult>> = [
  checkGhAuth,
  checkLabels,
  checkSecrets,
  checkActionsPermissions,
  checkGithubApp,
  checkSubIssuesApi,
  checkIssueTypes,
  checkPublicRepoSecurity,
  checkRuntimeSync,
  checkReviewerRuleset,
];

/** Runs every check in order; a `fail` on check 1 (gh auth) short-circuits the rest. */
export async function runAll(ctx: CheckContext = {}): Promise<CheckResult[]> {
  const results: CheckResult[] = [];
  for (const check of ALL_CHECKS) {
    const result = await check(ctx);
    results.push(result);
    if (result.id === 'gh-auth' && result.status === 'fail') break;
  }
  return results;
}
