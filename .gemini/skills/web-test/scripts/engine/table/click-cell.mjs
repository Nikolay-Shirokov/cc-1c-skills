// web-test table/click-cell v1.4 — click a cell in a form grid by (row, column).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Routed from core/click.mjs when the user calls clickElement({row, column}) and
// the form has no SpreadsheetDocument (or `table` matches a grid).
//
// Key behaviors:
//  - `row` can be a number (index in current DOM window) or `{col: value}` filter.
//  - `scroll: true | number` enables reveal-loop via PageDown when a filter row
//    isn't visible. End detected by snapshot stability between PageDowns.
//  - Horizontal scroll mirrors SpreadsheetDocument: focus a visible cell in the
//    target row, press ArrowRight/Left until the target column is in viewport.
//
// 1С virtualization quirks worth knowing:
//  - DOM holds a window of ~N visible rows. PageDown's first press moves the
//    cursor inside the window; subsequent presses swap the window contents.
//  - scrollTop/scrollLeft are always 0; absolute X of cells shifts on horizontal
//    scroll. So scroll progress must be inferred from cell coordinates / snapshot
//    diffs, never from scrollTop/Height.
//  - Frozen columns (.gridBoxFix) stay pinned at the left, overlap with scrolled
//    cells — DOM scripts handle the partition; engine just consumes their results.

import { page } from '../core/state.mjs';
import { waitForStable } from '../core/wait.mjs';
import { modifierClick, returnFormState, isInputFocusedInGrid } from '../core/helpers.mjs';
import { scrollHorizontallyByKey } from '../core/scroll-horiz.mjs';
import {
  findGridCellScript, findFocusCellScript, snapshotGridScript,
} from '../../dom.mjs';

const REVEAL_DEFAULT_LIMIT = 50;
const PD_WAIT_MS = 300;
const FOCUS_WAIT_MS = 150;

/**
 * Guard: a 'pic:N' filter value is a readTable picture token, not real cell text.
 * Picture cells render an icon (no text), so they can't select a row — fail fast
 * with guidance instead of a confusing 'row_not_found'.
 */
function assertNotPictureFilter(filter) {
  for (const [k, v] of Object.entries(filter)) {
    if (typeof v === 'string' && /^pic:\d+$/.test(v.trim())) {
      throw new Error(`clickElement: "${v}" is a readTable picture value (column "${k}"), not selectable text — it can't be used as a row filter. Filter by a text column (e.g. name/number) instead.`);
    }
  }
}

/**
 * Resolve a `{ col: value }` row filter to a numeric index into the grid's current
 * DOM window (`body.querySelectorAll('.gridLine')`). Reused by fillTableRow so it
 * can target an existing row by cell values, mirroring clickElement.
 *
 * The filter matches across ALL columns (AND). `findGridCellScript` requires a
 * `column`, so we pass the first filter key as a placeholder — it only affects the
 * returned coordinates (which we ignore), not row selection. The matched row
 * guarantees that key's cell is in the DOM, so no `cell_not_in_dom` for it.
 *
 * @param {object} args
 * @param {number} args.formNum
 * @param {string} [args.gridSelector] - CSS selector for the target grid (same grid the caller edits)
 * @param {object} args.filter - `{ col: value }` (one or more columns)
 * @param {string} [args.gridName] - for diagnostics in error messages
 * @param {boolean|number} [args.scroll] - reveal-loop beyond the DOM window (true = 50 PageDowns, number = limit)
 * @returns {Promise<number>} resolved row index
 */
export async function resolveRowIndexByFilter({ formNum, gridSelector, filter, gridName, scroll }) {
  assertNotPictureFilter(filter);
  const target = { row: filter, column: Object.keys(filter)[0] };
  let cell = await page.evaluate(findGridCellScript(formNum, gridSelector, target));
  if (cell?.error === 'row_not_found' && scroll) {
    cell = await revealAndFindCell({ formNum, gridSelector, target, scroll });
  }
  if (cell?.error) throw cellError(cell, target, gridName, scroll, 'fillTableRow');
  return cell.rowIdx;
}

/**
 * Click a cell in a form grid by (row, column). Called from core/click.mjs.
 *
 * @param {object} target - { row: number|{col:value}, column: string }
 * @param {object} ctx
 * @param {number} ctx.formNum
 * @param {string} ctx.gridSelector - CSS selector for the target grid
 * @param {string} [ctx.gridName] - for diagnostics
 * @param {string} [ctx.modifier] - 'ctrl' | 'shift' for multi-select
 * @param {boolean} [ctx.dblclick]
 * @param {boolean|number} [ctx.scroll] - true = up to 50 PageDowns, number = exact limit
 */
export async function clickGridCell(target, ctx) {
  const { formNum, gridSelector, gridName, modifier, dblclick, scroll } = ctx;

  if (target?.row && typeof target.row === 'object') assertNotPictureFilter(target.row);

  // 1. Try to find the cell in current DOM window.
  let cell = await page.evaluate(findGridCellScript(formNum, gridSelector, target));

  // 2. Reveal loop: only for filter-based row search with scroll opt-in.
  if (cell?.error === 'row_not_found' && scroll && target.row && typeof target.row === 'object') {
    cell = await revealAndFindCell({ formNum, gridSelector, target, scroll });
  }

  if (cell?.error) throw cellError(cell, target, gridName, scroll);

  // 3. Horizontal scroll if cell is off-viewport.
  if (!cell.visible) {
    await scrollGridToCell({ formNum, gridSelector, target, cell });
    cell = await page.evaluate(findGridCellScript(formNum, gridSelector, target));
    if (cell?.error) {
      throw new Error(`clickElement: cell vanished after horizontal scroll: ${cell.error}`);
    }
    if (!cell.visible) {
      // Scroll loop bailed out before reaching the target. Don't silently click
      // at off-screen coordinates — that would report a false success.
      const ctxMsg = gridName ? ` in table "${gridName}"` : '';
      throw new Error(`clickElement: horizontal scroll could not reach column "${cell.columnText}"${ctxMsg} (cell still at x=${cell.cellX}, viewport ends at ${cell.gridRight}).`);
    }
  }

  // 4. Click.
  await modifierClick(cell.x, cell.y, modifier, { dbl: !!dblclick });
  await waitForStable();
  return returnFormState({
    clicked: {
      kind: 'gridCell',
      row: target.row,
      column: cell.columnText,
      ...(dblclick ? { dblclick: true } : {}),
      ...(modifier ? { modifier } : {}),
    },
  });
}

