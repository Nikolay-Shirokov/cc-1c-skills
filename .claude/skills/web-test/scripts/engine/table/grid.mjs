// web-test table/grid v1.18 — Form-grid operations: read table rows, fill rows, delete rows.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// "Grid" в терминах 1С — таблица на форме (.gridLine/.gridBody/.grid в DOM):
// табличные части документов, формы списков, ТЧ настроек и т.п.
// Отдельно от SpreadsheetDocument (engine/spreadsheet/spreadsheet.mjs).

import { page, ensureConnected } from '../core/state.mjs';
import { detectFormScript, readTableScript, resolveGridScript } from '../../dom.mjs';
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
  const cellCoords = await page.evaluate(`(() => {
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
    if (!grid) return { error: 'no_grid' };
    const body = grid.querySelector('.gridBody');
    if (!body) return { error: 'no_grid_body' };
    const rows = [...body.querySelectorAll('.gridLine')];
    if (${row} >= rows.length) return { error: 'row_out_of_range', total: rows.length };
    const line = rows[${row}];
    // Use visible gridBox containers (not gridBoxText) to avoid clicking checkboxes
    const boxes = [...line.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
    // Skip first column (row number / checkbox) — pick second visible box
    const box = boxes.length > 1 ? boxes[1] : boxes[0];
    if (!box) return { error: 'no_cell' };
    const cell = box.querySelector('.gridBoxText') || box;
    const r = cell.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), total: rows.length };
  })()`);

  if (cellCoords.error) throw new Error(`deleteTableRow: ${cellCoords.error}${cellCoords.total ? ' (total rows: ' + cellCoords.total + ')' : ''}`);

  const rowsBefore = cellCoords.total;

  // Single click to select the row
  await page.mouse.click(cellCoords.x, cellCoords.y);
  await page.waitForTimeout(300);

  // 3. Press Delete to remove the row
  await page.keyboard.press('Delete');
  await waitForStable();

  // 4. Count rows after deletion
  const rowsAfter = await page.evaluate(`(() => {
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
    if (!grid) return 0;
    const body = grid.querySelector('.gridBody');
    return body ? body.querySelectorAll('.gridLine').length : 0;
  })()`);

  return returnFormState({ deleted: row, rowsBefore, rowsAfter });
}
