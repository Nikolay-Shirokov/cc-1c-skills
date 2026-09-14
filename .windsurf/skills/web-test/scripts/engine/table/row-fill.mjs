// web-test table/row-fill v1.25 — fillTableRow — заполнение строки табличной части/списка через Tab-навигацию и попутный выбор значений.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, ensureConnected, normYo, highlightMode, ACTION_WAIT,
} from '../core/state.mjs';
import {
  detectFormScript, resolveGridScript, readTableScript,
  countGridRowsScript, isTreeGridScript, findGridHeadCenterCoordsScript,
  getSelectedOrLastRowIndexScript,
  isNotInListCloudVisibleScript, clickShowAllInNotInListCloudScript,
  sortFieldKeysByColindexScript, findCellCoordsByFieldsScript,
  findNextCellCoordsByKeyScript, findCheckboxAtPointScript,
  findRowCommitClickCoordsScript, getGridEditCheckScript,
  readActiveGridCellScript, getElementCenterCoordsByIdScript,
} from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors } from '../core/errors.mjs';
import { waitForStable, waitForCondition, startNetworkMonitor } from '../core/wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import {
  safeClick, findFieldInputId, returnFormState,
  detectNewForm as helperDetectNewForm,
  isInputFocused, isInputFocusedInGrid, findOpenPopup,
  readEdd, isEddVisible, clickEddItemViaDispatch,
} from '../core/helpers.mjs';
import { clickElement } from '../core/click.mjs';
import { resolveRowIndexByFilter } from './click-cell.mjs';
import {
  pickFromSelectionForm, isTypeDialog, pickFromTypeDialog,
  fillReferenceField, selectValue,
} from '../forms/select-value.mjs';
import { pasteText } from '../core/clipboard.mjs';

/**
 * Fill a choice cell (_CB iCB, buttonKind==='choice') whose INPUT is already focused.
 *
 * Two kinds of cell carry the same choice button and are INDISTINGUISHABLE in the DOM
 * (both `editInput`, readOnly:false):
 *   (a) editable value cell (Произвольный/примитив, РедактированиеТекста=Истина) — typed text sticks;
 *   (b) pick-from-list cell (НачалоВыбора / РедактированиеТекста=Ложь) — typed text is rejected.
 * The only reliable discriminator is behavioral: paste and watch the input value.
 *   stuck  → editable cell → leave value in the INPUT (caller's Tab/commit persists it), method 'direct';
 *   rejected → F4 → form: isTypeDialog ? pickFromTypeDialog ('choice') : pickFromSelectionForm ('form').
 *
 * Does NOT navigate between cells — caller owns Tab/dblclick/row-commit.
 *
 * @param {number} formNum base form number (for new-form detection)
 * @param {string} text value to fill
 * @param {Object} [opts]
 * @param {string|null} [opts.type] explicit type for composite/value-list pick
 * @param {string} [opts.fieldLabel] field name for diagnostics / selection-form search
 * @returns {{ ok, method, error?, message?, value? }}
 */
