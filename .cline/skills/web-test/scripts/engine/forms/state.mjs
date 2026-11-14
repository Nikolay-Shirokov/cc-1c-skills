// web-test engine/forms/state v1.17 — central form-state reader.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// getFormState — the canonical "what's on the screen right now" call. Combines:
//   1. DOM script (getFormStateScript) → form structure (fields, buttons, tables, openForms, ...)
//   2. checkForErrors → state.errors + state.confirmation hint
//   3. detectPlatformDialogs → state.platformDialogs (About / Support Info / Error Report)
//
// Returned by virtually every action-function as the "after" snapshot.

import { page, ensureConnected } from '../core/state.mjs';
import { getFormStateScript } from '../../dom.mjs';
import { checkForErrors, detectPlatformDialogs } from '../core/errors.mjs';

/** Read current form state. Single evaluate call via combined script. */
export async function getFormState() {
  ensureConnected();
  const state = await page.evaluate(getFormStateScript());
  const err = await checkForErrors();
  if (err) {
    state.errors = err;
    if (err.confirmation) {
      state.confirmation = err.confirmation;
      state.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
  }
  // Detect platform-level dialogs (About, Support Info, Error Report)
  // These are NOT 1C forms — invisible to detectForms() and not closeable via Escape.
  const pd = await detectPlatformDialogs();
  if (pd.length) state.platformDialogs = pd;
  return state;
}
