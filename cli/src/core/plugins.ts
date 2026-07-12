import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { run } from './gh.js';

/** A single entry in the plugin marketplace index. */
export interface MarketplaceEntry {
  name: string;
  description: string;
  type: 'its' | 'git' | 'llm' | 'runtime' | 'agent';
  /** `OWNER/REPO` the bundle is downloaded from. */
  source: string;
  /** Pinned git ref/tag to install. */
  version: string;
  recommended?: boolean;
  /** Matcher: a comma-separated language/framework tag list, or an explicit `OWNER/REPO`. Absent matches every repo. */
  repos?: string;
}

/** Minimal, additive record of an installed plugin. */
export interface ManifestEntry {
  name: string;
  type: MarketplaceEntry['type'];
  source: string;
  version: string;
}

export interface PluginManifest {
  plugins: ManifestEntry[];
}

/** Root the whole plugin subsystem is scoped to — never write outside this tree (update-survival). */
export const PLUGINS_RELATIVE_DIR = path.join('.autoducks', 'custom', 'plugins');
export const MANIFEST_RELATIVE_PATH = path.join(PLUGINS_RELATIVE_DIR, 'manifest.json');
/** Bundled starter index, mirrored into every consumer by `install()` alongside the rest of `.autoducks/`. */
export const CURATED_INDEX_RELATIVE_PATH = path.join('.autoducks', 'core', 'plugins', 'marketplace.json');

export function resolvePluginsDir(cwd: string): string {
  return path.join(cwd, PLUGINS_RELATIVE_DIR);
}

export function resolveManifestPath(cwd: string): string {
  return path.join(cwd, MANIFEST_RELATIVE_PATH);
}

export function resolvePluginDir(cwd: string, name: string): string {
  return path.join(resolvePluginsDir(cwd), name);
}

/** Reads the manifest at `.autoducks/custom/plugins/manifest.json`, or an empty one if absent/invalid. */
export async function readManifest(cwd: string): Promise<PluginManifest> {
  try {
    const raw = await fs.readFile(resolveManifestPath(cwd), 'utf8');
    const parsed = JSON.parse(raw) as { plugins?: unknown };
    return { plugins: Array.isArray(parsed.plugins) ? (parsed.plugins as ManifestEntry[]) : [] };
  } catch {
    return { plugins: [] };
  }
}

/** Writes the manifest, creating `.autoducks/custom/plugins/` if needed. */
export async function writeManifest(cwd: string, manifest: PluginManifest): Promise<void> {
  const manifestPath = resolveManifestPath(cwd);
  await fs.mkdir(path.dirname(manifestPath), { recursive: true });
  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
}

// --- Marketplace index -------------------------------------------------

function isMarketplaceEntry(value: unknown): value is MarketplaceEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return (
    typeof entry.name === 'string' &&
    typeof entry.description === 'string' &&
    typeof entry.type === 'string' &&
    typeof entry.source === 'string' &&
    typeof entry.version === 'string'
  );
}

/** Parses a marketplace index JSON document (either a bare array or `{ plugins: [...] }`), dropping malformed entries. */
export function parseIndex(raw: string): MarketplaceEntry[] {
  const parsed = JSON.parse(raw) as unknown;
  const entries = Array.isArray(parsed) ? parsed : Array.isArray((parsed as { plugins?: unknown })?.plugins) ? (parsed as { plugins: unknown[] }).plugins : [];
  return entries.filter(isMarketplaceEntry);
}

/**
 * Loads the marketplace index. Honors the `AUTODUCKS_PLUGIN_INDEX` seam (an
 * absolute file path, used by tests/dev) exactly like `AUTODUCKS_SOURCE_DIR`;
 * otherwise reads the curated index bundled at
 * `.autoducks/core/plugins/marketplace.json`, which `install()` mirrors into
 * every consumer alongside the rest of `.autoducks/`.
 */
export async function fetchIndex(cwd: string = process.cwd()): Promise<MarketplaceEntry[]> {
  const override = process.env.AUTODUCKS_PLUGIN_INDEX;
  const indexPath = override ?? path.join(cwd, CURATED_INDEX_RELATIVE_PATH);
  const raw = await fs.readFile(indexPath, 'utf8');
  return parseIndex(raw);
}

// --- Bundle resolution ---------------------------------------------------

