// web-test core/click v1.24 — clickElement dispatcher: routes to spreadsheet / popup / form-group / grid-row / form-element / field-focus handlers by target kind.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, ensureConnected, highlightMode } from './state.mjs';
import {
  detectFormScript, findClickTargetScript, resolveGridScript,
  readSubmenuScript, resolveCellTargetScript,
} from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors } from './errors.mjs';
import { waitForStable } from './wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import { modifierClick, returnFormState } from './helpers.mjs';
import {
  clickGridGroupTarget, clickGridTreeNodeTarget, clickGridRowTarget,
} from '../table/click-row.mjs';
import { clickGridCell } from '../table/click-cell.mjs';
import {
  clickConfirmationButton, tryClickPopupItem,
} from '../forms/click-popup.mjs';
import { clickFormTarget, focusFormField } from '../forms/click-form.mjs';
import { clickFormGroupTarget } from '../forms/click-group.mjs';
import {
  clickSpreadsheetCell, findSpreadsheetCellByText,
} from '../spreadsheet/spreadsheet.mjs';

/** Click a button/hyperlink/tab on the current form. Use {dblclick: true} to double-click (open items from lists).
 *  First argument can also be an object { row, column } to click a cell in a SpreadsheetDocument (отчёт) or a form grid (таблица/табчасть). */
export async function clickElement(text, { dblclick, table, toggle, expand, modifier, scroll, timeout } = {}) {
  ensureConnected();

  // Dispatch to cell handler when first arg is { row, column }.
  // Routing (see resolveCellTargetScript):
  //   - `table` named: matches grid → grid cell; falls back to spreadsheet if it's the spreadsheet's name.
  //   - no `table`: form has spreadsheet → spreadsheet cell (backward-compat);
  //                 else first visible grid → grid cell.
  if (typeof text === 'object' && text !== null && text.column != null) {
    await dismissPendingErrors();
    const formNum = await page.evaluate(detectFormScript());
    if (formNum === null) throw new Error('clickElement: no form found');
    const route = await page.evaluate(resolveCellTargetScript(formNum, table));
    if (route.error === 'table_not_found') {
      throw new Error(`clickElement: table "${table}" not found. Available grids: ${(route.availableGrids || []).join(', ') || 'none'}`);
    }
    if (route.error) {
      throw new Error(`clickElement: no spreadsheet or grid on form to click cell in.`);
    }
    if (route.kind === 'spreadsheet') {
      return clickSpreadsheetCell(text, { dblclick, modifier });
    }
    // route.kind === 'grid'
    return clickGridCell(text, {
      formNum,
      gridSelector: route.gridSelector,
      gridName: route.gridName,
      modifier, dblclick, scroll,
    });
  }

  await dismissPendingErrors();
  if (highlightMode) {
    try { await highlight(text, { table }); await page.waitForTimeout(500); await unhighlight(); } catch {}
  }

  try {
    // 1. Intercept open confirmation dialog (Да/Нет/Отмена) — match button by text.
    const pending = await checkForErrors();
    if (pending?.confirmation) {
      return await clickConfirmationButton(text);
    }

    // 2. Intercept open popup (from previous submenu/split-button click).
    //    Returns null if popup is open but `text` doesn't match — fall through.
    const popupItems = await page.evaluate(readSubmenuScript());
    if (Array.isArray(popupItems) && popupItems.length > 0) {
      const popupResult = await tryClickPopupItem(text, popupItems);
      if (popupResult) return popupResult;
    }

    // 3. Find a target on the current form.
    let formNum = await page.evaluate(detectFormScript());
    if (formNum === null) throw new Error(`clickElement: no form found`);

    let gridSelector;
    if (table) {
      const resolved = await page.evaluate(resolveGridScript(formNum, table));
      if (resolved.error) throw new Error(`clickElement: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
      gridSelector = resolved.gridSelector;
    }

    let target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));

    // Retry: if not found, a modal form may still be loading (e.g. after F4).
    if (target?.error) {
      for (let retry = 0; retry < 4; retry++) {
        await page.waitForTimeout(500);
        const newForm = await page.evaluate(detectFormScript());
        if (newForm !== null && newForm !== formNum) {
          formNum = newForm;
          target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));
          if (!target?.error) break;
        }
      }
    }

    // Spreadsheet fallback: search iframes for text match before giving up.
    if (target?.error) {
      const ssCell = await findSpreadsheetCellByText(formNum, text);
      if (ssCell) {
        const cx = ssCell.box.x + ssCell.box.width / 2;
        const cy = ssCell.box.y + ssCell.box.height / 2;
        await modifierClick(cx, cy, modifier, { dbl: !!dblclick });
        await waitForStable();
        return returnFormState({
          clicked: { kind: 'spreadsheetCell', name: ssCell.text, ...(dblclick ? { dblclick: true } : {}) },
        });
      }
      throw new Error(`clickElement: "${text}" not found. Available: ${target.available?.join(', ') || 'none'}`);
    }

    // 4. Guard: a disabled target (button/frameButton/checkbox/tumbler/field) is a silent
    //    no-op in 1C — clicking it does nothing. Fail loud instead of masquerading success.
    //    Availability is checkable up front via getFormState().buttons[].disabled / fields[].disabled.
    if (target.disabled) throw new Error(`clickElement: "${text}" is disabled`);

    // 5. Dispatch to the right handler by target kind.
    const ctx = { formNum, modifier, dblclick, toggle, expand, timeout, table, gridSelector };
    if (target.kind === 'formGroup') return await clickFormGroupTarget(target, ctx);
    if (target.kind === 'gridGroup' || target.kind === 'gridParent') return await clickGridGroupTarget(target, ctx);
    if (target.kind === 'gridTreeNode') return await clickGridTreeNodeTarget(target, ctx);
    if (target.kind === 'gridRow') return await clickGridRowTarget(target, ctx);
    if (target.kind === 'field') return await focusFormField(target, ctx);
    return await clickFormTarget(target, ctx);
  } finally {
    if (highlightMode) try { await unhighlight(); } catch {}
  }
}
