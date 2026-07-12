import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  checkActionsPermissions,
  checkGhAuth,
  checkGithubApp,
  checkIssueTypes,
  checkLabels,
  checkPublicRepoSecurity,
  checkReviewerRuleset,
  checkRuntimeSync,
  checkSecrets,
  checkSubIssuesApi,
  fixSecret,
  parseProgressLabels,
  requiredLabels,
  runAll,
  type CheckContext,
} from '../src/core/checks.js';

// gh shim: canned answers driven by env vars, plus an argv call log — the
// technique from test/unit-engineer-dor.sh, ported to a per-test scratch dir.
const GH_SHIM = `#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
input="$(cat)"

args=("$@")
if [[ "\${args[0]:-}" == "-R" ]]; then
  args=("\${args[@]:2}")
fi
set -- "\${args[@]}"

case "$1 $2" in
  "auth status")
    exit "\${GH_AUTH_CODE:-0}" ;;
  "label list")
    printf '%s\\n' "\${GH_LABELS:-}"
    exit 0 ;;
  "label create")
    name="$3"
    if [[ ",\${GH_LABEL_CREATE_FAIL:-}," == *",$name,"* ]]; then
      exit 1
    fi
    exit 0 ;;
  "secret list")
    printf '%s\\n' "\${GH_SECRETS:-}"
    exit 0 ;;
  "secret set")
    exit "\${GH_SECRET_SET_CODE:-0}" ;;
  "issue list")
    printf '%s\\n' "\${GH_FIRST_ISSUE:-}"
    exit 0 ;;
  "repo view")
    echo "\${GH_VISIBILITY:-PRIVATE}"
    exit 0 ;;
esac

if [[ "$1" == "api" ]]; then
  path="$2"
  case "$path" in
    repos/*/actions/permissions/workflow)
      if [[ "$*" == *"PUT"* ]]; then
        exit "\${GH_PERMS_PUT_CODE:-0}"
      fi
      printf '%s\\n' "\${GH_PERMS:-}"
      exit 0 ;;
    repos/*/installation)
      exit "\${GH_INSTALLATION_CODE:-1}" ;;
    repos/*/issues/*/sub_issues)
      printf 'HTTP/2.0 %s\\n\\n{}' "\${GH_SUBISSUES_HTTP:-200}"
      exit 0 ;;
    orgs/*/issue-types)
      if [[ -z "\${GH_ISSUE_TYPES_JSON:-}" ]]; then
        exit "\${GH_ISSUE_TYPES_CODE:-1}"
      fi
      printf '%s' "$GH_ISSUE_TYPES_JSON"
      exit 0 ;;
    repos/*/rulesets/*)
      exit "\${GH_RULESET_PUT_CODE:-0}" ;;
    repos/*/rulesets)
      if [[ "$*" == *"POST"* ]]; then
        exit "\${GH_RULESET_POST_CODE:-0}"
      fi
      printf '%s\\n' "\${GH_RULESET_EXISTING_ID:-}"
      exit 0 ;;
  esac
fi

exit 0
`;

const PROGRESS_LABELS_SH = `#!/usr/bin/env bash
AUTODUCKS_PROGRESS_LABELS=(
  "Design:draft|C5DEF5|Architect agent is drafting the design"
  "Design:done|1F6FEB|Design complete"
)

AUTODUCKS_MODE_LABELS=(
  "Mode:waves|BFDADC|Orchestrator: sequential fan-out of waves (default)"
)
`;

const WORKFLOW_YML = 'name: autoducks-example\non: workflow_dispatch\njobs: {}\n';

let scratch: string;
let repoDir: string;
let originalPath: string | undefined;
let ctx: CheckContext;

function writeAutoducksConfig(config: Record<string, unknown>): void {
  writeFileSync(join(repoDir, '.autoducks', 'autoducks.json'), JSON.stringify(config, null, 2));
}

function ghLog(): string {
  return readFileSync(join(scratch, 'gh.log'), 'utf8');
}

