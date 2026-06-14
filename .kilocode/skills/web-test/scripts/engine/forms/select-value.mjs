// web-test forms/select-value v1.24 — Reference & composite-type value selection: selectValue, fillReferenceField, selection/type-dialog pickers.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, ensureConnected, normYo, highlightMode, ACTION_WAIT,
} from '../core/state.mjs';
import {
  detectFormScript, findFieldButtonScript, resolveFieldsScript,
  readSubmenuScript, checkErrorsScript,
  findSearchInputScript, findNamedButtonScript, findCompareTypeRadioScript, isFormVisibleScript,
  findPatternInputIdScript, isTypeDialogScript, isNotInListCloudVisibleScript,
  findChildFormByButtonScript, readTypeDialogVisibleRowsScript,
} from '../../dom.mjs';
import { scanGridRowsScript } from '../../dom/grid.mjs';
import { dismissPendingErrors, checkForErrors } from '../core/errors.mjs';
import { waitForStable, waitForCondition } from '../core/wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import {
  safeClick, findFieldInputId, readEdd,
  detectNewForm as helperDetectNewForm,
  clickEddItemViaDispatch, clickShowAllInEdd, returnFormState,
} from '../core/helpers.mjs';
import { pasteText } from '../core/clipboard.mjs';
import { getFormState } from './state.mjs';
import { filterList } from '../table/filter.mjs';

/**
 * Scan visible grid rows for a text match (exact → startsWith → includes).
 * Returns center coords of the matched row, or null if not found.
 * When searchLower is empty, returns coords of the first row (fallback).
 */
async function scanGridRows(formNum, searchLower) {
  return page.evaluate(scanGridRowsScript(formNum, searchLower));
}

/**
 * Select a row in a selection form via click + Enter, verify it closed.
 * Uses click + Enter instead of dblclick because dblclick toggles
 * expand/collapse in tree-style selection forms.
 * Returns { field, ok: true, method: 'form' } on success,
 * or { field, ok: false, reason: 'still_open' } if the item couldn't be selected (e.g. group row).
 */
async function dblclickAndVerify(coords, selFormNum, fieldName) {
  // Click to highlight the row, then Enter to confirm selection.
  // This works for both flat grids and tree forms (dblclick would
  // toggle expand/collapse on tree group rows).
  await page.mouse.click(coords.x, coords.y);
  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');
  await waitForStable(selFormNum);

  // Verify selection form closed
  const stillOpen = await page.evaluate(isFormVisibleScript(selFormNum));
  if (stillOpen) {
    // Enter didn't select — item is likely a non-selectable group.
    // Don't Escape here — let the caller decide (may want to try another row).
    return { field: fieldName, ok: false, reason: 'still_open' };
  }

  // Check for 1C error modals after selection
  const err = await page.evaluate(checkErrorsScript());
  if (err?.modal) {
    try {
      const btn = await page.$('a.press.pressDefault');
      if (btn) { await btn.click(); await page.waitForTimeout(500); }
    } catch { /* OK */ }
  }
  return { field: fieldName, ok: true, method: 'form' };
}

/**
 * Inline advanced search on a selection form via Alt+F.
 * Does NOT click any column — FieldSelector auto-populates with main representation.
 * Switches to "по части строки" (CompareType#1) to avoid composite type issues.
 * Does not throw — returns silently on failure.
 */
