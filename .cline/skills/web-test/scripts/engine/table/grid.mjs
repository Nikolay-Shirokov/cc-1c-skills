// web-test table/grid v1.20 — Form-grid operations: read table rows, fill rows, delete rows.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// "Grid" в терминах 1С — таблица на форме (.gridLine/.gridBody/.grid в DOM):
// табличные части документов, формы списков, ТЧ настроек и т.п.
// Отдельно от SpreadsheetDocument (engine/spreadsheet/spreadsheet.mjs).

import { page, ensureConnected } from '../core/state.mjs';
import { detectFormScript, readTableScript, resolveGridScript } from '../../dom.mjs';
import { findDeleteRowCoordsScript, countGridRowsScript } from '../../dom/grid.mjs';
import { isInputFocusedInGrid } from '../core/helpers.mjs';
import { dismissPendingErrors } from '../core/errors.mjs';
import { waitForStable } from '../core/wait.mjs';
import { clickElement } from '../core/click.mjs';
import { returnFormState } from '../core/helpers.mjs';

/** Read structured table data with pagination. Returns columns, rows, total count. */
export async function readTable({ maxRows = 20, offset = 0, table } = {}) {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('readTable: no form found');
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`readTable: ${resolved.message || resolved.error}. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }
  return await page.evaluate(readTableScript(formNum, { maxRows, offset, gridSelector }));
}

/**
 * Delete a row from the current table part.
 * Single click to select the row, then Delete key to remove it.
 *
 * @param {number} row - 0-based row index to delete
 * @param {Object} [options]
 * @param {string} [options.tab] - Switch to this form tab before operating
 * @returns {object} form state with { deleted, rowsBefore, rowsAfter }
 */
export async function deleteTableRow(row, { tab, table } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('deleteTableRow: no form found');

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`deleteTableRow: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  // 1. Switch tab if requested
  if (tab) {
    await clickElement(tab);
    await page.waitForTimeout(500);
  }

  // 2. Find the target row and click to select it
  const cellCoords = await page.evaluate(findDeleteRowCoordsScript(gridSelector, row));

  if (cellCoords.error) throw new Error(`deleteTableRow: ${cellCoords.error}${cellCoords.total ? ' (total rows: ' + cellCoords.total + ')' : ''}`);

  const rowsBefore = cellCoords.total;

  // Pre-click Escape: leftover edit-mode from a prior fillTableRow Tab-navigation.
  // Without it the next mouse click may not select the row reliably (the active
  // edit input intercepts the event timing).
  if (await isInputFocusedInGrid({ gridSelector })) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }

  // Single click to select the row
  await page.mouse.click(cellCoords.x, cellCoords.y);
  await page.waitForTimeout(300);

  // Post-click Escape: clicking a Number/Date cell auto-enters edit mode in 1С.
  // Delete in edit mode clears the cell buffer instead of deleting the row, so
  // we exit edit first. The row remains selected after Escape — Delete acts on it.
  if (await isInputFocusedInGrid({ gridSelector })) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }

  // 3. Press Delete to remove the row
  await page.keyboard.press('Delete');
  await waitForStable();

  // 4. Count rows after deletion
  const rowsAfter = await page.evaluate(countGridRowsScript(gridSelector));

  return returnFormState({ deleted: row, rowsBefore, rowsAfter });
}
