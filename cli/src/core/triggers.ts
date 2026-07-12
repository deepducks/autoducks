import { promises as fs } from 'node:fs';
import path from 'node:path';
import { run, type RunResult } from './gh.js';

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

async function jqAvailable(): Promise<boolean> {
  const result = await run('jq', ['--version']);
  return result.code === 0;
}

/**
 * Bakes per-team custom trigger aliases into the workflow guards by
 * shelling out to the shipped `scripts/update-triggers.sh` — kept as the
 * single source of truth so trigger baking stays byte-identical whether
 * triggered by install/update or by the `config` command. Skipped (no-op)
 * when `jq` isn't installed, exactly like `scripts/install.sh`.
 */
export async function bakeTriggers(cwd: string): Promise<RunResult | undefined> {
  const scriptPath = path.join(cwd, 'scripts', 'update-triggers.sh');
  const configPath = path.join(cwd, '.autoducks', 'autoducks.json');

  if (!(await pathExists(configPath)) || !(await pathExists(scriptPath))) return undefined;
  if (!(await jqAvailable())) return undefined;

  return run('bash', [scriptPath], { cwd });
}