async function advancedSearchInline(formNum, text) {
  try {
    // 1. Open advanced search via Alt+F
    await page.keyboard.press('Alt+f');
    await page.waitForTimeout(2000);

    const dialogForm = await page.evaluate(detectFormScript());
    if (dialogForm === formNum || dialogForm === null) return; // Alt+F didn't open dialog

    // 2. Switch to "по части строки" (CompareType#1)
    const radioClicked = await page.evaluate(findCompareTypeRadioScript(dialogForm, 1));
    if (radioClicked && !radioClicked.already) {
      await page.mouse.click(radioClicked.x, radioClicked.y);
      await page.waitForTimeout(300);
    }

    // 3. Fill Pattern field via clipboard paste
    const patternId = await page.evaluate(findPatternInputIdScript(dialogForm));
    if (!patternId) {
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      return;
    }
    await page.click(`[id="${patternId}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(300);

    // 4. Click "Найти"
    const findBtn = await page.evaluate(findNamedButtonScript('Найти'));
    if (findBtn) {
      await page.mouse.click(findBtn.x, findBtn.y);
      await page.waitForTimeout(2000);
    }

    // 5. Close advanced search dialog
    for (let attempt = 0; attempt < 3; attempt++) {
      const dialogVisible = await page.evaluate(isFormVisibleScript(dialogForm));
      if (!dialogVisible) break;
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
    }
    await waitForStable(formNum);
  } catch { /* silently fail — caller will re-scan and handle not_found */ }
}

/**
 * Pick a value from an opened selection form.
 *
 * Strategy (escalating):
 *   1. Scan visible rows for text match (exact → startsWith → includes)
 *   2. Advanced search (Alt+F, "по части строки") → re-scan
 *   3. Fallback: simple search (search input + Enter) → re-scan
 *   4. Not found → Escape → error
 *
 * For object search {field: value}: steps 1, then filterList(val, {field}) per entry, then re-scan.
 * For empty search: pick first visible row.
 *
 * @param {number} selFormNum - selection form number
 * @param {string} fieldName - field being filled (for error messages)
 * @param {string|Object} search - string for simple search, or { field: value } for per-field search
 * @param {number} origFormNum - original form number (to verify we returned)
 * @returns {{ field, ok, method }} or {{ field, error, message }}
 */
export async function pickFromSelectionForm(selFormNum, fieldName, search, origFormNum) {
  const searchText = typeof search === 'string'
    ? search : (search ? Object.values(search).join(' ') : '');
  const searchLower = normYo((searchText || '').toLowerCase());

  // Helper: try to select a row; returns result if ok, null if item wasn't selectable (group).
  let hadUnselectableMatch = false;
  async function trySelect(row) {
    const r = await dblclickAndVerify(row, selFormNum, fieldName);
    if (r.ok) return r;
    hadUnselectableMatch = true; // found match but couldn't select (possibly group row or overlay)
    return null; // form still open, try next step
  }

  // Step 1: Scan visible rows (no filtering)
  if (searchLower) {
    const row = await scanGridRows(selFormNum, searchLower);
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  // Step 2: Advanced search (Alt+F — fast, no overlay issues)
  if (typeof search === 'object' && search) {
    // Per-field advanced search via filterList(val, {field})
    for (const [fld, val] of Object.entries(search)) {
      try {
        await filterList(String(val), { field: fld });
      } catch (e) {
        // Re-throw programming errors (e.g. a missing import surfacing as
        // ReferenceError) — only field-filter failures (not found / unsupported
        // column) should be swallowed so we fall through to the re-scan.
        if (e instanceof ReferenceError || e instanceof TypeError) throw e;
        /* proceed */
      }
    }
  } else if (searchLower) {
    // Inline advanced search (Alt+F, "по части строки")
    await advancedSearchInline(selFormNum, searchText);
  }
  if (searchLower) {
    const row = await scanGridRows(selFormNum, searchLower);
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  // Step 3: Fallback — simple search via search input (for forms without Alt+F support)
  if (typeof search === 'string' && searchLower) {
    const searchInputInfo = await page.evaluate(findSearchInputScript(selFormNum));
    if (searchInputInfo) {
      try {
        await page.click(`[id="${searchInputInfo.id}"]`);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(searchText);
        await page.waitForTimeout(300);
        await page.keyboard.press('Enter');
        await waitForStable(selFormNum);
      } catch { /* proceed */ }
      const row = await scanGridRows(selFormNum, searchLower);
      if (row?.x) {
        const r = await trySelect(row);
        if (r) return r;
      }
    }
  }

  // Step 4: Empty search → pick first row; otherwise not found
  if (!searchLower) {
    const row = await scanGridRows(selFormNum, '');
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  await page.keyboard.press('Escape');
  await waitForStable();
  const searchDesc = typeof search === 'string' ? '"' + search + '"' : JSON.stringify(search);
  if (hadUnselectableMatch) {
    return { field: fieldName, error: 'not_selectable',
      message: 'Found ' + searchDesc + ' in selection form but it is not selectable (group/folder row)' };
  }
  return { field: fieldName, error: 'not_found',
    message: 'No matches in selection form for ' + searchDesc };
}

/**
 * Detect whether a form is a type selection dialog ("Выбор типа данных").
 * Type dialogs appear when selecting a value for a composite-type field.
 *
 * Detection signals (any one is sufficient):
 * - form{N}_OK element exists (selection forms use "Выбрать", not "OK")
 * - form{N}_ValueList grid exists (specific to type/value list dialogs)
 * - Window title contains "Выбор типа" (title attr on .toplineBoxTitle)
 */
export async function isTypeDialog(formNum) {
  return page.evaluate(isTypeDialogScript(formNum));
}

/**
 * Select a type from the type selection dialog ("Выбор типа данных")
 * using Ctrl+F search. The dialog has a virtual grid (~5 visible rows),
 * so Ctrl+F is the only reliable way to find a type.
 *
 * Algorithm: Ctrl+F → paste typeName → Enter (search) → Escape (close Find) →
 * verify selected row matches → Enter (OK)
 *
 * @param {number} formNum - type dialog form number
 * @param {string} typeName - type name to search for (fuzzy, e.g. "Реализация (акт")
 * @throws {Error} if type not found
 */
export async function pickFromTypeDialog(formNum, typeName) {
  // The type dialog is a modal ValueList grid.
  // Strategy: scan visible rows first (fast path), fall back to Ctrl+F for large lists.
  //
  // Key constraints discovered during testing:
  // - Grid focus: use evaluate(() => gridBody.focus()), NOT page.click({force:true})
  //   which punches through the modal overlay to the form underneath
  // - Ctrl+F only opens "Найти" if the GRID is focused (otherwise closes the type dialog)
  // - Buttons: use page.click({force:true}), NOT evaluate(() => el.click())
  //   because evaluate click doesn't trigger 1C's event chain properly
  // - Enter/Escape in "Найти" close the ENTIRE dialog chain, not just "Найти"
  // - Closing "Найти" via Cancel resets the search — verify grid while "Найти" is open

  const typeNorm = normYo(typeName.toLowerCase());

  // Helper: read visible rows and find matching ones
  async function readVisibleRows() {
    return page.evaluate(readTypeDialogVisibleRowsScript(formNum, typeNorm));
  }

  // Helper: dismiss the type-selection dialog (and any child "Найти") on error.
  // Escape closes the dialog chain, but a blind Escape×3 cascades into the underlying
  // form. So press Escape only while THIS type dialog is still present, then stop —
  // leaving the source form (and cell edit mode) for the caller to handle.
  async function dismissTypeDialog() {
    for (let i = 0; i < 4; i++) {
      const stillOpen = await page.evaluate(
        `!!document.getElementById('form${formNum}_OK') || !!document.getElementById('form${formNum}_ValueList')`);
      if (!stillOpen) break;
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
    }
  }

  // Exact-match preference: substring search can surface several types that merely CONTAIN the
  // requested name (e.g. "Контрагент" → "Банковская карта контрагента", "Договор с контрагентом",
  // …, "Контрагент"). Prefer the row equal to the requested name; only the absence of a single
  // exact match among multiple substring hits is a genuine ambiguity.
  function resolveExact(matches) {
    if (!matches || matches.length === 0) return null;
    if (matches.length === 1) return matches[0];
    const exact = matches.filter(m => normYo((m.text || '').toLowerCase()) === typeNorm);
    return exact.length === 1 ? exact[0] : null;
  }
  async function selectRowAndOk(row) {
    await page.mouse.click(row.x, row.y);
    await page.waitForTimeout(200);
    await page.click(`#form${formNum}_OK`, { force: true });
    await page.waitForTimeout(ACTION_WAIT);
  }
  // Focus the grid via evaluate (does NOT punch through the modal overlay like page.click).
  async function focusGrid() {
    await page.evaluate(`(() => {
      const grid = document.getElementById('form${formNum}_ValueList');
      if (!grid) return;
      const body = grid.querySelector('.gridBody');
      if (body) body.focus(); else grid.focus();
    })()`);
  }

  // Step 1: Scan visible rows (fast path — no Ctrl+F needed for small lists)
  const scan = await readVisibleRows();
  const scanPick = resolveExact(scan.matches);
  if (scanPick) { await selectRowAndOk(scanPick); return; }
  if (scan.matches.length > 1) {
    await dismissTypeDialog();
    await waitForStable();
    throw new Error(`selectValue: multiple types match "${typeName}": ${scan.matches.map(m => '"' + m.text + '"').join(', ')}. Specify a more precise type name`);
  }

  // Step 2: Not in visible rows — Ctrl+F jumps near the match in the large virtual list.
  await focusGrid();
  await page.waitForTimeout(300);

  // Ctrl+F to open "Найти" dialog
  await page.keyboard.press('Control+f');
  await page.waitForTimeout(1000);

  // Paste search text (focus is on "Что искать" field)
  await page.keyboard.press('Control+a');
  await pasteText(typeName);
  await page.waitForTimeout(300);

  // Find the "Найти" dialog form number (it's > formNum)
  const findFormNum = await page.evaluate(findChildFormByButtonScript(formNum, 'Find'));

  if (findFormNum === null) {
    await dismissTypeDialog();
    await waitForStable();
    throw new Error('selectValue: Ctrl+F did not open "Найти" dialog in type selection');
  }

  // Click "Найти" — search is client-side (no server round-trip)
  await page.click(`#form${findFormNum}_Find`, { force: true });

  // "Найти" positions at the first match; the exact row is at or just below it. Read, and if the
  // exact match is not yet in view, PageDown a few times (bounded) — virtualised grid, scrollTop
  // stays 0 but the visible window changes. Poll each window for matches to settle.
  let resolved = null, lastMatches = [], sawMatches = false;
  for (let pageStep = 0; pageStep <= 3; pageStep++) {
    if (pageStep > 0) { await focusGrid(); await page.keyboard.press('PageDown'); }
    let v = null;
    for (let w = 0; w < 5; w++) {
      await page.waitForTimeout(200);
      v = await readVisibleRows();
      if (v.matches.length) break;
    }
    if (v && v.matches.length) {
      sawMatches = true;
      lastMatches = v.matches;
      resolved = resolveExact(v.matches);
      if (resolved) break;
      // matches present but no single exact in this window — scroll to look just below
    } else if (sawMatches) {
      break; // scrolled past the matches without finding an exact one
    }
  }
  if (resolved) { await selectRowAndOk(resolved); return; }

  await dismissTypeDialog();
  await waitForStable();
  if (!sawMatches) {
    throw new Error(`selectValue: type "${typeName}" not found in type selection dialog` +
      `. Visible: ${(scan.visible || []).join(', ')}`);
  }
  throw new Error(`selectValue: multiple types match "${typeName}": ${lastMatches.map(m => '"' + m.text + '"').join(', ')}. Specify a more precise type name`);
}

/**
 * Fill a reference field via clipboard paste + 1C autocomplete.
 *
 * Strategy:
 *   1. Clear field if it has a value (Shift+F4 — native 1C mechanism, no JS errors)
 *   2. Clipboard paste text (Ctrl+V = trusted event, triggers real 1C autocomplete)
 *   3. Check editDropDown for autocomplete results → click match or Tab to resolve
 *   4. Verify result: resolved → ok, not found → clear + error
 *
 * Clipboard paste was chosen because:
 *   - Ctrl+V produces trusted browser events that 1C respects for autocomplete
 *   - page.fill() + synthetic keydown/keyup only triggers hints, not real search
 *   - keyboard.type() garbles Cyrillic on some fields
 *
 * @returns {{ field, ok?, method?, error?, value?, message?, available? }}
 */
export async function fillReferenceField(selector, fieldName, value, formNum) {
  const text = String(value);
  const escapedSel = selector.replace(/'/g, "\\'");

  // Helper: detect new forms opened above the current one (strict — interactive
  // elements only; fillReferenceField-specific)
  const detectNewForm = () => helperDetectNewForm(formNum, { strict: true });

  // Helper: clear the field using Shift+F4 (native 1C mechanism)
  async function clearField() {
    try {
      await page.click(selector, { timeout: 3000 });
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
    } catch { /* OK */ }
  }

  // Helper: check for "not in list" cloud popup (1C shows positioned div with "нет в списке")
  async function checkNotInListCloud() {
    return page.evaluate(isNotInListCloudVisibleScript());
  }

  // 0. Dismiss any leftover error modal from a previous operation
  await dismissPendingErrors();

  // 0a. Try DLB (DropListButton) first — works cleanly for combobox/enum fields
  //     and also for reference fields that show a dropdown.
  const inputId = selector.match(/\[id="(.+)"\]/)?.[1];
  // DLB button ID uses field name without _iN suffix (e.g. form1_Field_DLB, not form1_Field_i0_DLB)
  const dlbId = inputId.replace(/_i\d+$/, '') + '_DLB';
  const dlbSelector = `[id="${dlbId}"]`;
  try {
    const dlbVisible = await page.evaluate(`document.querySelector('${dlbSelector.replace(/'/g, "\\'")}')?.offsetWidth > 0`);
    if (dlbVisible) {
      await page.click(dlbSelector);
      await page.waitForTimeout(1000);
      const eddState = await readEdd();
      if (eddState.visible && eddState.items?.length > 0) {
        const target = normYo(text.toLowerCase());
        const candidates = eddState.items.filter(i => !i.name.startsWith('Создать'));
        let match = candidates.find(i => normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase()) === target);
        if (!match) match = candidates.find(i => normYo(i.name.toLowerCase()).includes(target));
        if (!match) match = candidates.find(i => {
          const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
          return name.includes(target) || target.includes(name);
        });
        if (match) {
          await page.mouse.click(match.x, match.y);
          await waitForStable();
          await dismissPendingErrors();
          return { field: fieldName, ok: true, method: 'dropdown',
            value: match.name.replace(/\s*\([^)]*\)\s*$/, '') };
        }
        // No match in DLB dropdown — close and fall through to paste approach
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      } else if (eddState.visible) {
        // DLB opened a hint popup (no .eddText items) — close it before proceeding
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
    }
  } catch { /* DLB approach failed — fall through to paste */ }

  // 1. Focus (handle surface/modal overlay from previous interaction)
  await safeClick(selector, { dismissErrors: true });

  // 2. If field already has a value, clear using Shift+F4 (native 1C mechanism).
  //    This is needed for reference fields — Shift+F4 properly clears the ref link.
  const currentVal = await page.evaluate(`document.querySelector('${escapedSel}')?.value || ''`);
  if (currentVal) {
    await page.keyboard.press('Shift+F4');
    await page.waitForTimeout(500);
    await page.keyboard.press('Tab');
    await page.waitForTimeout(500);
    // Refocus
    await page.click(selector);
  }

  // 3. Paste text via clipboard (trusted event → triggers real 1C autocomplete)
  await pasteText(text);
  await page.waitForTimeout(2000);

  // 4. Check editDropDown for autocomplete suggestions
  const eddState = await readEdd();

  if (eddState.visible && eddState.items?.length > 0) {
    const target = normYo(text.toLowerCase());
    // Separate real matches from "Создать:" items
    const candidates = eddState.items.filter(i => !i.name.startsWith('Создать'));

    if (candidates.length > 0) {
      // Find best match (items have format "Name (Code)" — match against name part)
      let match = candidates.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name === target;
      });
      if (!match) match = candidates.find(i => normYo(i.name.toLowerCase()).includes(target));
      if (!match) match = candidates.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name.includes(target) || target.includes(name);
      });

      if (match) {
        await page.mouse.click(match.x, match.y);
        await waitForStable();
        await dismissPendingErrors(); // business logic errors (e.g. СПАРК) may appear async
        return { field: fieldName, ok: true, method: 'dropdown',
          value: match.name.replace(/\s*\([^)]*\)\s*$/, '') };
      }
      // Candidates exist but none match — report them
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await clearField();
      return { field: fieldName, error: 'not_matched',
        available: candidates.map(i => i.name.replace(/\s*\([^)]*\)\s*$/, '')) };
    }

    // Only "Создать:" items — no existing matches
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'No existing values match "' + text + '"' };
  }

  // 4b. No edd — check for "not in list" cloud that may have appeared during paste
  if (await checkNotInListCloud()) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (not in list)' };
  }

  // 5. No edd at all — press Tab to trigger direct resolve
  await page.keyboard.press('Tab');
  await waitForStable();
  await dismissPendingErrors();

  // 5x. Check for "not in list" cloud popup after Tab
  if (await checkNotInListCloud()) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (not in list)' };
  }

  // 5a. New form opened? (creation form = value not found)
  const newForm = await detectNewForm();
  if (newForm !== null) {
    await page.keyboard.press('Escape');
    await waitForStable();
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found' };
  }

  // 5b. Dropdown after Tab?
  const popup = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popup) && popup.length > 0) {
    const realItems = popup.filter(i => !i.name.startsWith('Создать'));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    if (realItems.length > 0) {
      return { field: fieldName, error: 'ambiguous',
        message: 'Multiple matches for "' + text + '"',
        available: realItems.map(i => i.name.replace(/\s*\([^)]*\)\s*$/, '')) };
    }
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found' };
  }

  // 5c. Check final value
  const finalVal = await page.evaluate(`document.querySelector('${escapedSel}')?.value || ''`);
  if (!finalVal) {
    // 6. Last resort: try F4 to open selection form and pick from there
    try {
      await page.click(selector);
      await page.waitForTimeout(300);
    } catch { /* OK — field may be unfocused */ }
    await page.keyboard.press('F4');
    await page.waitForTimeout(ACTION_WAIT);

    const selFormNum = await detectNewForm();
    if (selFormNum !== null) {
      const pickResult = await pickFromSelectionForm(selFormNum, fieldName, text, formNum);
      if (pickResult.ok) return pickResult;
      // pickFromSelectionForm already closed the form on error
    }

    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (field is empty)' };
  }

  return { field: fieldName, ok: true, method: 'typeahead', value: finalVal };
}