function cellError(cell, target, gridName, scroll, who = 'clickElement') {
  const ctxMsg = gridName ? ` in table "${gridName}"` : '';
  if (cell.error === 'row_not_found') {
    const hint = scroll
      ? ' (reveal-loop exhausted)'
      : ' — pass { scroll: true } to scan beyond the current DOM window';
    return new Error(`${who}: row matching ${JSON.stringify(target.row)} not found${ctxMsg}${hint}.`);
  }
  if (cell.error === 'column_not_found' || cell.error === 'filter_column_not_found') {
    return new Error(`${who}: column "${cell.column}" not found${ctxMsg}. Available: ${(cell.available || []).join(', ')}`);
  }
  if (cell.error === 'row_out_of_range') {
    return new Error(`${who}: row index ${cell.row} out of range${ctxMsg} (loaded: ${cell.loaded}). Note: row index is into current DOM window, not absolute — long lists are virtualized.`);
  }
  return new Error(`${who}: cannot resolve cell ${JSON.stringify(target)}${ctxMsg}: ${cell.error}`);
}

/**
 * Press PageDown in a loop, scanning DOM each iteration for the target row.
 * Bail when the row is found, snapshots stop changing (end of list), or limit hit.
 * page.mouse.click on a safe cell first — PageDown needs keyboard focus on gridBody.
 */
async function revealAndFindCell({ formNum, gridSelector, target, scroll }) {
  const limit = typeof scroll === 'number' ? scroll : REVEAL_DEFAULT_LIMIT;

  const focusPt = await page.evaluate(findFocusCellScript(gridSelector));
  if (!focusPt) return { error: 'no_focusable_cell' };
  await page.mouse.click(focusPt.x, focusPt.y);
  await page.waitForTimeout(FOCUS_WAIT_MS);
  // Click on a Number/Date cell auto-enters edit mode in 1С; PageDown there
  // is a no-op. Exit edit mode before driving the reveal loop.
  if (await isInputFocusedInGrid({ gridSelector })) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }

  let prevSnap = await page.evaluate(snapshotGridScript(gridSelector));
  for (let i = 0; i < limit; i++) {
    await page.keyboard.press('PageDown');
    await page.waitForTimeout(PD_WAIT_MS);

    const cell = await page.evaluate(findGridCellScript(formNum, gridSelector, target));
    if (!cell?.error) return cell;

    const snap = await page.evaluate(snapshotGridScript(gridSelector));
    // Reached the end of the list. Primary signal: nothing remains below
    // (`hasBelow === false`) — the reliable cross-grid-type signal. Content
    // stability is only a fallback when hasBelow is unknown: it compares the
    // full-row text (snapshotGridScript joins every cell), so a low-cardinality
    // first column (e.g. all "Товар 0X") can't look "stable" mid-scroll.
    const reachedEnd = snap && (
      snap.hasBelow === false
      || (snap.hasBelow == null
        && snap.firstText === prevSnap?.firstText
        && snap.lastText === prevSnap?.lastText
        && snap.selIdx === prevSnap?.selIdx
        && snap.lineCount === prevSnap?.lineCount)
    );
    if (reachedEnd) return { error: 'row_not_found', filter: target.row };
    prevSnap = snap;
  }
  return { error: 'row_not_found', filter: target.row };
}

/**
 * Scroll the grid horizontally so the target cell falls inside the viewport.
 * Focuses an edge cell in the target row (rightmost-visible for ArrowRight,
 * leftmost-visible for ArrowLeft) so the next arrow key immediately scrolls.
 *
 * Frozen columns (gridBoxFix) are excluded from focus candidates — they don't
 * drive the scrollable viewport. The DOM script handles that detail.
 */
async function scrollGridToCell({ formNum, gridSelector, target, cell }) {
  const direction = cell.cellX > cell.gridRight ? 'ArrowRight'
                  : cell.cellRight < cell.gridX ? 'ArrowLeft'
                  : (cell.cellRight > cell.gridRight ? 'ArrowRight' : 'ArrowLeft');

  const focusPt = await page.evaluate(
    findFocusCellScript(gridSelector, { rowIdx: cell.rowIdx, direction })
  );
  if (!focusPt) throw new Error('clickElement: no visible cell to focus for horizontal scroll');
  await page.mouse.click(focusPt.x, focusPt.y);
  await page.waitForTimeout(FOCUS_WAIT_MS);
  // Click on a Number/Date cell auto-enters edit mode in 1С; arrow keys there
  // navigate text inside the input rather than scrolling the viewport. Exit first.
  if (await isInputFocusedInGrid({ gridSelector })) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }

  await scrollHorizontallyByKey({
    page,
    direction,
    isFullyVisible: async () => {
      const c = await page.evaluate(findGridCellScript(formNum, gridSelector, target));
      return !!c && !c.error && c.visible;
    },
    getCenterX: async () => {
      const c = await page.evaluate(findGridCellScript(formNum, gridSelector, target));
      return c && !c.error ? c.x : null;
    },
  });
}
