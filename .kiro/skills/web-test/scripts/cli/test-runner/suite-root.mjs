// web-test cli/test-runner/suite-root v1.0 — locate the suite root above a given test path
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, statSync } from 'fs';
import { resolve, dirname } from 'path';

// Files that MARK a suite root. Both count, not just the config: `webtest.config.mjs` is
// optional (a single-URL suite may pass --url= instead), and a suite that ships only
// `_hooks.mjs` must still be found — otherwise its stand preparation is silently skipped,
// which is worse than any URL error.
const MARKERS = ['webtest.config.mjs', '_hooks.mjs'];

// Files that BOUND the climb. A boundary never selects a root — it only stops the search,
// so a wrong boundary degrades to "root not found" (= the pre-v1.9 behaviour plus a clear
// message) and can never produce a wrong root. `package.json` is deliberately absent: it
// occurs nested and would stop the climb below a legitimate suite root.
const BOUNDARIES = ['.git', '.v8-project.json'];

const isDir = (p) => { try { return statSync(p).isDirectory(); } catch { return false; } };

/**
 * Walk up from `startPath` looking for a suite root.
 *
 * @param {string} startPath  A test file or directory (absolute or cwd-relative).
 * @param {{cwd?: string}} [opts]
 * @returns {{root: string, marker: string} | null} null when no marker was found within bounds.
 *
 * Stops after examining the first directory that contains `.git` / `.v8-project.json`
 * (that directory IS examined for markers), or — when neither is met — after examining `cwd`.
 * A path outside `cwd` degenerates to the filesystem root; the marker requirement still
 * makes a wrong hit unlikely, and the resolved root is printed in the run banner.
 */
export function findSuiteRoot(startPath, { cwd = process.cwd() } = {}) {
  const full = resolve(startPath);
  let dir = isDir(full) ? full : dirname(full);
  const cwdAbs = resolve(cwd);

  while (true) {
    for (const m of MARKERS) {
      if (existsSync(resolve(dir, m))) return { root: dir, marker: m };
    }
    const atBoundary = BOUNDARIES.some(b => existsSync(resolve(dir, b))) || dir === cwdAbs;
    const parent = dirname(dir);
    if (atBoundary || parent === dir) return null;
    dir = parent;
  }
}

/**
 * The directory a path contributes to root resolution — its own dir for a file, itself for
 * a directory. Also the fallback root when no marker is found (pre-v1.9 behaviour).
 */
export function startDirOf(testPath) {
  const full = resolve(testPath);
  return isDir(full) ? full : dirname(full);
}
