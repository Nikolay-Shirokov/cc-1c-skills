// web-test core/helpers v1.21 — private, cross-cutting helpers used by the
// public action functions (clickElement/fillFields/selectValue/etc).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page } from './state.mjs';
import { dismissPendingErrors, checkForErrors } from './errors.mjs';
import { getFormState } from '../forms/state.mjs';
import {
  detectNewFormScript,
  isInputFocusedScript,
  isInputFocusedInGridScript,
  findOpenPopupScript,
  readEddScript,
  isEddVisibleScript,
  clickEddItemViaDispatchScript,
  clickShowAllInEddScript,
} from '../../dom.mjs';

/**
 * page.click with the standard "intercepts pointer events" retry ladder:
 *   normal → force → Escape (+ optional dismissPendingErrors) → normal.
 * Mirrors the three hand-written copies in fillReferenceField, clickElement
 * and the DLB branch of selectValue.
 *
 * @param {string} selector
 * @param {object} [opts]
 * @param {number} [opts.timeout] — passed through to page.click
 * @param {boolean} [opts.dismissErrors=false] — call dismissPendingErrors()
 *   before pressing Escape on the second retry (used in fillReferenceField).
 */
export async function safeClick(selector, { timeout, dismissErrors = false } = {}) {
  const baseOpts = timeout != null ? { timeout } : {};
  try {
    await page.click(selector, baseOpts);
  } catch (e) {
    if (!e.message.includes('intercepts pointer events')) throw e;
    try {
      await page.click(selector, { ...baseOpts, force: true });
    } catch (e2) {
      if (!e2.message.includes('intercepts pointer events')) throw e2;
      if (dismissErrors) await dismissPendingErrors();
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
      await page.click(selector, baseOpts);
    }
  }
}

/**
 * Find a form field's input element id by name. Tries `form{N}_{name}` first,
 * then `form{N}_{name}_i0` (reference fields use the _i0 suffix). Returns the
 * element id or null. Used in selectValue's clear/composite-type/F4 fallback
 * branches.
 *
 * @param {number} formNum
 * @param {string} fieldName
 * @returns {Promise<string|null>}
 */
export async function findFieldInputId(formNum, fieldName) {
  return await page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const name = ${JSON.stringify(fieldName)};
    const el = document.querySelector('[id="' + p + name + '"], [id="' + p + name + '_i0"]');
    return el ? el.id : null;
  })()`);
}

/**
 * Detect a new form opened above the given `prevFormNum`. Two modes:
 *   `{ strict: true }`  — only counts visible interactive elements
 *     (`input.editInput[id], a.press[id]`); used by fillReferenceField.
 *   default (broad)     — any element with `id^=form{N}_` that's visible
 *     in either dimension; also finds type-dialogs whose a.press buttons
 *     have empty IDs. Used by selectValue / fillTableRow.
 *
 * @param {number} prevFormNum
 * @param {object} [opts]
 * @param {boolean} [opts.strict=false]
 * @returns {Promise<number|null>} new form number or null
 */
export async function detectNewForm(prevFormNum, { strict = false } = {}) {
  return page.evaluate(detectNewFormScript(prevFormNum, { strict }));
}

/**
 * Thin wrapper: is the currently focused element an INPUT (or TEXTAREA)?
 *
 * @param {object} [opts]
 * @param {boolean} [opts.allowTextarea=false]
 */
export async function isInputFocused({ allowTextarea = false } = {}) {
  return page.evaluate(isInputFocusedScript({ allowTextarea }));
}

/**
 * Thin wrapper: is the currently focused INPUT/TEXTAREA inside a `.grid`?
 * Used to verify grid edit-mode. Pass `{ gridSelector }` to scope the check
 * to a specific grid (when a form has multiple grids).
 */
export async function isInputFocusedInGrid({ gridSelector } = {}) {
  return page.evaluate(isInputFocusedInGridScript(gridSelector));
}

/**
 * Thin wrapper: is calculator (`.calculate`) or calendar (`.frameCalendar`)
 * popup visible? Returns `'calculator' | 'calendar' | null`.
 */
export async function findOpenPopup() {
  return page.evaluate(findOpenPopupScript());
}

/**
 * Read the `#editDropDown` autocomplete popup. Returns whether it's visible
 * and, when visible, an array of `.eddText` items with display name and
 * center coordinates (suitable for page.mouse.click).
 *
 * @returns {Promise<{visible: boolean, items?: Array<{name:string, x:number, y:number}>}>}
 */
export async function readEdd() {
  return page.evaluate(readEddScript());
}

/**
 * Thin wrapper: is the EDD popup currently visible?
 * Lighter than `readEdd` when only presence matters.
 */
export async function isEddVisible() {
  return page.evaluate(isEddVisibleScript());
}

/**
 * Click an EDD item by name via dispatchEvent (bypasses div.surface overlays).
 * Returns the clicked item's innerText, or `null` if no match.
 */
export async function clickEddItemViaDispatch(itemName) {
  return page.evaluate(clickEddItemViaDispatchScript(itemName));
}

/**
 * Click the "Показать все" / "Show all" link in the EDD footer.
 * Returns boolean.
 */
export async function clickShowAllInEdd() {
  return page.evaluate(clickShowAllInEddScript());
}

/**
 * Standard "tail" of action functions: fetch current form state, attach
 * caller-specified extras (e.g. `{ clicked: {...} }`) and the result of
 * `checkForErrors()` if any. Returns the flat state object.
 *
 * Unifies ~15 hand-written copies in clickElement, selectValue, closeForm,
 * navigation functions, etc. Also closes R1/R2/R3 from the refactor plan —
 * any caller using this helper gets `state.errors` for free.
 *
 * @param {object} [extras] — merged into the state object via Object.assign.
 * @returns {Promise<object>} form state (flat) with optional `errors`.
 */
export async function returnFormState(extras = {}) {
  const state = await getFormState();
  Object.assign(state, extras);
  const err = await checkForErrors();
  if (err) state.errors = err;
  return state;
}

/**
 * Mouse click at (x, y) with an optional modifier key held down for the duration.
 * Supports `'ctrl'` / `'shift'` (used by clickElement for multi-select).
 * Pass `{ dbl: true }` for double-click.
 */
export async function modifierClick(x, y, modifier, { dbl = false } = {}) {
  const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
  if (modKey) await page.keyboard.down(modKey);
  if (dbl) await page.mouse.dblclick(x, y);
  else await page.mouse.click(x, y);
  if (modKey) await page.keyboard.up(modKey);
}
