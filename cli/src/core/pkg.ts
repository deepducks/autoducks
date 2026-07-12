import { promises as fs } from 'node:fs';
import { fileURLToPath } from 'node:url';

let cachedVersion: string | undefined;

/**
 * Reads the CLI's own `version` field from its `package.json`, resolved
 * relative to this module so it works identically whether running from
 * `src/` (tests) or the built `dist/` (both sit one level below the package
 * root, sibling to `package.json`).
 */
export async function getCliVersion(): Promise<string> {
  if (cachedVersion) return cachedVersion;
  const pkgPath = fileURLToPath(new URL('../../package.json', import.meta.url));
  const raw = await fs.readFile(pkgPath, 'utf8');
  const pkg = JSON.parse(raw) as { version?: string };
  cachedVersion = pkg.version ?? '0.0.0';
  return cachedVersion;
}
