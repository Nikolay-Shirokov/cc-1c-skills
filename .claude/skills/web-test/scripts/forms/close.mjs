// web-test forms/close v1.16 — Close current form via Escape, handle save-changes confirmation.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, recorder, ensureConnected } from '../core/state.mjs';
import { detectFormScript } from '../dom.mjs';
import { dismissPendingErrors, checkForErrors, _detectPlatformDialogs, _closePlatformDialogs } from '../core/errors.mjs';
import { waitForStable } from '../core/wait.mjs';
import { getFormState } from '../browser.mjs';

/**
 * Close the current form/dialog via Escape.
 * @param {Object} [opts]
 * @param {boolean} [opts.save] - Handle "Save changes?" confirmation automatically:
 *   true  → click "Да" (save and close)
 *   false → click "Нет" (discard and close)
 *   undefined → return confirmation as hint for caller to decide
 */
export async function closeForm({ save } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  // If platform dialogs are open, close them instead of pressing Escape
  const pd = await _detectPlatformDialogs();
  if (pd.length) {
    await _closePlatformDialogs();
    await page.waitForTimeout(300);
    const state = await getFormState();
    state.closed = true;
    state.closedPlatformDialogs = pd;
    return state;
  }
  const beforeForm = await page.evaluate(detectFormScript());
  await page.keyboard.press('Escape');
  await waitForStable(beforeForm);
  const state = await getFormState();
  const err = await checkForErrors();
  if (err?.confirmation) {
    if (save === true || save === false) {
      const label = save ? 'Да' : 'Нет';
      const btnSel = `#form${err.confirmation.formNum}_container a.press.pressButton`;
      const btns = await page.$$(btnSel);
      for (const b of btns) {
        const txt = (await b.textContent()).trim();
        if (txt === label) {
          if (recorder) await page.waitForTimeout(500); // show confirmation to viewer during recording
          await b.click({ force: true });
          await waitForStable(beforeForm);
          break;
        }
      }
      const afterState = await getFormState();
      afterState.closed = afterState.form !== beforeForm;
      return afterState;
    }
    state.confirmation = err.confirmation;
    state.hint = 'Confirmation dialog shown. Click "Да" to confirm or "Нет" to cancel';
    return state;
  }
  state.closed = state.form !== beforeForm;
  return state;
}