/**
 * Select a value from a reference field (compound operation).
 * Handles three patterns:
 *   A) DLB opens an inline dropdown popup — click matching item
 *   B) DLB opens dropdown with history — click "Показать все" or F4 to open selection form
 *   C) DLB opens a separate selection form directly — search + dblclick in grid
 */
export async function selectValue(fieldName, searchText, { type } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error(`selectValue: no form found`);

  // Detect any new form opened above this one (broad — includes type dialogs).
  // Hoisted to the top so the composite-type branch can call it before its
  // original declaration site further below.
  const detectNewForm = () => helperDetectNewForm(formNum);

  // 1. Find DLB button (fallback to CB — ERP uses Choose Button instead of DLB for some fields)
  let btn = await page.evaluate(findFieldButtonScript(formNum, fieldName, 'DLB'));
  if (btn?.error === 'button_not_found') {
    btn = await page.evaluate(findFieldButtonScript(formNum, fieldName, 'CB'));
  }
  if (btn?.error) return btn;
  if (highlightMode) try { await highlight(fieldName); await page.waitForTimeout(500); await unhighlight(); } catch {}
  try {

  // === CLEAR FIELD if searchText is empty/null ===
  if (!searchText && searchText !== 0) {
    const inputId = await findFieldInputId(formNum, btn.fieldName);
    if (inputId) {
      await page.click(`[id="${inputId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await waitForStable();
    }
    if (highlightMode) try { await unhighlight(); } catch {}
    return returnFormState({ selected: { field: fieldName, search: null, method: 'clear' } });
  }

  // === COMPOSITE TYPE HANDLING ===
  // When `type` is specified, clear the field first to reset cached type,
  // then open type selection dialog, pick the type, then pick the value.
  if (type) {
    // Find and focus the field input
    const inputId = await findFieldInputId(formNum, btn.fieldName);
    if (!inputId) throw new Error(`selectValue: field "${btn.fieldName}" input not found`);

    // Clear cached type + value with Shift+F4
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
    await page.keyboard.press('Shift+F4');
    await page.waitForTimeout(500);

    // Re-focus and press F4 to open type selection dialog
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
    await page.keyboard.press('F4');
    await page.waitForTimeout(ACTION_WAIT);
    await waitForStable(formNum);

    const newFormNum = await detectNewForm();
    if (newFormNum === null) {
      throw new Error(`selectValue: F4 for composite field "${btn.fieldName}" did not open type selection dialog`);
    }

    if (await isTypeDialog(newFormNum)) {
      // Pick type from the dialog
      await pickFromTypeDialog(newFormNum, type);
      await waitForStable(newFormNum);

      // After type selection, the actual selection form should open
      const selFormNum = await detectSelectionForm();
      if (selFormNum === null) {
        throw new Error(`selectValue: after selecting type "${type}", no selection form opened for "${btn.fieldName}"`);
      }

      const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: searchText || null, type, method: 'form' };
      if (pickResult.error) state.selected.error = pickResult.error;
      if (pickResult.message) state.selected.message = pickResult.message;
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    } else {
      // Not a type dialog — field is not composite type, proceed with normal selection
      const pickResult = await pickFromSelectionForm(newFormNum, btn.fieldName, searchText || '', formNum);
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
      if (pickResult.error) state.selected.error = pickResult.error;
      if (pickResult.message) state.selected.message = pickResult.message;
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
  }
  // === END COMPOSITE TYPE HANDLING ===

  // Auto-enable DCS checkbox if resolved via label
  if (btn.dcsCheckbox) {
    const cbSel = `[id="${btn.dcsCheckbox.inputId}"]`;
    const isChecked = await page.$eval(cbSel, el =>
      el.classList.contains('checked') || el.classList.contains('checkboxOn') || el.classList.contains('select'));
    if (!isChecked) { await page.click(cbSel); await waitForStable(); }
  }

  // Helper: detect selection form (form number > formNum, strict mode)
  async function detectSelectionForm() {
    return helperDetectNewForm(formNum, { strict: true });
  }

  // detectNewForm is hoisted at the top of selectValue (see above).

  // Helper: open selection form and pick value
  async function openFormAndPick() {
    await waitForStable(formNum);
    const selFormNum = await detectSelectionForm();
    if (selFormNum !== null) {
      const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
      const selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
      if (pickResult.error) selected.error = pickResult.error;
      if (pickResult.message) selected.message = pickResult.message;
      return returnFormState({ selected });
    }
    return null;
  }

  // Locals → dom-scripts in helpers.mjs (see clickEddItemViaDispatch / clickShowAllInEdd)
  const clickEddItem = clickEddItemViaDispatch;
  const clickShowAll = clickShowAllInEdd;

  // 2. Click DLB (handle funcPanel / surface overlay intercept)
  const dlbSel = `[id="${btn.buttonId}"]`;
  await safeClick(dlbSel, { timeout: 5000 });
  await page.waitForTimeout(ACTION_WAIT);

  // 3A. Check if a dropdown popup appeared (inline quick selection)
  const popupItems = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popupItems) && popupItems.length > 0) {
    const regularItems = popupItems.filter(i => i.kind !== 'showAll');
    const showAllItem = popupItems.find(i => i.kind === 'showAll');

    if (searchText && typeof searchText !== 'string') {
      // Object search ({field: value}) can't be matched against dropdown item
      // text — close the typeahead popup and open the full selection form, which
      // handles per-field advanced search (pickFromSelectionForm → filterList).
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      const inputId = await findFieldInputId(formNum, btn.fieldName);
      if (inputId) { await page.click(`[id="${inputId}"]`); await page.waitForTimeout(300); }
      await page.keyboard.press('F4');
      await page.waitForTimeout(ACTION_WAIT);
      const formResult = await openFormAndPick();
      if (formResult) return formResult;
      throw new Error(`selectValue: object search ${JSON.stringify(searchText)} for "${btn.fieldName}" did not open a selection form`);
    }

    if (searchText) {
      const target = normYo(searchText.toLowerCase());
      // Try to find match among regular dropdown items
      let match = regularItems.find(i => normYo(i.name.toLowerCase()) === target);
      if (!match) match = regularItems.find(i => normYo(i.name.toLowerCase()).includes(target));
      if (!match) match = regularItems.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name === target || name.includes(target) || target.includes(name);
      });

      if (match) {
        // Click via evaluate to bypass div.surface overlay
        await clickEddItem(match.name);
        await waitForStable();
        return returnFormState({ selected: { field: btn.fieldName, search: searchText, method: 'dropdown' } });
      }

      // No match in dropdown — try "Показать все" to open selection form
      if (showAllItem) {
        await clickShowAll();
        const formResult = await openFormAndPick();
        if (formResult) return formResult;
      }

      // No "Показать все" — close dropdown, try F4
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);

      // Focus the field input and press F4 to open selection form
      const inputId = await findFieldInputId(formNum, btn.fieldName);
      if (inputId) {
        await page.click(`[id="${inputId}"]`);
        await page.waitForTimeout(300);
      }
      await page.keyboard.press('F4');
      await page.waitForTimeout(ACTION_WAIT);

      const formResult = await openFormAndPick();
      if (formResult) return formResult;

      // Still nothing — report available items from original dropdown
      throw new Error(`selectValue: "${searchText}" not found for field "${btn.fieldName}". Available: ${regularItems.map(i => i.name).join(', ') || 'none'}`);
    }

    // No search text — click first regular item
    if (regularItems.length > 0) {
      await clickEddItem(regularItems[0].name);
      await waitForStable();
      return returnFormState({ selected: { field: btn.fieldName, search: null, picked: regularItems[0].name, method: 'dropdown' } });
    }
  }

  // 3B. Check if a new selection form opened directly (use broad detection to also catch type dialogs)
  const selFormNum = await detectNewForm();
  if (selFormNum !== null) {
    // Auto-detect type selection dialog when `type` was not specified
    if (await isTypeDialog(selFormNum)) {
      await page.keyboard.press('Escape');
      await waitForStable();
      throw new Error(`selectValue: field "${btn.fieldName}" opened a type selection dialog — this is a composite-type field. Specify the type: selectValue('${btn.fieldName}', '${searchText || ''}', { type: 'ИмяТипа' })`);
    }
    const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
    const selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
    if (pickResult.error) selected.error = pickResult.error;
    if (pickResult.message) selected.message = pickResult.message;
    return returnFormState({ selected });
  }

  // 3C. Neither popup nor form — try F4 as last resort
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);

  const inputId = await findFieldInputId(formNum, btn.fieldName);
  if (inputId) {
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
  }
  await page.keyboard.press('F4');
  await page.waitForTimeout(ACTION_WAIT);

  const formResult = await openFormAndPick();
  if (formResult) return formResult;

  throw new Error(`selectValue: DLB click for "${btn.fieldName}" did not open a popup or selection form`);

  } finally { if (highlightMode) try { await unhighlight(); } catch {} }
}