async function fillChoiceCell(formNum, text, { type = null, fieldLabel = '' } = {}) {
  const norm = (s) => normYo((s || '').toLowerCase());
  const before = await page.evaluate(`document.activeElement?.value || ''`);
  // Re-fill guard: cell already holds the target (paste wouldn't change it → false "rejected").
  if (before && norm(before).includes(norm(text))) {
    return { ok: true, method: 'skip', value: before };
  }
  // Paste, then poll. Three outcomes, distinguished BEHAVIORALLY (not by value equality):
  //   (1) EDD autocomplete appears   → reference/list cell → pick from the dropdown;
  //   (2) input changes to non-empty, no EDD → editable cell → leave value, method 'direct';
  //   (3) input unchanged (rejected) → НачалоВыбора pick-from-list → F4 selection form.
  // A value-equality check on `after` is UNRELIABLE: numeric/date masks reformat the pasted
  // text (grouping nbsp, decimal comma, padding) — e.g. "1234.56" → "1 234,56", "0,000"
  // baseline. So we test "did the input change to non-empty" + "no autocomplete", never
  // "does after contain text" (that false-negatives on reformatting → F4 → stray calculator).
  await pasteText(text, { confirm: ['Control+a', 'Control+v'] });
  let after = before, changed = false, eddSeen = false;
  for (let i = 0; i < 6; i++) {
    await page.waitForTimeout(100);
    if (await isEddVisible()) { eddSeen = true; break; }
    after = await page.evaluate(`document.activeElement?.value || ''`);
    if (after !== before && after !== '') changed = true;
  }

  if (eddSeen) {
    // Reference/list cell — pick a MATCHING item from the autocomplete. Only accept an
    // exact (parenthetical-stripped) or substring match; never blind-pick items[0] — for a
    // non-existent value 1C still lists unrelated entries, and picking the first silently
    // writes the wrong reference. No match → fall through to the F4 selection form, which
    // searches the full list and returns not_found if the value is truly absent.
    const edd = await readEdd();
    const items = (edd.items || []).map(i => i.name)
      .filter(i => !/^Создать[\s:]/.test(i) && !/не найдено/i.test(i) && !/показать все/i.test(i));
    const tgt = norm(text);
    const pick = items.find(i => norm(i.replace(/\s*\([^)]*\)\s*$/, '')) === tgt)
              || items.find(i => norm(i).includes(tgt));
    if (pick) {
      await clickEddItemViaDispatch(pick);
      await waitForStable();
      return { ok: true, method: 'dropdown', value: pick.replace(/\s*\([^)]*\)\s*$/, '') };
    }
    // No matching item — dismiss the autocomplete and fall through to the F4 selection form.
    await page.keyboard.press('Escape'); await page.waitForTimeout(200);
  } else if (changed) {
    // Editable cell — value lives in the INPUT; caller's Tab / end-of-row commit persists it.
    return { ok: true, method: 'direct', value: after };
  }

  // Text rejected (pick-from-list cell) — nothing typed to clear (field is not text-editable).
  // Dismiss any autocomplete hint, then open the choice form via F4.
  if (await isEddVisible()) { await page.keyboard.press('Escape'); await page.waitForTimeout(200); }
  await page.keyboard.press('F4');
  let choiceForm = null;
  for (let cw = 0; cw < 8; cw++) {
    await page.waitForTimeout(200);
    choiceForm = await helperDetectNewForm(formNum);
    if (choiceForm !== null) break;
  }
  if (choiceForm === null) {
    // F4 safety net: on an editable numeric/date cell mis-routed here, F4 opens a
    // calculator/calendar (NOT a selection form). Close it — never leave the popup open
    // (it blocks the UI) — and salvage: if the cell now holds a value, count it as 'direct'.
    if (await findOpenPopup()) {
      await page.keyboard.press('Escape');
      for (let dw = 0; dw < 4; dw++) { await page.waitForTimeout(150); if (!(await findOpenPopup())) break; }
      const nowVal = await page.evaluate(`document.activeElement?.value || ''`);
      if (nowVal && nowVal !== before) return { ok: true, method: 'direct', value: nowVal };
    }
    return { ok: false, error: 'no_selection_form', message: `Cell "${fieldLabel || text}": F4 did not open a choice form` };
  }
  if (await isTypeDialog(choiceForm)) {
    try {
      await pickFromTypeDialog(choiceForm, type || text);
    } catch (e) {
      return { ok: false, error: 'not_found', message: e.message };
    }
    await waitForStable(formNum);
    // A value form opened after the type pick → composite-value cell needs { value, type }.
    const valForm = await helperDetectNewForm(formNum);
    if (valForm !== null) {
      await page.keyboard.press('Escape'); await page.waitForTimeout(300);
      return { ok: false, error: 'type_required', message: `Cell "${fieldLabel || text}" expects { value, type }` };
    }
    return { ok: true, method: 'choice', value: text };
  }
  const pr = await pickFromSelectionForm(choiceForm, fieldLabel || text, text, formNum);
  return pr.ok ? { ok: true, method: 'form' } : { ok: false, error: pr.error, message: pr.message };
}

/**
 * Fill cells in the current table row via Tab navigation.
 * Grid cells are only accessible sequentially (Tab) — no random access.
 *
 * After "Добавить", 1C enters inline edit mode on the first cell.
 * All inputs in the row are created hidden (offsetWidth=0); only the active one is visible.
 * Tab moves through cells in a fixed order determined by the form configuration.
 *
 * @param {Object} fields - { fieldName: value } map (fuzzy match: "Номенклатура" → "ТоварыНоменклатура")
 * @param {Object} [options]
 * @param {string} [options.tab] - Switch to this form tab before operating
 * @param {boolean} [options.add] - Click "Добавить" to create a new row first
 * @param {number|Object} [options.row] - Edit existing row: 0-based DOM-window index, or
 *   a `{ col: value }` filter (one or more columns, AND-matched) to locate the row by cell values
 * @param {boolean|number} [options.scroll] - When `row` is a filter, scan beyond the current
 *   DOM window via PageDown (true = up to 50 presses, number = exact limit)
 * @returns {{ filled[], notFilled[]?, form }}
 */