beforeEach(() => {
  scratch = mkdtempSync(join(tmpdir(), 'autoducks-checks-'));
  repoDir = join(scratch, 'repo');
  mkdirSync(join(repoDir, '.autoducks', 'core', 'feedback'), { recursive: true });
  mkdirSync(join(repoDir, '.autoducks', 'runtimes', 'github-actions'), { recursive: true });
  mkdirSync(join(repoDir, '.github', 'workflows'), { recursive: true });
  writeFileSync(join(repoDir, '.autoducks', 'core', 'feedback', 'progress-labels.sh'), PROGRESS_LABELS_SH);
  writeAutoducksConfig({ reviewer: { required_check: false }, defaults: { base_branch: 'main' } });
  writeFileSync(join(repoDir, '.autoducks', 'runtimes', 'github-actions', 'autoducks-example.yml'), WORKFLOW_YML);
  writeFileSync(join(repoDir, '.github', 'workflows', 'autoducks-example.yml'), WORKFLOW_YML);

  const bin = join(scratch, 'bin');
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, 'gh'), GH_SHIM, { mode: 0o755 });
  writeFileSync(join(scratch, 'gh.log'), '');

  originalPath = process.env.PATH;
  process.env.PATH = `${bin}:${originalPath ?? ''}`;
  process.env.GH_LOG = join(scratch, 'gh.log');

  ctx = { cwd: repoDir, repo: 'acme/widgets' };
});

afterEach(() => {
  process.env.PATH = originalPath;
  for (const key of Object.keys(process.env)) {
    if (key.startsWith('GH_')) delete process.env[key];
  }
  rmSync(scratch, { recursive: true, force: true });
});

describe('parseProgressLabels / requiredLabels', () => {
  it('sources exactly the static labels plus every progress/mode label entry', async () => {
    const parsed = parseProgressLabels(PROGRESS_LABELS_SH);
    expect(parsed).toEqual([
      { name: 'Design:draft', color: 'C5DEF5', description: 'Architect agent is drafting the design' },
      { name: 'Design:done', color: '1F6FEB', description: 'Design complete' },
      { name: 'Mode:waves', color: 'BFDADC', description: 'Orchestrator: sequential fan-out of waves (default)' },
    ]);

    const required = await requiredLabels(ctx);
    expect(required).toHaveLength(10 + 3);
    expect(required.map((l) => l.name)).toEqual([
      'Feature',
      'Bug',
      'Task',
      'Draft',
      'smoke-test',
      'Priority:Critical',
      'Priority:High',
      'Priority:Medium',
      'Priority:Low',
      'Duplicate',
      'Design:draft',
      'Design:done',
      'Mode:waves',
    ]);
  });
});

describe('checkGhAuth', () => {
  it('passes when gh is authenticated', async () => {
    const result = await checkGhAuth(ctx);
    expect(result).toEqual({ id: 'gh-auth', title: 'GitHub CLI authentication', status: 'pass', message: expect.any(String) });
  });

  it('fails (fatal) when gh is not authenticated', async () => {
    process.env.GH_AUTH_CODE = '1';
    const result = await checkGhAuth(ctx);
    expect(result.status).toBe('fail');
    expect(result.remediation).toContain('gh auth login');
  });
});

describe('checkLabels', () => {
  it('passes when every required label already exists', async () => {
    const required = await requiredLabels(ctx);
    process.env.GH_LABELS = required.map((l) => l.name).join('\n');
    const result = await checkLabels(ctx);
    expect(result.status).toBe('pass');
    expect(ghLog()).not.toContain('label create');
  });

  it('creates missing labels and passes', async () => {
    process.env.GH_LABELS = 'Feature\nBug';
    const result = await checkLabels(ctx);
    expect(result.status).toBe('pass');
    expect(ghLog()).toContain('label create Design:draft');
    expect(ghLog()).toContain('label create Mode:waves');
  });

  it('fails when a missing label cannot be created', async () => {
    process.env.GH_LABELS = '';
    process.env.GH_LABEL_CREATE_FAIL = 'Feature';
    const result = await checkLabels(ctx);
    expect(result.status).toBe('fail');
    expect(result.remediation).toContain('Feature');
  });
});

describe('checkSecrets', () => {
  it('is manual with a non-echoing remediation when ANTHROPIC_API_KEY is missing', async () => {
    process.env.GH_SECRETS = '';
    const result = await checkSecrets(ctx);
    expect(result.status).toBe('manual');
    expect(result.remediation).toContain('gh secret set ANTHROPIC_API_KEY');
  });

  it('passes and notes the optional org token when both secrets are set', async () => {
    process.env.GH_SECRETS = 'ANTHROPIC_API_KEY\nAUTODUCKS_ORG_TOKEN';
    const result = await checkSecrets(ctx);
    expect(result.status).toBe('pass');
    expect(result.message).toContain('AUTODUCKS_ORG_TOKEN is also set');
  });
});

