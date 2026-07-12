import { spawn } from 'node:child_process';

export interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface RunOptions {
  /** Working directory for the subprocess (defaults to `process.cwd()`). */
  cwd?: string;
  /** Written to the subprocess's stdin, if given. */
  input?: string;
  /**
   * Argument *values* (not flags) that must never appear in debug logging,
   * e.g. a secret being passed to `gh secret set`. Matched by exact value.
   */
  redact?: string[];
}

export interface GhRunOptions extends RunOptions {
  /** Target repository, honored via `gh`'s `-R/--repo` global flag. */
  repo?: string;
}

/**
 * Replaces any arg present in `redact` with a placeholder. Used both for
 * debug logging and exposed standalone so it can be unit-tested without
 * spawning a subprocess.
 */
export function redactArgs(args: string[], redact: string[] = []): string[] {
  if (redact.length === 0) return args;
  const secrets = new Set(redact.filter((value) => value.length > 0));
  return args.map((arg) => (secrets.has(arg) ? '***' : arg));
}

/** Formats a command line for debug logging with secret values redacted. */
export function formatCommand(bin: string, args: string[], redact: string[] = []): string {
  return [bin, ...redactArgs(args, redact)].join(' ');
}

function debugLog(bin: string, args: string[], redact: string[] | undefined): void {
  if (!process.env.AUTODUCKS_DEBUG) return;
  console.error(`+ ${formatCommand(bin, args, redact)}`);
}

function execBin(bin: string, args: string[], options: RunOptions = {}): Promise<RunResult> {
  debugLog(bin, args, options.redact);

  return new Promise((resolve) => {
    const child = spawn(bin, args, { cwd: options.cwd });
    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    child.on('error', (err) => {
      resolve({ code: 1, stdout, stderr: stderr || String(err) });
    });
    child.on('close', (code) => {
      resolve({ code: code ?? 1, stdout, stderr });
    });

    if (options.input !== undefined) {
      child.stdin.write(options.input);
    }
    child.stdin.end();
  });
}

/** Runs `gh` with the given args, honoring `options.repo` via `-R`. */
export function gh(args: string[], options: GhRunOptions = {}): Promise<RunResult> {
  const finalArgs = options.repo ? ['-R', options.repo, ...args] : args;
  return execBin('gh', finalArgs, options);
}

/** Runs `git` with the given args. */
export function git(args: string[], options: RunOptions = {}): Promise<RunResult> {
  return execBin('git', args, options);
}

/** Detects the current repo (`OWNER/REPO`) via `gh repo view`, or undefined if not resolvable. */
export async function detectRepo(cwd?: string): Promise<string | undefined> {
  const result = await gh(['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'], { cwd });
  if (result.code !== 0) return undefined;
  const value = result.stdout.trim();
  return value.length > 0 ? value : undefined;
}