export interface PluginSourceHandle {
  /** Directory containing the plugin's files, ready to copy into `.autoducks/custom/plugins/<name>/`. */
  dir: string;
  /** Removes any temp directory created for this handle. No-op for the offline seam. */
  cleanup: () => Promise<void>;
}

/**
 * Resolves the directory tree to install a plugin bundle from. Honors the
 * `AUTODUCKS_PLUGIN_SOURCE_DIR` offline seam (a directory containing one
 * `<name>/` subdirectory per plugin, used by tests/dev) in place of
 * downloading; otherwise downloads and extracts the tarball for
 * `entry.source`@`entry.version` into a fresh temp dir the caller must clean up.
 */
export async function resolvePluginBundle(entry: MarketplaceEntry): Promise<PluginSourceHandle> {
  const override = process.env.AUTODUCKS_PLUGIN_SOURCE_DIR;
  if (override) {
    return { dir: path.join(override, entry.name), cleanup: async () => {} };
  }

  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'autoducks-plugin-'));
  await downloadAndExtract(entry, tmpDir);
  return { dir: tmpDir, cleanup: () => fs.rm(tmpDir, { recursive: true, force: true }) };
}

async function downloadAndExtract(entry: MarketplaceEntry, destDir: string): Promise<void> {
  const url = `https://api.github.com/repos/${entry.source}/tarball/${entry.version}`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download plugin '${entry.name}' from ${url}: ${response.status} ${response.statusText}`);
  }

  const tarballPath = path.join(destDir, 'bundle.tar.gz');
  await fs.writeFile(tarballPath, Buffer.from(await response.arrayBuffer()));
  try {
    const result = await run('tar', ['xz', '-f', tarballPath, '-C', destDir, '--strip-components=1']);
    if (result.code !== 0) {
      throw new Error(`Failed to extract plugin '${entry.name}': ${result.stderr}`);
    }
  } finally {
    await fs.rm(tarballPath, { force: true });
  }
}

// --- list ------------------------------------------------------------------

export type PluginState = 'installed' | 'available' | 'update-available';

export interface PluginListEntry {
  name: string;
  description: string;
  type: MarketplaceEntry['type'];
  state: PluginState;
  installedVersion?: string;
  latestVersion: string;
  recommended?: boolean;
}

/** Cross-references the installed manifest against the marketplace index: installed / available / update-available. */
export async function list(cwd: string, index: MarketplaceEntry[]): Promise<PluginListEntry[]> {
  const manifest = await readManifest(cwd);
  const installedByName = new Map(manifest.plugins.map((entry) => [entry.name, entry]));

  return index.map((entry) => {
    const installed = installedByName.get(entry.name);
    const state: PluginState = !installed ? 'available' : installed.version === entry.version ? 'installed' : 'update-available';
    return {
      name: entry.name,
      description: entry.description,
      type: entry.type,
      state,
      installedVersion: installed?.version,
      latestVersion: entry.version,
      recommended: entry.recommended,
    };
  });
}

// --- install / uninstall ----------------------------------------------------

export interface InstallOptions {
  cwd: string;
  entry: MarketplaceEntry;
  /** Already-resolved bundle directory (see `resolvePluginBundle`). */
  bundleDir: string;
}

export interface InstallResult {
  alreadyInstalled: boolean;
}

/**
 * Copies `bundleDir` into `.autoducks/custom/plugins/<name>/` (replacing any
 * existing copy) and records/updates the manifest entry. Idempotent:
 * re-installing the same entry converges to the same on-disk state.
 */
export async function install(opts: InstallOptions): Promise<InstallResult> {
  const { cwd, entry, bundleDir } = opts;
  const manifest = await readManifest(cwd);
  const alreadyInstalled = manifest.plugins.some((p) => p.name === entry.name);

  const destDir = resolvePluginDir(cwd, entry.name);
  await fs.rm(destDir, { recursive: true, force: true });
  await fs.mkdir(path.dirname(destDir), { recursive: true });
  await fs.cp(bundleDir, destDir, { recursive: true });

  const nextEntry: ManifestEntry = { name: entry.name, type: entry.type, source: entry.source, version: entry.version };
  const plugins = [...manifest.plugins.filter((p) => p.name !== entry.name), nextEntry];
  await writeManifest(cwd, { plugins });

  return { alreadyInstalled };
}

export interface UninstallResult {
  removed: boolean;
}

/** Removes `.autoducks/custom/plugins/<name>/` and its manifest entry. Idempotent: a no-op if not installed. */
export async function uninstall(cwd: string, name: string): Promise<UninstallResult> {
  const manifest = await readManifest(cwd);
  const wasInstalled = manifest.plugins.some((p) => p.name === name);

  await fs.rm(resolvePluginDir(cwd, name), { recursive: true, force: true });
  if (wasInstalled) {
    await writeManifest(cwd, { plugins: manifest.plugins.filter((p) => p.name !== name) });
  }

  return { removed: wasInstalled };
}

// --- install-recommended -----------------------------------------------------

/** Language/framework tags detected from marker files at the repo root. */
const LANGUAGE_MARKERS: Array<{ tag: string; files: string[] }> = [
  { tag: 'node', files: ['package.json'] },
  { tag: 'typescript', files: ['tsconfig.json'] },
  { tag: 'python', files: ['pyproject.toml', 'requirements.txt', 'setup.py'] },
  { tag: 'go', files: ['go.mod'] },
  { tag: 'rust', files: ['Cargo.toml'] },
  { tag: 'ruby', files: ['Gemfile'] },
  { tag: 'java', files: ['pom.xml', 'build.gradle'] },
];

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

/** Detects language/framework tags for `cwd` by probing well-known marker files at its root. */
export async function detectRepoTags(cwd: string): Promise<string[]> {
  const tags: string[] = [];
  for (const marker of LANGUAGE_MARKERS) {
    for (const file of marker.files) {
      if (await pathExists(path.join(cwd, file))) {
        tags.push(marker.tag);
        break;
      }
    }
  }
  return tags;
}

export interface RepoDetection {
  /** `OWNER/REPO`, if resolvable. */
  slug?: string;
  tags: string[];
}

/**
 * True when `matcher` (an entry's `repos` field) matches the detected repo:
 * absent matches everything; an explicit `OWNER/REPO` matches only that
 * repo; otherwise it's a comma-separated language/framework tag list and
 * matches if any detected tag is present.
 */
export function matchesRepo(matcher: string | undefined, detection: RepoDetection): boolean {
  if (!matcher) return true;
  if (matcher.includes('/')) return matcher === detection.slug;
  const wanted = matcher
    .split(',')
    .map((tag) => tag.trim().toLowerCase())
    .filter(Boolean);
  return wanted.some((tag) => detection.tags.includes(tag));
}

export interface InstallRecommendedOptions {
  cwd: string;
  index: MarketplaceEntry[];
  detection: RepoDetection;
  resolveBundle: (entry: MarketplaceEntry) => Promise<PluginSourceHandle>;
}

export interface RecommendedOutcome {
  name: string;
  reason: string;
}

export interface InstallRecommendedResult {
  selected: RecommendedOutcome[];
  skipped: RecommendedOutcome[];
}

/**
 * Installs every `recommended: true` marketplace entry whose `repos`
 * matcher matches the current repo. Every entry in the index is recorded as
 * either selected or skipped with a reason, so a selection is never silent.
 */
export async function installRecommended(opts: InstallRecommendedOptions): Promise<InstallRecommendedResult> {
  const selected: RecommendedOutcome[] = [];
  const skipped: RecommendedOutcome[] = [];

  const manifest = await readManifest(opts.cwd);
  const installedNames = new Set(manifest.plugins.map((p) => p.name));

  for (const entry of opts.index) {
    if (!entry.recommended) {
      skipped.push({ name: entry.name, reason: 'not marked recommended' });
      continue;
    }
    if (!matchesRepo(entry.repos, opts.detection)) {
      skipped.push({ name: entry.name, reason: `repos matcher '${entry.repos}' does not match this repo` });
      continue;
    }
    if (installedNames.has(entry.name)) {
      skipped.push({ name: entry.name, reason: 'already installed' });
      continue;
    }

    const bundle = await opts.resolveBundle(entry);
    try {
      await install({ cwd: opts.cwd, entry, bundleDir: bundle.dir });
      selected.push({ name: entry.name, reason: entry.repos ? `matches repos '${entry.repos}'` : 'recommended for all repos' });
    } finally {
      await bundle.cleanup();
    }
  }

  return { selected, skipped };
}
