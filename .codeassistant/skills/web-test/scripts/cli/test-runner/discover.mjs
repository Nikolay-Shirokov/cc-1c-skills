// web-test cli/test-runner/discover v1.4 — test file discovery + state reset between tests
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

/**
 * Return the context to a clean desktop between tests — and REPORT whether that worked.
 *
 * The verdict is the point. closeForm does not throw when a form refuses to close: it returns
 * `{closed:false}`, and this loop used to drop that on the floor, so a context with someone else's
 * modal still open went back into the pool as "clean" and the next test clicked into it. Measured
 * on the pilot's stand: 10 idle iterations, `closed:false` every time, state unchanged — and the
 * runner called it a success.
 *
 * @returns {Promise<{clean: boolean, attempts: number, form?: any, title?: string, modal?: boolean, lastError?: Error}>}
 *   `clean:false` also when the check itself failed — not being able to confirm is not being clean.
 */
export async function resetState(ctx) {
  try { if (typeof ctx.dismissPendingErrors === 'function') await ctx.dismissPendingErrors(); } catch {}
  let attempts = 0;
  let lastError = null;
  for (let i = 0; i < 10; i++) {
    try {
      const state = await ctx.getFormState();
      // form === null means no form open (desktop). form === 0 is a real background form
      // 1C exposes in some states — must still close it to fully reset.
      if (state.form == null) return { clean: true, attempts };
      attempts++;
      const r = await ctx.closeForm({ save: false });
      // The platform found nothing closable → this is the desktop, however many forms sit on it.
      // Without this the check would be "form == null", which is only true for an EMPTY desktop:
      // on a real application the home page keeps its own forms (measured: form=5, formCount=3,
      // no cross), so the old rule declared a perfectly clean context dirty after every test.
      if (r?.nothingToClose) return { clean: true, attempts, desktop: true };
      // Deliberately NOT bailing out on `closed:false`: measured A/B on the live suite — a dirty
      // «Приходная накладная *» reports closed:false on the first round and closes on a later one,
      // so an early exit aborted a context that was about to be clean. `closed` compares form
      // numbers, so an intermediate step (a popup going away) reads as "nothing happened" even
      // though progress was made. The verdict below judges the END state, which is what matters.
    } catch (e) { lastError = e; break; }
  }

  // Control check — the loop proves nothing on its own: it can also exit via `catch` above.
  try {
    const state = await ctx.getFormState();
    if (state.form == null) return { clean: true, attempts };
    return {
      clean: false, attempts, lastError,
      form: state.form,
      // state.title is the form's own caption; activeTab reads the open-windows panel, which the
      // user can switch off — keep it only as the fallback it always was.
      title: state.title || state.activeTab || null,
      modal: !!state.modal,
    };
  } catch (e) {
    return { clean: false, attempts, lastError: lastError || e };
  }
}
