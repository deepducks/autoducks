import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** Paths under `.autoducks/` the consumer owns and that must survive an update untouched. */
const CONSUMER_CONFIG = path.join('.autoducks', 'autoducks.json');
const CONSUMER_CLAUDE_SETTINGS = path.join('.autoducks', 'providers', 'llm', 'claude', 'settings.json');
const CONSUMER_CUSTOM_DIR = path.join('.autoducks', 'custom');

/** Same helper-script list `scripts/install.sh` copies into the consumer's `scripts/`. */
const SCRIPT_FILES = [
  'setup.sh',
  'install.sh',
  'update-triggers.sh',
  'smoke-test.sh',
  'smoke-test-plan.sh',
  'smoke-test-product.sh',
];

export interface InstallOptions {
  /** Consumer repo root. */
  cwd: string;
  /** Extracted source tree (or the `AUTODUCKS_SOURCE_DIR` seam) to install from. */
  sourceDir: string;
  /** Resolved tag/ref to record as the top-level `version` field. */
  version: string;
}

export interface InstallResult {
  freshInstall: boolean;
}

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

async function stash(from: string, into: string): Promise<void> {
  if (!(await pathExists(from))) return;
  await fs.mkdir(path.dirname(into), { recursive: true });
  await fs.cp(from, into, { recursive: true });
}

async function restore(from: string, into: string): Promise<void> {
  if (!(await pathExists(from))) return;
  await fs.rm(into, { recursive: true, force: true });
  await fs.mkdir(path.dirname(into), { recursive: true });
  await fs.cp(from, into, { recursive: true });
}

async function chmodShellScripts(dir: string): Promise<void> {
  if (!(await pathExists(dir))) return;
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await chmodShellScripts(full);
    } else if (entry.isFile() && entry.name.endsWith('.sh')) {
      await fs.chmod(full, 0o755);
    }
  }
}

/** True when the consumer has no `.autoducks/autoducks.json` yet (fresh install vs. update). */
export async function isFreshInstall(cwd: string): Promise<boolean> {
  return !(await pathExists(path.join(cwd, CONSUMER_CONFIG)));
}

/** Reads the `version` field currently recorded in the consumer's autoducks.json, if any. */
export async function readRecordedVersion(cwd: string): Promise<string | undefined> {
  try {
    const raw = await fs.readFile(path.join(cwd, CONSUMER_CONFIG), 'utf8');
    const config = JSON.parse(raw) as { version?: unknown };
    return typeof config.version === 'string' ? config.version : undefined;
  } catch {
    return undefined;
  }
}

async function writeVersion(configPath: string, version: string): Promise<void> {
  const raw = await fs.readFile(configPath, 'utf8');
  const config = JSON.parse(raw) as Record<string, unknown>;
  config.version = version;
  await fs.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
}

/**
 * Ports `scripts/install.sh`'s file operations: stash the three
 * consumer-owned paths, wholesale-replace `.autoducks/`, restore the
 * stashed paths, mirror runtime workflows into `.github/workflows/`, copy
 * issue templates and helper scripts, chmod all `.sh` files, and record the
 * resolved version. Never touches `.github/actions/` — that tree is
 * entirely consumer-owned (custom hooks).
 */
export async function install(opts: InstallOptions): Promise<InstallResult> {
  const freshInstall = await isFreshInstall(opts.cwd);
  const autoducksDir = path.join(opts.cwd, '.autoducks');

  const stashDir = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-stash-'));
  try {
    await stash(path.join(opts.cwd, CONSUMER_CONFIG), path.join(stashDir, 'autoducks.json'));
    await stash(path.join(opts.cwd, CONSUMER_CLAUDE_SETTINGS), path.join(stashDir, 'claude-settings.json'));
    await stash(path.join(opts.cwd, CONSUMER_CUSTOM_DIR), path.join(stashDir, 'custom'));

    await fs.rm(autoducksDir, { recursive: true, force: true });
    await fs.cp(path.join(opts.sourceDir, '.autoducks'), autoducksDir, { recursive: true });

    await restore(path.join(stashDir, 'autoducks.json'), path.join(opts.cwd, CONSUMER_CONFIG));
    await restore(path.join(stashDir, 'claude-settings.json'), path.join(opts.cwd, CONSUMER_CLAUDE_SETTINGS));
    await restore(path.join(stashDir, 'custom'), path.join(opts.cwd, CONSUMER_CUSTOM_DIR));
  } finally {
    await fs.rm(stashDir, { recursive: true, force: true });
  }

  // Mirror runtime workflow templates into .github/workflows/ (glob: autoducks-*.yml).
  const workflowsDir = path.join(opts.cwd, '.github', 'workflows');
  await fs.mkdir(workflowsDir, { recursive: true });
  const runtimeDir = path.join(autoducksDir, 'runtimes', 'github-actions');
  for (const file of await fs.readdir(runtimeDir)) {
    if (file.startsWith('autoducks-') && file.endsWith('.yml')) {
      await fs.copyFile(path.join(runtimeDir, file), path.join(workflowsDir, file));
    }
  }

  // Issue templates.
  const sourceIssueTemplates = path.join(opts.sourceDir, '.github', 'ISSUE_TEMPLATE');
  if (await pathExists(sourceIssueTemplates)) {
    const destIssueTemplates = path.join(opts.cwd, '.github', 'ISSUE_TEMPLATE');
    await fs.mkdir(destIssueTemplates, { recursive: true });
    for (const file of await fs.readdir(sourceIssueTemplates)) {
      await fs.copyFile(path.join(sourceIssueTemplates, file), path.join(destIssueTemplates, file));
    }
  }

  // Helper scripts (explicit list — dev-only scripts and the unit-test suite are never copied, #784).
  const scriptsDir = path.join(opts.cwd, 'scripts');
  await fs.mkdir(scriptsDir, { recursive: true });
  for (const file of SCRIPT_FILES) {
    const src = path.join(opts.sourceDir, 'scripts', file);
    if (await pathExists(src)) {
      await fs.copyFile(src, path.join(scriptsDir, file));
    }
  }

  await chmodShellScripts(scriptsDir);
  await chmodShellScripts(autoducksDir);

  await writeVersion(path.join(opts.cwd, CONSUMER_CONFIG), opts.version);

  return { freshInstall };
}
