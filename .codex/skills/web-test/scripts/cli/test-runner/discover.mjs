// web-test cli/test-runner/discover v1.1 — test file discovery + state reset between tests
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, readdirSync } from 'fs';
import { resolve } from 'path';

// Accepts a single path or an array of paths (files and/or dirs). Each .test.mjs file is
// taken directly; each directory is walked recursively (skipping _ / . prefixes). Results
// are deduped and sorted — sorting preserves the numeric-prefix order the suite relies on
// (00-, 01-, …) even when paths are listed out of order.
export function discoverTests(testPaths) {
  const paths = Array.isArray(testPaths) ? testPaths : [testPaths];
  const files = [];
  function walk(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('_') || entry.name.startsWith('.')) continue;
      const full = resolve(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.test.mjs')) files.push(full);
    }
  }
  for (const p of paths) {
    const full = resolve(p);
    if (full.endsWith('.test.mjs')) {
      if (existsSync(full)) files.push(full);
    } else if (existsSync(full)) {
      walk(full);
    }
  }
  return [...new Set(files)].sort();
}

export async function resetState(ctx) {
  try { if (typeof ctx.dismissPendingErrors === 'function') await ctx.dismissPendingErrors(); } catch {}
  for (let i = 0; i < 10; i++) {
    try {
      const state = await ctx.getFormState();
      // form === null means no form open (desktop). form === 0 is a real background form
      // 1C exposes in some states — must still close it to fully reset.
      if (state.form == null) break;
      await ctx.closeForm({ save: false });
    } catch { break; }
  }
}
