// web-test cli/exec-context v1.0 — buildContext + executeScript для run/exec/test
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { readFileSync, writeFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import * as browser from '../browser.mjs';
import { elapsed } from './util.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ERROR_SHOT_PATH = resolve(__dirname, '..', '..', 'error-shot.png');

/**
 * Build a per-context wrapper: same shape as buildContext output, but every call
 * is prefixed with `setActiveContext(name)` so the test can interleave actions
 * across contexts (`ctx.a.click(...); ctx.b.click(...)`).
 */
export function buildScopedContext(name) {
  const inner = buildContext({ noRecord: false });
  const scoped = {};
  for (const [k, v] of Object.entries(inner)) {
    if (typeof v === 'function') {
      scoped[k] = async (...args) => {
        await browser.setActiveContext(name);
        return v(...args);
      };
    } else {
      scoped[k] = v;
    }
  }
  return scoped;
}

export function buildContext({ noRecord = false } = {}) {
  const ctx = {};
  for (const [k, v] of Object.entries(browser)) {
    if (k !== 'default') ctx[k] = v;
  }
  ctx.writeFileSync = writeFileSync;
  ctx.readFileSync = readFileSync;

  // --no-record: stub recording/narration functions to return safe defaults
  if (noRecord) {
    const noop = async () => {};
    ctx.startRecording = noop;
    ctx.stopRecording = async () => ({ file: null, duration: 0, size: 0 });
    ctx.addNarration = async () => ({ file: null, duration: 0, size: 0, captions: 0 });
    for (const fn of ['showCaption', 'hideCaption']) {
      ctx[fn] = noop;
    }
    ctx.isRecording = () => false;
    ctx.getCaptions = () => [];
  }

  // Wrap action functions to auto-detect 1C errors (modal, balloon)
  // and stop execution immediately with diagnostic info
  const ACTION_FNS = [
    'clickElement', 'fillFields', 'fillField', 'selectValue', 'fillTableRow',
    'deleteTableRow', 'openCommand', 'navigateSection', 'navigateLink', 'openFile',
    'closeForm', 'filterList', 'unfilterList'
  ];
  for (const name of ACTION_FNS) {
    if (typeof ctx[name] !== 'function') continue;
    const orig = ctx[name];
    ctx[name] = async (...args) => {
      const result = await orig(...args);
      const errors = result?.errors;
      if (errors?.modal || errors?.balloon) {
        // Screenshot while the error modal is still visible (before fetchErrorStack closes it)
        let errorShot;
        try {
          const png = await ctx.screenshot();
          errorShot = ERROR_SHOT_PATH;
          writeFileSync(errorShot, png);
        } catch {}
        // Try to fetch call stack for modal errors before throwing
        let stack = null;
        if (errors?.modal && typeof ctx.fetchErrorStack === 'function') {
          try {
            stack = await ctx.fetchErrorStack(errors.modal.formNum, errors.modal.hasReport);
          } catch { /* don't fail if stack fetch fails */ }
        }
        const msg = errors.modal?.message || errors.balloon?.message || 'Unknown 1C error';
        const err = new Error(msg);
        err.onecError = { step: name, args, errors, formState: result, stack, screenshot: errorShot };
        throw err;
      }
      return result;
    };
  }

  return ctx;
}

export async function executeScript(code, { noRecord } = {}) {
  const output = [];
  const origLog = console.log;
  const origErr = console.error;
  console.log = (...a) => output.push(a.map(String).join(' '));
  console.error = (...a) => output.push('[ERR] ' + a.map(String).join(' '));

  const t0 = Date.now();
  try {
    const ctx = buildContext({ noRecord });

    // Normalize Windows backslash paths to prevent JS parse errors
    // (e.g. C:\Users\... → \u triggers "Invalid Unicode escape sequence")
    code = code.replace(/[A-Za-z]:\\[^\s'"`;\n)}\]]+/g, m => m.replace(/\\/g, '/'));

    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    const fn = new AsyncFunction(...Object.keys(ctx), code);
    await fn(...Object.values(ctx));

    console.log = origLog;
    console.error = origErr;
    return { ok: true, output: output.join('\n'), elapsed: elapsed(t0) };
  } catch (e) {
    console.log = origLog;
    console.error = origErr;

    // Auto-stop recording if active (prevents "Already recording" on next exec)
    if (browser.isRecording()) {
      try { await browser.stopRecording(); } catch {}
    }

    // Error screenshot (skip if already taken before fetchErrorStack closed the modal)
    let shotFile = e.onecError?.screenshot;
    if (!shotFile) {
      try {
        const png = await browser.screenshot();
        shotFile = ERROR_SHOT_PATH;
        writeFileSync(shotFile, png);
      } catch {}
    }

    const result = { ok: false, error: e.message, output: output.join('\n'), screenshot: shotFile, elapsed: elapsed(t0) };

    // Enrich with 1C error context if available
    if (e.onecError) {
      result.step = e.onecError.step;
      result.stepArgs = e.onecError.args;
      result.onecErrors = e.onecError.errors;
      result.formState = e.onecError.formState;
      if (e.onecError.stack) result.stack = e.onecError.stack;
    }

    return result;
  }
}