export async function fillTableRow(fields, { tab, add, row, table, scroll } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('fillTableRow: no form found');

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`fillTableRow: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  try {
  // 1. Switch tab if requested
  if (tab) {
    await clickElement(tab);
  }

  // 1b. Resolve a { col: value } row filter to a numeric DOM-window index (mirrors
  // clickElement). After this, `row` is a number and all downstream code/recursion
  // works unchanged. Filter targets an EXISTING row — incompatible with `add`.
  if (row != null && typeof row === 'object') {
    row = await resolveRowIndexByFilter({ formNum, gridSelector, filter: row, gridName: table, scroll });
  }

  // 2. Add new row if requested
  let addedRowIdx = -1;
  if (add) {
    // Count rows before add — new row will be appended at this index
    addedRowIdx = await page.evaluate(countGridRowsScript(gridSelector));
    await clickElement('Добавить', { table });
    // Poll for edit mode (INPUT inside grid) instead of fixed 1000ms wait
    for (let aw = 0; aw < 6; aw++) {
      await page.waitForTimeout(150);
      if (await isInputFocusedInGrid()) break;
    }
  }

  // 2b. Enter edit mode on existing row by dblclick
  if (row != null) {
    // Sort fields by colindex (leftmost first) so Tab traversal covers all fields left-to-right
    const sortedKeys = await page.evaluate(
      sortFieldKeysByColindexScript(gridSelector, Object.keys(fields).map(k => k.toLowerCase())));
    if (sortedKeys) {
      // Rebuild fields in sorted order
      const sortedFields = {};
      for (const kl of sortedKeys) {
        const origKey = Object.keys(fields).find(k => k.toLowerCase() === kl);
        if (origKey) sortedFields[origKey] = fields[origKey];
      }
      // Add any keys not matched in header (preserve original order for those)
      for (const k of Object.keys(fields)) {
        if (!(k in sortedFields)) sortedFields[k] = fields[k];
      }
      fields = sortedFields;
    }

    const cellCoords = await page.evaluate(
      findCellCoordsByFieldsScript(gridSelector, row, Object.keys(fields).map(k => k.toLowerCase())));

    if (cellCoords.error) throw new Error(`fillTableRow: ${cellCoords.error}${cellCoords.total ? ' (total rows: ' + cellCoords.total + ')' : ''}`);

    // Skip if cell already contains the desired value (single-field optimization)
    const firstKey0 = Object.keys(fields)[0];
    const rawFirstVal = fields[firstKey0];
    const firstVal0 = rawFirstVal === null || rawFirstVal === undefined || rawFirstVal === ''
      ? '' : (typeof rawFirstVal === 'object' ? rawFirstVal.value : String(rawFirstVal));
    let firstFieldSkipped = false;
    if (cellCoords.currentText && firstVal0 &&
        cellCoords.currentText.toLowerCase().includes(firstVal0.toLowerCase())) {
      firstFieldSkipped = true;
      if (Object.keys(fields).length === 1) {
        return returnFormState({ filled: [{ field: firstKey0, ok: true, method: 'skip', value: cellCoords.currentText }] });
      }
    }

    // Checkbox cell? Detect BEFORE any click. Clicking the cell center toggles the
    // checkbox, so an unconditional click here would flip an already-correct value
    // (visible flicker + redundant write — снимаем→ставим). findCheckboxAtPoint reads
    // the state straight from the DOM (no edit mode needed), so we branch first and
    // click the icon only when the current state differs from the desired one.
    if (firstVal0 !== '') {
      const checkboxInfo = await page.evaluate(findCheckboxAtPointScript(cellCoords.x, cellCoords.y));
      if (checkboxInfo !== null) {
        const desired = ['true', 'да', '1', 'yes'].includes(String(firstVal0).toLowerCase().trim());
        if (checkboxInfo.checked !== desired) {
          await page.mouse.click(checkboxInfo.x, checkboxInfo.y);
          await page.waitForTimeout(300);
        }
        const results = [{ field: firstKey0, ok: true, method: 'toggle', value: desired }];
        await waitForStable(formNum);
        // If more fields remain, process them on the same row
        const remaining = { ...fields };
        delete remaining[firstKey0];
        if (Object.keys(remaining).length > 0) {
          const more = await fillTableRow(remaining, { row, table });
          results.push(...more.filled);
        }
        return returnFormState({ filled: results });
      }
    }

    // Click first (tree grids enter edit on single click; dblclick toggles expand/collapse).
    // Then escalate: dblclick → F4 if needed.
    await page.mouse.click(cellCoords.x, cellCoords.y);

    // Clear cell via Shift+F4 if value is empty
    if (firstVal0 === '') {
      await page.waitForTimeout(500);
      // Check if click opened a selection form — close it first
      let openedForm = await helperDetectNewForm(formNum);
      if (openedForm !== null) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
      } else {
        // No form opened — need to enter edit mode first (dblclick), then close any form that opens
        await page.mouse.dblclick(cellCoords.x, cellCoords.y);
        await page.waitForTimeout(500);
        openedForm = await helperDetectNewForm(formNum);
        if (openedForm !== null) {
          await page.keyboard.press('Escape');
          await page.waitForTimeout(500);
        }
      }
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      const results = [{ field: firstKey0, ok: true, method: 'clear', value: '' }];
      // If more fields remain, process them on the same row
      const remaining = { ...fields };
      delete remaining[firstKey0];
      if (Object.keys(remaining).length > 0) {
        const more = await fillTableRow(remaining, { row, table });
        results.push(...more.filled);
      }
      return returnFormState({ filled: results });
    }

    let inEdit = false;
    let directEditForm = null;
    for (let dw = 0; dw < 4; dw++) {
      await page.waitForTimeout(150);
      inEdit = await isInputFocused();
      if (inEdit) break;
      directEditForm = await helperDetectNewForm(formNum);
      if (directEditForm !== null) break;
    }
    // Click didn't enter edit — try dblclick (works for flat grids)
    if (!inEdit && directEditForm === null) {
      await page.mouse.dblclick(cellCoords.x, cellCoords.y);
      for (let dw = 0; dw < 4; dw++) {
        await page.waitForTimeout(150);
        inEdit = await isInputFocused();
        if (inEdit) break;
        directEditForm = await helperDetectNewForm(formNum);
        if (directEditForm !== null) break;
      }
    }
    // Still nothing — try F4 (opens selection for direct-edit cells)
    if (!inEdit && directEditForm === null) {
      await page.keyboard.press('F4');
      for (let fw = 0; fw < 8; fw++) {
        await page.waitForTimeout(200);
        inEdit = await isInputFocused();
        if (inEdit) break;
        directEditForm = await helperDetectNewForm(formNum);
        if (directEditForm !== null) break;
      }
    }

    // When click entered INPUT mode but no selection form yet — try F4 only for tree grids
    // (tree grid ref fields need F4 to open selection form; flat grids work via Tab-loop)
    if (inEdit && directEditForm === null) {
      const isTreeGrid = await page.evaluate(isTreeGridScript(gridSelector));
      if (isTreeGrid) {
        await page.keyboard.press('F4');
        for (let fw = 0; fw < 8; fw++) {
          await page.waitForTimeout(200);
          directEditForm = await helperDetectNewForm(formNum);
          if (directEditForm !== null) break;
        }
        // If F4 didn't open a selection form, fall through to Tab loop
      }
    }

    // Direct-edit mode: selection form opened on dblclick/F4 (e.g. tree grid with immediate editing).
    // Handle each field by picking from selection form, then dblclick next cell.
    if (directEditForm !== null) {
      const pending = new Map();
      for (const [key, val] of Object.entries(fields)) {
        if (val && typeof val === 'object' && 'value' in val) {
          pending.set(key, { value: String(val.value), type: val.type || null, filled: false });
        } else {
          pending.set(key, { value: String(val), type: null, filled: false });
        }
      }
      const results = [];

      // Helper: handle type dialog + pick from selection form
      async function directEditPick(openedForm, key, info) {
        let selForm = openedForm;
        // Check if opened form is a type selection dialog (composite type field)
        if (await isTypeDialog(selForm)) {
          if (info.type) {
            await pickFromTypeDialog(selForm, info.type);
            await waitForStable(selForm);
            // After type selection, detect the actual selection form
            selForm = await helperDetectNewForm(formNum);
            if (selForm === null) {
              return { field: key, ok: false, error: 'no_selection_after_type', message: `Type selected but no selection form opened for "${key}"` };
            }
          } else {
            // No type given — treat as a choice cell: the value IS the list item
            // ("Выбрать тип"). Pick it; if a value form follows, it was genuinely a
            // composite-value cell that needs {value, type}.
            try {
              await pickFromTypeDialog(selForm, info.value);
            } catch (e) {
              return { field: key, ok: false, error: 'not_found', message: e.message };
            }
            await waitForStable(formNum);
            const after = await helperDetectNewForm(formNum);
            if (after !== null) {
              await page.keyboard.press('Escape');
              await page.waitForTimeout(300);
              return { field: key, ok: false, error: 'type_required', message: `Cell "${key}" expects { value, type }` };
            }
            return { field: key, ok: true, method: 'choice' };
          }
        }
        const pr = await pickFromSelectionForm(selForm, key, info.value, formNum);
        return pr.ok ? { field: key, ok: true, method: 'form' } : { field: key, ok: false, error: pr.error, message: pr.message };
      }

      // First field: selection form is already open from the dblclick above
      const firstKey = Object.keys(fields)[0];
      const firstInfo = pending.get(firstKey);
      if (firstFieldSkipped) {
        firstInfo.filled = true;
        results.push({ field: firstKey, ok: true, method: 'skip', value: cellCoords.currentText });
        // Close the selection form that opened from the click
        await page.keyboard.press('Escape');
        await waitForStable(formNum);
      } else {
        const pickResult = await directEditPick(directEditForm, firstKey, firstInfo);
        firstInfo.filled = true;
        results.push(pickResult);
      }

      // Remaining fields: dblclick on each column cell individually
      for (const [key, info] of pending) {
        if (info.filled) continue;
        // Find column for this key and dblclick on it
        const nextCoords = await page.evaluate(findNextCellCoordsByKeyScript(gridSelector, row, key));
        if (!nextCoords) {
          info.filled = true;
          results.push({ field: key, ok: false, error: 'column_not_found', message: `Column for "${key}" not found` });
          continue;
        }
        // Skip if cell already contains the desired value
        if (nextCoords.currentText && info.value &&
            nextCoords.currentText.toLowerCase().includes(info.value.toLowerCase())) {
          info.filled = true;
          results.push({ field: key, ok: true, method: 'skip', value: nextCoords.currentText });
          continue;
        }
        await page.mouse.dblclick(nextCoords.x, nextCoords.y);
        await page.waitForTimeout(300);
        // Check if dblclick entered INPUT mode (plain text/numeric field) — before F4 which may open calculator
        const inInputAfterDblclick = await isInputFocusedInGrid();
        // Also check if a selection form already appeared
        let selForm = await helperDetectNewForm(formNum);
        if (selForm === null && inInputAfterDblclick) {
          // Choice cell (bare _CB iCB) — editable value (text sticks) or pick-from-list
          // (text rejected → F4 form). fillChoiceCell discriminates; row commit persists 'direct'.
          const activeCell = await page.evaluate(readActiveGridCellScript());
          if (activeCell.buttonKind === 'choice') {
            const r = await fillChoiceCell(formNum, info.value, { type: info.type, fieldLabel: key });
            info.filled = true;
            results.push(r.ok
              ? { field: key, ok: true, method: r.method, ...(r.value !== undefined ? { value: r.value } : {}) }
              : { field: key, ok: false, error: r.error, message: r.message });
            continue;
          }
          // Plain text/numeric field — fill via clipboard paste
          await pasteText(info.value, { confirm: ['Control+a', 'Control+v'] });
          await page.waitForTimeout(400);
          // Dismiss EDD autocomplete if it appeared
          if (await isEddVisible()) {
            await page.keyboard.press('Escape');
            await page.waitForTimeout(200);
          }
          info.filled = true;
          results.push({ field: key, ok: true, method: 'paste' });
          continue;
        }
        // Poll for selection form (with F4 fallback if dblclick didn't open it)
        if (selForm === null) {
          for (let attempt = 0; attempt < 2 && selForm === null; attempt++) {
            if (attempt === 1) await page.keyboard.press('F4'); // F4 fallback
            for (let sw = 0; sw < 6; sw++) {
              await page.waitForTimeout(200);
              selForm = await helperDetectNewForm(formNum);
              if (selForm !== null) break;
            }
          }
        }
        if (selForm === null) {
          info.filled = true;
          results.push({ field: key, ok: false, error: 'no_selection_form', message: `Dblclick on "${key}" did not open selection form` });
          continue;
        }
        const pr = await directEditPick(selForm, key, info);
        info.filled = true;
        results.push(pr);
      }
      // Commit the edit: click on a different row (Escape cancels in tree grids).
      // Find the first visible row that is NOT the edited row and click it.
      const commitCoords = await page.evaluate(findRowCommitClickCoordsScript(gridSelector, row));
      if (commitCoords) {
        await page.mouse.click(commitCoords.x, commitCoords.y);
      } else {
        await page.keyboard.press('Escape');
      }
      await waitForStable(formNum);
      return returnFormState({ filled: results });
    }

    if (!inEdit) throw new Error(`fillTableRow: click on row ${row} did not enter edit mode`);
  } else {
    // No row specified — verify we're in grid edit mode (active INPUT inside a .grid or .gridContent)
    const editCheck = await page.evaluate(getGridEditCheckScript());

    if (!editCheck.inEdit) {
      throw new Error('fillTableRow: not in grid edit mode. Use add:true or click a cell first.');
    }
  }

  // 4. Prepare pending fields for fuzzy matching
  const pending = new Map();
  for (const [key, val] of Object.entries(fields)) {
    if (val === null || val === undefined || val === '') {
      pending.set(key, { value: '', type: null, filled: false });
    } else if (val && typeof val === 'object' && 'value' in val) {
      const innerVal = val.value;
      pending.set(key, {
        value: innerVal === null || innerVal === undefined || innerVal === '' ? '' : String(innerVal),
        type: val.type || null, filled: false
      });
    } else {
      pending.set(key, { value: String(val), type: null, filled: false });
    }
  }

  const results = [];
  const MAX_ITER = 40;
  let prevCellId = null;
  let nonInputCount = 0;
  let firstCellId = null;

  for (let iter = 0; iter < MAX_ITER; iter++) {
    // All requested fields filled → stop. Без этого цикл табает дальше до wrap-around
    // (обходит остаток строки впустую): ветки заполнения по составному типу/примитиву
    // не выходили сами, что особенно заметно на широких строках (субконто/проводки).
    // Значение последнего поля к этому моменту уже зафиксировано (commit-Tab примитива,
    // выбор из формы, либо end-of-row commit для choice-ячейки).
    if ([...pending.values()].every(p => p.filled)) break;
    // Read focused element (INPUT or TEXTAREA inside grid = editable cell)
    const cell = await page.evaluate(readActiveGridCellScript());

    if (cell.tag !== 'INPUT' || !cell.fullName) {
      // Not in an editable grid cell — Tab past (ERP has DIV focus between cells)
      nonInputCount++;
      // If only checkbox fields remain unfilled, stop Tab'ing to avoid creating extra rows
      const onlyCheckboxLeft = [...pending.values()].every(p => p.filled ||
        ['true', 'false', 'да', 'нет', '1', '0', 'yes', 'no'].includes(p.value.toLowerCase().trim()));
      if (nonInputCount > 3 || onlyCheckboxLeft) break;
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
      continue;
    }
    nonInputCount = 0;

    // Track first cell to detect wrap-around (Tab looped back to row start)
    if (firstCellId === null) firstCellId = cell.id;
    else if (cell.id === firstCellId) break; // wrapped around — all cells visited

    // Stuck detection: same cell twice in a row → force Tab
    if (cell.id === prevCellId) {
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      prevCellId = null;
      continue;
    }
    prevCellId = cell.id;

    // Fuzzy match cell name to user field: exact → suffix → includes → no-space includes
    const cellLower = cell.fullName.toLowerCase();
    let matchedKey = null;
    for (const [key, info] of pending) {
      if (info.filled) continue;
      const kl = key.toLowerCase();
      if (cellLower === kl || cellLower.endsWith(kl) || cellLower.includes(kl)) {
        matchedKey = key;
        break;
      }
      // CamelCase cell names have no spaces/dashes — try matching without spaces and dashes
      const klNoSpace = kl.replace(/[\s\-]+/g, '');
      if (klNoSpace && (cellLower.endsWith(klNoSpace) || cellLower.includes(klNoSpace))) {
        matchedKey = key;
        break;
      }
    }

    // Fallback: match by column header text (handles metadata typos in cell id)
    if (!matchedKey && cell.headerText) {
      const htLower = cell.headerText.toLowerCase();
      for (const [key, info] of pending) {
        if (info.filled) continue;
        const kl = key.toLowerCase();
        if (htLower === kl || htLower.endsWith(kl) || htLower.includes(kl)) {
          matchedKey = key;
          break;
        }
      }
    }

    if (!matchedKey) {
      // Skip this cell
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
      continue;
    }

    const info = pending.get(matchedKey);
    const text = info.value;

    // Clear cell if value is empty (Shift+F4 = native 1C clear)
    if (text === '') {
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'clear', value: '' });
      if ([...pending.values()].every(p => p.filled)) break;
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // If user specified a type, always clear and use type selection flow
    if (info.type) {
      await page.keyboard.press('Shift+F4');  // Clear cell to reset any inherited type
      await page.waitForTimeout(300);
      await page.keyboard.press('F4');
      // Poll for type dialog form to appear
      let typeForm = null;
      for (let tw = 0; tw < 6; tw++) {
        await page.waitForTimeout(200);
        typeForm = await helperDetectNewForm(formNum);
        if (typeForm !== null) break;
      }
      if (typeForm !== null && await isTypeDialog(typeForm)) {
        await pickFromTypeDialog(typeForm, info.type);
        await waitForStable(typeForm);
        // After type selection, check if a selection form opened (ref types)
        const selForm = await helperDetectNewForm(formNum);
        if (selForm === null) {
          // Primitive type — poll for calculator/calendar popup or settle on INPUT
          let hasPopup = null;
          for (let pw = 0; pw < 5; pw++) {
            await page.waitForTimeout(200);
            hasPopup = await findOpenPopup();
            if (hasPopup) break;
          }
          if (hasPopup) {
            await page.keyboard.press('Escape');
            // Poll for popup to disappear
            for (let dw = 0; dw < 4; dw++) {
              await page.waitForTimeout(150);
              if (!(await findOpenPopup())) break;
            }
          }
          // Ensure we are in an editable INPUT for this cell
          const inInput = await isInputFocused({ allowTextarea: true });
          if (!inInput) {
            const cellRect = await page.evaluate(getElementCenterCoordsByIdScript(cell.id));
            if (cellRect) {
              await page.mouse.dblclick(cellRect.x, cellRect.y);
              // Poll for INPUT focus
              for (let fw = 0; fw < 4; fw++) {
                await page.waitForTimeout(150);
                if (await isInputFocused({ allowTextarea: true })) break;
              }
            }
          }
          await pasteText(text, { confirm: ['Control+a', 'Control+v'] });
          await page.waitForTimeout(400);
          await page.keyboard.press('Tab');
          await page.waitForTimeout(300);
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'type-direct', type: info.type });
          continue;
        }
        const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
        info.filled = true;
        results.push(pickResult.ok
          ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form', type: info.type }
          : { field: matchedKey, cell: cell.fullName, ok: false,
              error: pickResult.error, message: pickResult.message });
        continue;
      }
      // F4 opened something but not a type dialog — close and report
      if (typeForm !== null) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName, ok: false,
        error: 'type_dialog_failed',
        message: `Cell "${matchedKey}": F4 did not open type dialog for type "${info.type}"` });
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // Choice cell (_CB iCB): either an editable value cell (text sticks → direct input) or a
    // pick-from-list cell (НачалоВыбора / РедактированиеТекста=Ложь → text rejected → F4 form).
    // fillChoiceCell discriminates behaviorally; both kinds are indistinguishable in the DOM.
    if (cell.buttonKind === 'choice') {
      const r = await fillChoiceCell(formNum, text, { type: info.type, fieldLabel: matchedKey });
      info.filled = true;
      results.push(r.ok
        ? { field: matchedKey, cell: cell.fullName, ok: true, method: r.method, ...(r.value !== undefined ? { value: r.value } : {}) }
        : { field: matchedKey, cell: cell.fullName, ok: false, error: r.error, message: r.message });
      // 'direct' leaves text in the INPUT — caller's Tab (or end-of-row commit on the last field) persists it.
      if ([...pending.values()].every(p => p.filled)) break;
      await page.keyboard.press('Tab'); await page.waitForTimeout(500);
      continue;
    }

    // === Fill this cell: clipboard paste (trusted event) ===
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(1500);

    // Check if paste was rejected (composite-type cell blocks text input until type is selected)
    const inputAfterPaste = await page.evaluate(`document.activeElement?.value || ''`);
    if (!inputAfterPaste && text) {
      // No type specified — can't fill this composite-type cell
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName, ok: false,
        error: 'type_required',
        message: `Cell "${matchedKey}" rejected text input (composite-type). Use { value: '...', type: 'Тип' } syntax` });
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // Check for EDD autocomplete (indicates reference field)
    const edd = await readEdd();
    const eddItems = edd.visible ? edd.items.map(i => i.name) : null;

    if (eddItems && eddItems.length > 0) {
      // Reference field with autocomplete — click best match
      // Filter out reference field "create" actions (Создать элемент, Создать группу, Создать: ...)
      // but keep standalone enum values like "Создать" (no space/colon after)
      const realItems = eddItems.filter(i => !/^Создать[\s:]/.test(i));

      if (realItems.length > 0) {
        const tgt = normYo(text.toLowerCase());
        let pick = realItems.find(i =>
          normYo(i.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase()) === tgt);
        if (!pick) pick = realItems.find(i => normYo(i.toLowerCase()).includes(tgt));

        if (pick) {
          // Click EDD item via dispatchEvent (bypasses div.surface overlay)
          await clickEddItemViaDispatch(pick);
          await waitForStable();
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: true,
            method: 'dropdown', value: pick.replace(/\s*\([^)]*\)\s*$/, '') });
        } else {
          // EDD listed items but NONE matches the requested value. Do NOT blind-pick the
          // first item — when the typed text has no hit, 1C still shows unrelated entries
          // (recent/full list), so items[0] would silently write the wrong reference.
          // Dismiss, clear the typed text, report not_found.
          await page.keyboard.press('Escape');
          await page.waitForTimeout(300);
          await page.keyboard.press('Control+A');
          await page.keyboard.press('Delete');
          await page.waitForTimeout(200);
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: false,
            error: 'not_found', message: `No match for "${text}" in autocomplete` });
        }
      } else {
        // Only "Создать:" items — value not found in autocomplete
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
        info.filled = true;
        results.push({ field: matchedKey, cell: cell.fullName, ok: false,
          error: 'not_found', message: `No match for "${text}"` });
      }

      // Done? If so, don't Tab (avoids creating a new row after last cell)
      if ([...pending.values()].every(p => p.filled)) break;
      // Tab to move to next cell
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // No EDD — press Tab to commit the value
    await page.keyboard.press('Tab');
    await page.waitForTimeout(1000);

    // Check for "нет в списке" cloud popup (reference field, value not found)
    const notInList = await page.evaluate(isNotInListCloudVisibleScript());

    if (notInList) {
      // Cloud has "Показать все" link — try to open selection form via it
      const clickedShowAll = await page.evaluate(clickShowAllInNotInListCloudScript());

      if (clickedShowAll) {
        await waitForStable(formNum);
        // Check if selection form opened
        const selForm = await helperDetectNewForm(formNum, { strict: true });

        if (selForm !== null) {
          const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
          info.filled = true;
          if (pickResult.ok) {
            results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'form' });
            continue;
          }
          // Not found in selection form — fall through to clear + skip
          results.push({ field: matchedKey, cell: cell.fullName, ok: false,
            error: pickResult.error, message: pickResult.message });
        } else {
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: false,
            error: 'not_found', message: `Value "${text}" not in list` });
        }
      } else {
        info.filled = true;
        results.push({ field: matchedKey, cell: cell.fullName, ok: false,
          error: 'not_found', message: `Value "${text}" not in list` });
      }

      // 1C won't let us Tab away from an invalid ref value.
      // Must clear the field first, then Tab to move on.
      // Escape dismisses the cloud; Ctrl+A + Delete clears the text.
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await page.keyboard.press('Control+A');
      await page.keyboard.press('Delete');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // Check for a new form (broad detection — also catches type dialogs whose buttons lack IDs)
    const newForm = await helperDetectNewForm(formNum);

    if (newForm !== null) {
      if (await isTypeDialog(newForm)) {
        // Composite-type cell — need type to proceed
        if (info.type) {
          await pickFromTypeDialog(newForm, info.type);
          await waitForStable(newForm);
          // After type selection, the actual selection form should open
          const selForm = await helperDetectNewForm(formNum);
          if (selForm === null) {
            // Primitive type — poll for calculator/calendar popup or settle on INPUT
            let hasPopup = null;
            for (let pw = 0; pw < 5; pw++) {
              await page.waitForTimeout(200);
              hasPopup = await findOpenPopup();
              if (hasPopup) break;
            }
            if (hasPopup) {
              await page.keyboard.press('Escape');
              for (let dw = 0; dw < 4; dw++) {
                await page.waitForTimeout(150);
                if (!(await findOpenPopup())) break;
              }
            }
            const inInput = await isInputFocused({ allowTextarea: true });
            if (!inInput) {
              const cellRect = await page.evaluate(getElementCenterCoordsByIdScript(cell.id));
              if (cellRect) {
                await page.mouse.dblclick(cellRect.x, cellRect.y);
                for (let fw = 0; fw < 4; fw++) {
                  await page.waitForTimeout(150);
                  if (await isInputFocused({ allowTextarea: true })) break;
                }
              }
            }
            await pasteText(text, { confirm: ['Control+a', 'Control+v'] });
            await page.waitForTimeout(400);
            await page.keyboard.press('Tab');
            await page.waitForTimeout(300);
            info.filled = true;
            results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'type-direct', type: info.type });
            continue;
          }
          const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
          info.filled = true;
          results.push(pickResult.ok
            ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form', type: info.type }
            : { field: matchedKey, cell: cell.fullName, ok: false,
                error: pickResult.error, message: pickResult.message });
          continue;
        } else {
          // No type specified — close dialog, clear cell, report error
          await page.keyboard.press('Escape');
          await page.waitForTimeout(300);
          await page.keyboard.press('Control+A');
          await page.keyboard.press('Delete');
          await page.waitForTimeout(300);
          await page.keyboard.press('Tab');
          await page.waitForTimeout(500);
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: false,
            error: 'type_required',
            message: `Cell "${matchedKey}" opened a type selection dialog. Use { value: '...', type: 'Тип' } syntax` });
          continue;
        }
      }
      // Not a type dialog — normal selection form
      const pickResult = await pickFromSelectionForm(newForm, matchedKey, text, formNum);
      info.filled = true;
      results.push(pickResult.ok
        ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form' }
        : { field: matchedKey, cell: cell.fullName, ok: false,
            error: pickResult.error, message: pickResult.message });
      continue;
    }

    // Plain field — value committed via Tab
    info.filled = true;
    results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'direct' });

    // All done?
    if ([...pending.values()].every(p => p.filled)) break;
    // Tab already pressed — we're on next cell
  }

  // Commit the new row: click on the grid header to exit edit mode.
  // Clicking a different data row would re-enter edit mode on that row.
  // Without this commit click, the row stays in "uncommitted add" state
  // and a subsequent Escape (e.g. from closeForm) would cancel the entire row.
  const commitTarget = await page.evaluate(findGridHeadCenterCoordsScript(gridSelector));
  if (commitTarget) {
    await page.mouse.click(commitTarget.x, commitTarget.y);
    await page.waitForTimeout(500);
  } else {
    // Fallback: Tab out of the last cell to commit the row
    await page.keyboard.press('Tab');
    await page.waitForTimeout(500);
  }

  // Dismiss any leftover error modals
  const err = await checkForErrors();
  if (err?.modal) {
    try {
      const btn = await page.$('a.press.pressDefault');
      if (btn) { await btn.click(); await page.waitForTimeout(500); }
    } catch { /* OK */ }
  }

  const notFilled = [...pending].filter(([_, info]) => !info.filled).map(([key]) => key);

  // Retry unfilled checkbox fields via direct click (Tab skips checkbox cells)
  if (notFilled.length > 0) {
    const checkboxFields = {};
    for (const key of notFilled) {
      const val = String(pending.get(key).value).toLowerCase().trim();
      if (['true', 'false', 'да', 'нет', '1', '0', 'yes', 'no'].includes(val)) {
        checkboxFields[key] = pending.get(key).value;
      }
    }
    if (Object.keys(checkboxFields).length > 0) {
      // Use row index: addedRowIdx (from add mode) or fallback to selected row
      const currentRow = addedRowIdx >= 0 ? addedRowIdx : (row != null ? row : await page.evaluate(getSelectedOrLastRowIndexScript(gridSelector))
      );
      if (currentRow >= 0) {
        const more = await fillTableRow(checkboxFields, { row: currentRow, table });
        results.push(...more.filled);
        for (const key of Object.keys(checkboxFields)) {
          const idx = notFilled.indexOf(key);
          if (idx >= 0) notFilled.splice(idx, 1);
        }
      }
    }
  }

  const extras = { filled: results };
  if (notFilled.length > 0) extras.notFilled = notFilled;
  return returnFormState(extras);

  } catch (e) {
    if (e.message.startsWith('fillTableRow:')) throw e;
    throw new Error(`fillTableRow: ${e.message}`);
  }
}