describe('fixSecret', () => {
  it('never writes the secret value to the gh call log', async () => {
    const ok = await fixSecret(ctx, 'ANTHROPIC_API_KEY', 'sk-super-secret-value');
    expect(ok).toBe(true);
    expect(ghLog()).not.toContain('sk-super-secret-value');
    expect(ghLog()).toContain('secret set ANTHROPIC_API_KEY');
  });
});

describe('checkActionsPermissions', () => {
  it('passes on write + can-approve-PRs', async () => {
    process.env.GH_PERMS = 'write|true';
    const result = await checkActionsPermissions(ctx);
    expect(result.status).toBe('pass');
  });

  it('is manual with a PUT remediation otherwise', async () => {
    process.env.GH_PERMS = 'read|false';
    const result = await checkActionsPermissions(ctx);
    expect(result.status).toBe('manual');
    expect(result.remediation).toContain('-X PUT');
  });

  it('is manual when the permissions cannot be read at all', async () => {
    process.env.GH_PERMS = '';
    const result = await checkActionsPermissions(ctx);
    expect(result.status).toBe('manual');
  });
});

describe('checkGithubApp', () => {
  it('is manual by default (no public API confirms installation)', async () => {
    const result = await checkGithubApp(ctx);
    expect(result.status).toBe('manual');
    expect(result.remediation).toContain('https://github.com/apps/claude');
  });

  it('passes when the best-effort re-probe succeeds', async () => {
    process.env.GH_INSTALLATION_CODE = '0';
    const result = await checkGithubApp(ctx);
    expect(result.status).toBe('pass');
  });
});

describe('checkSubIssuesApi', () => {
  it('is a soft manual when the repo has no issues to probe', async () => {
    process.env.GH_FIRST_ISSUE = '';
    const result = await checkSubIssuesApi(ctx);
    expect(result.status).toBe('manual');
    expect(result.message).toContain('no issues to probe');
  });

  it('passes on a 2xx probe response', async () => {
    process.env.GH_FIRST_ISSUE = '42';
    process.env.GH_SUBISSUES_HTTP = '200';
    const result = await checkSubIssuesApi(ctx);
    expect(result.status).toBe('pass');
  });

  it('is manual on a 404 (feature not enabled)', async () => {
    process.env.GH_FIRST_ISSUE = '42';
    process.env.GH_SUBISSUES_HTTP = '404';
    const result = await checkSubIssuesApi(ctx);
    expect(result.status).toBe('manual');
    expect(result.message).toContain('404');
  });
});

describe('checkIssueTypes', () => {
  it('passes when Feature and Task exist in the org', async () => {
    process.env.GH_ISSUE_TYPES_JSON = JSON.stringify([{ name: 'Feature' }, { name: 'Task' }, { name: 'Bug' }]);
    const result = await checkIssueTypes(ctx);
    expect(result.status).toBe('pass');
  });

  it('is manual when a type is missing', async () => {
    process.env.GH_ISSUE_TYPES_JSON = JSON.stringify([{ name: 'Feature' }]);
    const result = await checkIssueTypes(ctx);
    expect(result.status).toBe('manual');
    expect(result.message).toContain('Task');
  });

  it('is manual (advisory) when org issue types cannot be listed at all', async () => {
    const result = await checkIssueTypes(ctx);
    expect(result.status).toBe('manual');
  });
});

describe('checkPublicRepoSecurity', () => {
  it('passes for a private repo without checking the config', async () => {
    process.env.GH_VISIBILITY = 'PRIVATE';
    const result = await checkPublicRepoSecurity(ctx);
    expect(result.status).toBe('pass');
  });

  it('is manual for a public repo with no security block', async () => {
    process.env.GH_VISIBILITY = 'PUBLIC';
    const result = await checkPublicRepoSecurity(ctx);
    expect(result.status).toBe('manual');
  });

  it('passes for a public repo that has a security block', async () => {
    process.env.GH_VISIBILITY = 'PUBLIC';
    writeAutoducksConfig({ security: { trusted_associations: ['OWNER'] } });
    const result = await checkPublicRepoSecurity(ctx);
    expect(result.status).toBe('pass');
  });
});

