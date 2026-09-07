// web-test forms/close v1.20 — Close current form via Escape, handle save-changes confirmation.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, recorder, ensureConnected } from '../core/state.mjs';
import { detectFormScript, closeCrossScript } from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors, detectPlatformDialogs, closePlatformDialogs } from '../core/errors.mjs';
import { waitForStable } from '../core/wait.mjs';
import { returnFormState } from '../core/helpers.mjs';
import { getFormState } from './state.mjs';

/**
 * Which button actually CLOSES the form on this confirmation?
 *
 * 1C asks two different questions with the same two buttons:
 *   «Данные были изменены. Сохранить изменения?» → Да = save+close, Нет = close without saving
 *   «Виза сохранена не будет. Закрыть согласование?» → Да = close, Нет = STAY IN THE FORM
 * A hard-coded «Нет» for save:false is right for the first and exactly backwards for the second:
 * the caller asks to close and gets a form that stays open (measured — that is how a modal leaked
 * into the next test).
 *
 * Decide by the QUESTION, not by the whole message: both texts contain the root «сохран», but only
 * the interrogative sentence says what the buttons mean. Unknown wording keeps the legacy answer.
 */
function pickConfirmationLabel(message, save) {
  const question = (String(message || '').match(/[^.!?]*\?/g) || []).pop() || '';
  if (/сохранит/i.test(question)) return save ? 'Да' : 'Нет';   // "…Сохранить изменения?"
  if (/закрыт/i.test(question)) return 'Да';                     // "…Закрыть согласование?" — Да = закрыть
  return save ? 'Да' : 'Нет';                                    // unknown → as before
}

/**
 * Close the current form/dialog: Escape first, the modal window cross if Escape does nothing.
 * @param {Object} [opts]
 * @param {boolean} [opts.save] - Handle a confirmation automatically. The button is chosen by the
 *   MEANING of the question (see pickConfirmationLabel), not by a fixed label:
 *   true  → save and close
 *   false → close without saving
 *   undefined → return confirmation as hint for caller to decide
 */
export async function closeForm({ save } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  // If platform dialogs are open, close them instead of pressing Escape
  const pd = await detectPlatformDialogs();
  if (pd.length) {
    await closePlatformDialogs();
    await page.waitForTimeout(300);
    return returnFormState({ closed: true, closedPlatformDialogs: pd });
  }
  const beforeForm = await page.evaluate(detectFormScript());
  await page.keyboard.press('Escape');
  await waitForStable(beforeForm);
  let state = await getFormState();
  let err = await checkForErrors();
  let usedCross = false;
  let nothingToClose = false;

  // Escape did nothing and raised no question. On a real stand that is the norm, not the exception:
  // Escape closed neither a modal nor even a plain list there. Fall back to the cross a human would
  // click. Only when nothing moved, so ordinary forms keep the cheap Escape path.
  if (!err?.confirmation && state.form === beforeForm) {
    const crossId = await page.evaluate(closeCrossScript());
    if (crossId) {
      await page.click(`#${crossId}`).catch(() => {});
      await waitForStable(beforeForm);
      state = await getFormState();
      err = await checkForErrors();
      usedCross = true;
    } else {
      // No cross anywhere: the platform itself says this surface is not closable — i.e. we are on
      // the desktop. This is what tells resetState "clean" without knowing anything about the
      // application: a home page with three forms on it looks exactly like an empty one here.
      nothingToClose = true;
    }
  }

  if (err?.confirmation) {
    if (save === true || save === false) {
      const label = pickConfirmationLabel(err.confirmation.message, save);
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
      const afterForm = await page.evaluate(detectFormScript());
      // Report which button was pressed: on a "…Закрыть?" question it is «Да» even for save:false,
      // and a silent surprise there is what cost the last investigation its afternoon.
      return returnFormState({ closed: afterForm !== beforeForm, confirmationAnswered: label, closedViaCross: usedCross || undefined });
    }
    state.confirmation = err.confirmation;
    state.hint = 'Confirmation dialog shown. Click "Да" to confirm or "Нет" to cancel';
    return state;
  }
  return returnFormState({
    closed: state.form !== beforeForm,
    closedViaCross: usedCross || undefined,
    nothingToClose: nothingToClose || undefined,
  });
}
