import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { gh, run } from './gh.js';

/** The autoducks source repo installs/updates are downloaded from — not the consumer's `--repo`. */
export const SOURCE_REPO = 'deepducks/autoducks';

export interface ResolveRefOptions {
  /** `--version` flag value, if the user passed one. */
  version?: string;
  /** True when the consumer has no `.autoducks/autoducks.json` yet. */
  freshInstall: boolean;
  /** The `version` field currently recorded in the consumer's autoducks.json (update path). */
  recordedVersion?: string;
}

export interface ResolvedRef {
  ref: string;
  /** True for `main`/`--edge`, which track the tip of main instead of a release tag. */
  tracksMain: boolean;
  warning?: string;
}

/**
 * Resolves the git ref to install: an explicit `--version` wins outright
 * (with `main`/`--edge` special-cased to skip release resolution); a fresh
 * install with no override takes the latest GitHub Release; an update with
 * no override keeps the recorded version; and if the source repo has no
 * releases at all, falls back to `main` with a warning.
 */
export async function resolveRef(opts: ResolveRefOptions): Promise<ResolvedRef> {
  if (opts.version) {
    if (opts.version === 'main' || opts.version === 'edge') {
      return { ref: 'main', tracksMain: true };
    }
    return { ref: opts.version, tracksMain: false };
  }

  if (!opts.freshInstall && opts.recordedVersion) {
    return { ref: opts.recordedVersion, tracksMain: false };
  }

  const latest = await fetchLatestReleaseTag();
  if (latest) {
    return { ref: latest, tracksMain: false };
  }

  return {
    ref: 'main',
    tracksMain: true,
    warning: `No releases found for ${SOURCE_REPO}; falling back to main.`,
  };
}

/** Fetches the latest release tag for the source repo, or undefined if there are no releases. */
export async function fetchLatestReleaseTag(): Promise<string | undefined> {
  const result = await gh(['release', 'view', '--json', 'tagName', '-q', '.tagName'], { repo: SOURCE_REPO });
  if (result.code !== 0) return undefined;
  const tag = result.stdout.trim();
  return tag.length > 0 ? tag : undefined;
}

export interface SourceHandle {
  /** Directory containing the extracted (or seamed) source tree, e.g. `<dir>/.autoducks`. */
  dir: string;
  /** Removes any temp directory created for this handle. No-op for the offline seam. */
  cleanup: () => Promise<void>;
}

/**
 * Resolves the directory tree to install from. Honors the
 * `AUTODUCKS_SOURCE_DIR` offline seam (used by tests and local development)
 * in place of downloading, exactly like `scripts/install.sh`; otherwise
 * downloads and extracts the tarball for `ref` into a fresh temp dir that
 * the caller must clean up.
 */
export async function resolveSourceDir(ref: string): Promise<SourceHandle> {
  const override = process.env.AUTODUCKS_SOURCE_DIR;
  if (override) {
    return { dir: override, cleanup: async () => {} };
  }

  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-source-'));
  await downloadAndExtract(ref, tmpDir);
  return { dir: tmpDir, cleanup: () => fs.rm(tmpDir, { recursive: true, force: true }) };
}

async function downloadAndExtract(ref: string, destDir: string): Promise<void> {
  const url = `https://api.github.com/repos/${SOURCE_REPO}/tarball/${ref}`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url}: ${response.status} ${response.statusText}`);
  }

  const tarballPath = path.join(destDir, 'source.tar.gz');
  await fs.writeFile(tarballPath, Buffer.from(await response.arrayBuffer()));
  try {
    const result = await run('tar', ['xz', '-f', tarballPath, '-C', destDir, '--strip-components=1']);
    if (result.code !== 0) {
      throw new Error(`Failed to extract tarball for ref "${ref}": ${result.stderr}`);
    }
  } finally {
    await fs.rm(tarballPath, { force: true });
  }
}