describe('checkRuntimeSync', () => {
  it('passes when every runtime is byte-identical to its mirror', async () => {
    const result = await checkRuntimeSync(ctx);
    expect(result.status).toBe('pass');
  });

  it('fails when a mirror is out of sync', async () => {
    writeFileSync(join(repoDir, '.github', 'workflows', 'autoducks-example.yml'), 'name: drifted\n');
    const result = await checkRuntimeSync(ctx);
    expect(result.status).toBe('fail');
    expect(result.message).toContain('out of sync');
  });

  it('fails when a mirror is missing entirely', async () => {
    rmSync(join(repoDir, '.github', 'workflows', 'autoducks-example.yml'));
    const result = await checkRuntimeSync(ctx);
    expect(result.status).toBe('fail');
    expect(result.message).toContain('missing');
  });
});

describe('checkReviewerRuleset', () => {
  it('is a no-op pass when reviewer.required_check is false', async () => {
    writeAutoducksConfig({ reviewer: { required_check: false } });
    const result = await checkReviewerRuleset(ctx);
    expect(result.status).toBe('pass');
    expect(ghLog()).toBe('');
  });

  it('creates the ruleset when required_check is true and none exists', async () => {
    writeAutoducksConfig({ reviewer: { required_check: true, check_name: 'Autoducks: Reviewer' }, defaults: { base_branch: 'main' } });
    process.env.GH_RULESET_EXISTING_ID = '';
    process.env.GH_RULESET_POST_CODE = '0';
    const result = await checkReviewerRuleset(ctx);
    expect(result.status).toBe('pass');
    expect(result.message).toContain('created');
    expect(ghLog()).toContain('--method POST');
  });

  it('updates the ruleset idempotently when one already exists', async () => {
    writeAutoducksConfig({ reviewer: { required_check: true }, defaults: { base_branch: 'main' } });
    process.env.GH_RULESET_EXISTING_ID = '99';
    process.env.GH_RULESET_PUT_CODE = '0';
    const result = await checkReviewerRuleset(ctx);
    expect(result.status).toBe('pass');
    expect(result.message).toContain('updated');
    expect(ghLog()).toContain('rulesets/99');
    expect(ghLog()).toContain('--method PUT');
  });

  it('is manual when the upsert fails (needs repo admin)', async () => {
    writeAutoducksConfig({ reviewer: { required_check: true }, defaults: { base_branch: 'main' } });
    process.env.GH_RULESET_EXISTING_ID = '';
    process.env.GH_RULESET_POST_CODE = '1';
    const result = await checkReviewerRuleset(ctx);
    expect(result.status).toBe('manual');
  });
});

describe('runAll', () => {
  it('short-circuits after a fatal gh-auth failure', async () => {
    process.env.GH_AUTH_CODE = '1';
    const results = await runAll(ctx);
    expect(results).toHaveLength(1);
    expect(results[0].id).toBe('gh-auth');
    expect(results[0].status).toBe('fail');
  });

  it('runs every check in order when gh-auth passes', async () => {
    process.env.GH_LABELS = (await requiredLabels(ctx)).map((l) => l.name).join('\n');
    process.env.GH_SECRETS = 'ANTHROPIC_API_KEY';
    process.env.GH_PERMS = 'write|true';
    process.env.GH_FIRST_ISSUE = '1';
    process.env.GH_SUBISSUES_HTTP = '200';
    process.env.GH_ISSUE_TYPES_JSON = JSON.stringify([{ name: 'Feature' }, { name: 'Task' }]);
    process.env.GH_VISIBILITY = 'PRIVATE';

    const results = await runAll(ctx);
    expect(results.map((r) => r.id)).toEqual([
      'gh-auth',
      'labels',
      'secrets',
      'actions-permissions',
      'github-app',
      'sub-issues-api',
      'issue-types',
      'public-repo-security',
      'runtime-sync',
      'reviewer-ruleset',
    ]);
    for (const result of results) {
      expect(result.id).toEqual(expect.any(String));
      expect(result.title).toEqual(expect.any(String));
      expect(['pass', 'fail', 'manual']).toContain(result.status);
      expect(result.message).toEqual(expect.any(String));
    }
  });
});
