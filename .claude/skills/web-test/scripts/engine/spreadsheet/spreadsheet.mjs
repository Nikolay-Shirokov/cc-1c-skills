// web-test spreadsheet v1.18 — readSpreadsheet + helpers for SpreadsheetDocument (отчёты, печатные формы).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, ensureConnected } from '../core/state.mjs';
import { detectFormScript } from '../../dom.mjs';
import { waitForStable } from '../core/wait.mjs';
import { getFormState } from '../forms/state.mjs';
import { returnFormState } from '../core/helpers.mjs';

// --- Spreadsheet helpers (shared by readSpreadsheet and clickElement) ---

/**
 * Scan spreadsheet iframes for the current form and collect all cells.
 * Returns { allCells: Map<'r_c', {r,c,t}>, frameMap: Map<'r_c', frameIndex> }
 * where frameIndex is the Playwright frames[] index (1-based, 0 = main).
 */
async function scanSpreadsheetCells(formNum) {
  const prefix = `form${formNum ?? 0}_`;
  const iframeHandles = await page.$$('iframe');

  const allCells = new Map();
  const frameMap = new Map(); // key 'r_c' → Playwright Frame object

  for (const handle of iframeHandles) {
    const ok = await handle.evaluate((f, pfx) => {
      if (f.offsetWidth < 100) return false;
      let el = f.parentElement;
      for (let d = 0; el && d < 30; d++, el = el.parentElement) {
        if (el.id && el.id.startsWith(pfx)) return true;
      }
      return false;
    }, prefix);
    if (!ok) continue;

    const frame = await handle.contentFrame();
    if (!frame) continue;

    try {
      const cells = await frame.evaluate(`(() => {
        const cells = [];
        document.querySelectorAll('div[x]').forEach(d => {
          const span = d.querySelector('span');
          const text = span?.innerText?.replace(/\\n/g, ' ')?.trim() || '';
          if (!text) return;
          const rowDiv = d.parentElement;
          const row = rowDiv?.getAttribute('y') || rowDiv?.className?.match(/R(\\d+)/)?.[1] || null;
          const col = d.getAttribute('x');
          if (row != null && col != null) cells.push({ r: parseInt(row), c: parseInt(col), t: text });
        });
        return cells;
      })()`);
      for (const cell of cells) {
        const key = `${cell.r}_${cell.c}`;
        if (!allCells.has(key) || cell.t.length > allCells.get(key).t.length) {
          allCells.set(key, cell);
          frameMap.set(key, frame);
        }
      }
    } catch { /* skip inaccessible frames */ }
  }
  return { allCells, frameMap };
}

/**
 * Build structured mapping from raw cells: headers, column map, data/totals row indices.
 * Returns { rows, sortedRows, maxCol, colNames, headerRowIdx, dataStartIdx, totalsRowIdx, rowMap }
 * or null if header detection fails.
 */
function buildSpreadsheetMapping(allCells) {
  const rowMap = new Map();
  let maxCol = 0;
  for (const cell of allCells.values()) {
    if (!rowMap.has(cell.r)) rowMap.set(cell.r, new Map());
    rowMap.get(cell.r).set(cell.c, cell.t);
    if (cell.c > maxCol) maxCol = cell.c;
  }

  const sortedRows = [...rowMap.keys()].sort((a, b) => a - b);
  const rows = sortedRows.map(r => {
    const cm = rowMap.get(r);
    const arr = [];
    for (let c = 0; c <= maxCol; c++) arr.push(cm.get(c) || '');
    return arr;
  });

  // Generic numeric check: digits with optional spaces/commas, excludes codes like "68/78"
  // Accepts bare integers (e.g. account codes "50", "84") — used for hasNumber / totals classification.
  const isNumericVal = (c) => {
    if (!c || !/\d/.test(c)) return false;
    const s = c.replace(/^[-\s\u00a0]+/, '').replace(/[\s\u00a0]/g, '');
    return /^\d[\d,]*$/.test(s);
  };
  // Data-formatted numeric value: requires a formatting signal (grouping space, decimal comma, or leading minus).
  // Used as the anchor for first data row — avoids false positives on bare account codes like "50", "51".
  const isDataNumericVal = (c) => {
    if (!isNumericVal(c)) return false;
    return /[\s\u00a0,]/.test(c) || /^-/.test(c);
  };
  const hasNumber = (row) => row.some(c => isNumericVal(c));
  const nonEmpty = (row) => row.filter(c => c !== '').length;

  // Build a rich mapping (group/super/DCS) anchored at a known detailIdx + firstDataIdx.
  // Shared by Level 1 (DCS-code anchor) and Level 2 (formatted-number anchor).
  const buildRichMapping = (detailIdx, firstDataIdx) => {
    let groupIdx = -1;
    if (detailIdx > 0 && nonEmpty(rows[detailIdx - 1]) >= 2) groupIdx = detailIdx - 1;

    const detailRow = rows[detailIdx];
    const groupRow = groupIdx >= 0 ? rows[groupIdx] : null;

    // Detect optional third header level above group row (bounds carry-forward)
    let superRow = null;
    if (groupIdx > 0 && nonEmpty(rows[groupIdx - 1]) >= 2) {
      superRow = rows[groupIdx - 1];
    }

    // Build column names (group + detail merge)
    const groupFilled = new Array(maxCol + 1).fill('');
    if (groupRow) {
      let cur = '';
      for (let c = 0; c <= maxCol; c++) {
        if (groupRow[c]) {
          cur = groupRow[c];
        } else if (superRow && superRow[c]) {
          // New top-level header starts here — stop carry-forward
          cur = '';
        }
        groupFilled[c] = cur;
      }
    }

    const detailCounts = {};
    for (let c = 0; c <= maxCol; c++) {
      const n = detailRow[c];
      if (n) detailCounts[n] = (detailCounts[n] || 0) + 1;
    }

    // Detect DCS column codes (К1, К2, ...) — always prefix with group when present
    const detailNonEmpty = detailRow.filter(c => c);
    const isDcsCodeRow = detailNonEmpty.length >= 2 && detailNonEmpty.every(c => /^К\d+$/.test(c));

    const colNames = [];
    for (let c = 0; c <= maxCol; c++) {
      const detail = detailRow[c];
      const group = groupFilled[c];
      const sup = superRow ? superRow[c] : '';
      if (detail) {
        // Prefer group prefix; fall back to superRow for DCS code columns without sub-group
        const prefix = group && group !== detail ? group : (isDcsCodeRow && sup ? sup : '');
        const needPrefix = prefix && (isDcsCodeRow || detailCounts[detail] > 1 || (groupRow && groupRow[c] === ''));
        colNames.push(needPrefix ? `${prefix} / ${detail}` : detail);
      } else if (group) {
        colNames.push(group);
      } else if (sup) {
        colNames.push(sup);
      } else {
        colNames.push(null);
      }
    }

    const colMap = new Map();
    for (let c = 0; c < colNames.length; c++) {
      if (colNames[c]) colMap.set(colNames[c], c);
    }

    // Classify data rows: separate data indices and totals index
    const dataRowIndices = [];
    let totalsRowIdx = -1;
    for (let i = firstDataIdx; i < rows.length; i++) {
      if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
      const first = rows[i][0]?.trim().toLowerCase();
      if (first === 'итого' || first === 'всего') {
        totalsRowIdx = i;
      } else {
        dataRowIndices.push(i);
      }
    }

    const superRowIdx = superRow ? groupIdx - 1 : -1;

    return {
      rows, sortedRows, maxCol, colNames, colMap,
      headerRowIdx: detailIdx, groupRowIdx: groupIdx, superRowIdx,
      dataStartIdx: firstDataIdx, dataRowIndices, totalsRowIdx,
      rowMap, hasNumber, nonEmpty,
    };
  };

  // --- Level 1: DCS-code row anchor ---
  // ФСД / СКД-отчёты всегда содержат строку "К1, К2, ..." — rock-solid structural marker.
  // Якорение через неё — детерминированное, работает даже если все данные — голые целые (отчёт в "тыс.руб").
  for (let i = 0; i < rows.length; i++) {
    const detailNonEmpty = rows[i].filter(c => c);
    if (detailNonEmpty.length >= 2 && detailNonEmpty.every(c => /^К\d+$/.test(c))) {
      // Find first non-empty row after the К-codes row as data start
      let firstDataIdx = rows.length;
      for (let j = i + 1; j < rows.length; j++) {
        if (nonEmpty(rows[j]) > 0) { firstDataIdx = j; break; }
      }
      return buildRichMapping(i, firstDataIdx);
    }
  }

  // --- Level 2: formatted-number anchor (heuristic for reports without DCS codes) ---
  let firstDataIdx = rows.length;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].filter(c => isDataNumericVal(c)).length >= 2) { firstDataIdx = i; break; }
  }
  if (firstDataIdx === rows.length) {
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].some(c => isDataNumericVal(c))) { firstDataIdx = i; break; }
    }
  }

  if (firstDataIdx < rows.length) {
    let detailIdx = -1;
    for (let i = firstDataIdx - 1; i >= 0; i--) {
      if (nonEmpty(rows[i]) >= Math.min(3, maxCol + 1)) { detailIdx = i; break; }
    }
    if (detailIdx !== -1) return buildRichMapping(detailIdx, firstDataIdx);
  }

  // --- Level 3: single-row header fallback (text-only data, query console) ---
  // First "wide" row (nonEmpty >= 2) = headers, rest = data. No multi-level composition.
  let headerIdx = -1;
  for (let i = 0; i < rows.length; i++) {
    if (nonEmpty(rows[i]) >= 2) { headerIdx = i; break; }
  }
  // Single-column tables: accept nonEmpty >= 1
  if (headerIdx === -1 && maxCol === 0) {
    for (let i = 0; i < rows.length; i++) {
      if (nonEmpty(rows[i]) >= 1) { headerIdx = i; break; }
    }
  }
  if (headerIdx === -1) return null; // truly empty — top-level fallback to { rows, total }

  const detailRow = rows[headerIdx];
  const colNames = [];
  for (let c = 0; c <= maxCol; c++) colNames.push(detailRow[c] || null);
  const colMap = new Map();
  for (let c = 0; c < colNames.length; c++) {
    if (colNames[c]) colMap.set(colNames[c], c);
  }

  const dataRowIndices = [];
  let totalsRowIdx = -1;
  for (let i = headerIdx + 1; i < rows.length; i++) {
    if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
    const first = rows[i][0]?.trim().toLowerCase();
    if (first === 'итого' || first === 'всего') {
      totalsRowIdx = i;
    } else {
      dataRowIndices.push(i);
    }
  }

  return {
    rows, sortedRows, maxCol, colNames, colMap,
    headerRowIdx: headerIdx, groupRowIdx: -1, superRowIdx: -1,
    dataStartIdx: headerIdx + 1, dataRowIndices, totalsRowIdx,
    rowMap, hasNumber, nonEmpty,
  };
}

/**
 * Scroll SpreadsheetDocument to make a cell visible using arrow keys.
 * Uses native platform scroll — keeps headers, data, and scrollbar synchronized.
 *
 * How it works:
 * 1. Check target cell visibility via Playwright boundingBox (page-level coords).
 * 2. Click a fully-visible cell via page.mouse.click through the mxlCurrBody overlay.
 *    This is the same native click that clickSpreadsheetCell uses — it gives keyboard
 *    focus to the spreadsheet and keeps headers/data/scrollbar in sync.
 *    (frame.locator().click() bypasses overlay → desyncs frozen headers;
 *     page.mouse.click() + frameEl.focus() doesn't transfer keyboard focus.)
 * 3. Press ArrowRight/ArrowLeft until the target cell is fully within the viewport.
 *
 * @param {Frame} frame - Playwright Frame containing the spreadsheet cells
 * @param {number} physRow - physical row (y attribute) in the frame
 * @param {number} physCol - physical column (x attribute) in the frame
 * @param {Locator} cellLoc - Playwright locator for the target cell (from caller)
 */
async function scrollSpreadsheetToCell(frame, physRow, physCol, cellLoc) {
  const pageVw = await page.evaluate('window.innerWidth');
  // Get iframe bounds — the actual visible region on page.
  // The iframe may extend behind the section panel on the left, so cells with
  // x >= 0 but x < iframeBox.x are behind the panel. Clicking them hits the panel.
  const frameElm = await frame.frameElement();
  const frameBox = await frameElm.boundingBox();
  const visLeft = frameBox ? frameBox.x : 0;
  const visRight = frameBox ? Math.min(frameBox.x + frameBox.width, pageVw) : pageVw;

  const getBox = async () => {
    try { return await cellLoc.boundingBox({ timeout: 500 }); }
    catch { return null; }
  };
  const isFullyVisible = (box) => box && box.x >= visLeft && (box.x + box.width) <= visRight;

  let box = await getBox();
  if (!box) return; // cell not in DOM
  if (isFullyVisible(box)) return;

  const direction = (box.x + box.width) > pageVw ? 'ArrowRight' : 'ArrowLeft';

  // Find a fully-visible cell to click for focus.
  // Prefer cells in the target row (scrollable area), fall back to any row.
  const targetRowSel = `div[y="${physRow}"] div[x]`;
  const anyRowSel = 'div[x]';
  let focusClicked = false;
  for (const sel of [targetRowSel, anyRowSel]) {
    const locs = frame.locator(sel);
    const count = await locs.count();
    const candidates = [];
    for (let ci = 0; ci < count; ci++) {
      const b = await locs.nth(ci).boundingBox();
      if (b && b.width > 5 && b.x >= visLeft && (b.x + b.width) <= visRight) {
        candidates.push({ ci, box: b });
      }
    }
    if (candidates.length === 0) continue;
    candidates.sort((a, b) => a.box.x - b.box.x);
    // ArrowRight → rightmost fully-visible (each press scrolls right immediately)
    // ArrowLeft  → leftmost fully-visible  (each press scrolls left immediately)
    const pick = direction === 'ArrowRight'
      ? candidates[candidates.length - 1]
      : candidates[0];
    // Native click through overlay — gives keyboard focus + no header desync.
    await page.mouse.click(pick.box.x + pick.box.width / 2, pick.box.y + pick.box.height / 2);
    await page.waitForTimeout(100);
    focusClicked = true;
    break;
  }
  if (!focusClicked) return; // no visible cells — can't scroll

  // Arrow keys until cell is fully visible or we detect no progress.
  const MAX_STALE = 5; // bail out if arrows aren't scrolling (lost focus?)
  let prevCx = box.x + box.width / 2;
  let staleCount = 0;
  for (let i = 0; i < 100; i++) {
    await page.keyboard.press(direction);
    await page.waitForTimeout(50);
    box = await getBox();
    if (!box) break;
    if (isFullyVisible(box)) break;
    const cx = box.x + box.width / 2;
    if (Math.abs(cx - prevCx) >= 1) {
      staleCount = 0;
    } else {
      staleCount++;
      if (staleCount >= MAX_STALE) break;
    }
    prevCx = cx;
  }
  await page.waitForTimeout(200);
}

/**
 * Click a cell in SpreadsheetDocument by logical coordinates.
 * target: { row: number|'totals'|{colName: value}, column: string }
 * Internal helper — called from clickElement when first arg is an object.
 */
export async function clickSpreadsheetCell(target, { dblclick: dbl, modifier } = {}) {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());
  const { allCells, frameMap } = await scanSpreadsheetCells(formNum);
  if (allCells.size === 0) throw new Error('clickElement: no SpreadsheetDocument found on current form.');

  const mapping = buildSpreadsheetMapping(allCells);
  if (!mapping) throw new Error('clickElement: could not detect spreadsheet headers. Use readSpreadsheet() to check report structure.');

  const { rows, sortedRows, colNames, colMap, dataRowIndices, totalsRowIdx } = mapping;

  // Resolve column (exact → endsWith " / X" → includes)
  let colName = target.column;
  if (!colMap.has(colName)) {
    const available = colNames.filter(n => n);
    const suffix = ' / ' + colName;
    const match = available.find(n => n.endsWith(suffix)) || available.find(n => n.includes(colName));
    if (!match) throw new Error(`clickElement: column "${colName}" not found. Available: ${available.join(', ')}`);
    colName = match;
  }
  const physCol = colMap.get(colName);

  // Resolve row → index into rows[] array
  let rowIdx;
  const row = target.row;
  if (row === 'totals') {
    if (totalsRowIdx === -1) throw new Error('clickElement: no totals row found in spreadsheet.');
    rowIdx = totalsRowIdx;
  } else if (typeof row === 'number') {
    if (row < 0 || row >= dataRowIndices.length) throw new Error(`clickElement: row index ${row} out of range (0..${dataRowIndices.length - 1}).`);
    rowIdx = dataRowIndices[row];
  } else if (typeof row === 'object') {
    // Filter: { colName: value } — find first data row where column matches
    const filterEntries = Object.entries(row);
    const norm = s => s?.replace(/\u00a0/g, ' ').trim().toLowerCase() || '';
    const resolveCol = (name) => {
      if (colMap.has(name)) return colMap.get(name);
      const suffix = ' / ' + name;
      const available = colNames.filter(n => n);
      const m = available.find(n => n.endsWith(suffix)) || available.find(n => n.includes(name));
      return m ? colMap.get(m) : null;
    };
    rowIdx = dataRowIndices.find(i => {
      return filterEntries.every(([fCol, fVal]) => {
        const fColIdx = resolveCol(fCol);
        if (fColIdx == null) return false;
        const cellText = norm(rows[i][fColIdx]);
        const search = norm(fVal);
        return cellText === search || cellText.includes(search);
      });
    });
    if (rowIdx == null) throw new Error(`clickElement: no row matching ${JSON.stringify(row)} found in spreadsheet data.`);
  } else {
    throw new Error('clickElement: row must be a number, "totals", or { colName: value } filter object.');
  }

  // Map rows[] index → physical row number
  const physRow = sortedRows[rowIdx];
  const cellKey = `${physRow}_${physCol}`;
  const frame = frameMap.get(cellKey);
  if (!frame) {
    // Cell exists in mapping but might be empty — try clicking anyway
    throw new Error(`clickElement: cell at row=${JSON.stringify(target.row)}, column="${colName}" is empty or not rendered.`);
  }
  // Use [y]+[x] attributes — CSS class RxCy uses different numbering than y/x attrs.
  const cellDiv = frame.locator(`div[y="${physRow}"] div[x="${physCol}"]`).first();
  // Scroll cell into view using arrow keys — the only reliable way to scroll
  // 1C SpreadsheetDocument without desynchronizing headers, data, and scrollbar.
  await scrollSpreadsheetToCell(frame, physRow, physCol, cellDiv);
  const box = await cellDiv.boundingBox();
  if (!box) throw new Error(`clickElement: cell y=${physRow} x=${physCol} not visible (no bounding box).`);

  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
  if (modKey) await page.keyboard.down(modKey);
  if (dbl) {
    await page.mouse.dblclick(x, y);
  } else {
    await page.mouse.click(x, y);
  }
  if (modKey) await page.keyboard.up(modKey);

  await waitForStable();
  return returnFormState({ clicked: { kind: 'spreadsheetCell', row: target.row, column: colName, ...(dbl ? { dblclick: true } : {}) } });
}

/**
 * Search spreadsheet iframes for a cell matching text (for text fallback in clickElement).
 * Returns { frameIndex, physRow, physCol, box } or null if not found.
 */
export async function findSpreadsheetCellByText(formNum, searchText) {
  const { allCells, frameMap } = await scanSpreadsheetCells(formNum);
  if (allCells.size === 0) return null;

  const norm = s => s?.replace(/\u00a0/g, ' ').trim().toLowerCase() || '';
  const target = norm(searchText);

  // Exact match first, then includes
  let found = null;
  for (const [key, cell] of allCells) {
    if (norm(cell.t) === target) { found = { key, cell }; break; }
  }
  if (!found) {
    for (const [key, cell] of allCells) {
      if (norm(cell.t).includes(target)) { found = { key, cell }; break; }
    }
  }
  if (!found) return null;

  const frame = frameMap.get(found.key);
  if (!frame) return null;

  // Scroll cell into view using native arrow-key mechanism
  const cellDiv = frame.locator(`div[y="${found.cell.r}"] div[x="${found.cell.c}"]`).first();
  await scrollSpreadsheetToCell(frame, found.cell.r, found.cell.c, cellDiv);
  const box = await cellDiv.boundingBox();
  if (!box) return null;

  return { frame, physRow: found.cell.r, physCol: found.cell.c, text: found.cell.t, box };
}

/**
 * Read report output (SpreadsheetDocumentField) rendered in iframes.
 * 1C renders spreadsheet documents as absolutely-positioned div cells inside iframes.
 * Each cell is a div[x] inside a row div[y], text content in <span>.
 *
 * Returns structured data:
 *   { title, headers, data: [{col: val}], totals: {col: val}, total }
 * If header detection fails, falls back to { rows: string[][], total }.
 */
export async function readSpreadsheet() {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());

  const { allCells } = await scanSpreadsheetCells(formNum);

  if (allCells.size === 0) {
    // Check for state window messages (info bar) that explain why the report is empty
    const err = await checkForErrors();
    const hint = err?.stateText?.length ? err.stateText.join('; ') : '';
    throw new Error('readSpreadsheet: no SpreadsheetDocument found.' + (hint ? ' State: ' + hint : ' Report may not be generated yet.'));
  }

  const mapping = buildSpreadsheetMapping(allCells);
  if (!mapping) {
    // Fallback: return raw rows
    const rowMap = new Map();
    let maxCol = 0;
    for (const cell of allCells.values()) {
      if (!rowMap.has(cell.r)) rowMap.set(cell.r, new Map());
      rowMap.get(cell.r).set(cell.c, cell.t);
      if (cell.c > maxCol) maxCol = cell.c;
    }
    const sortedRows = [...rowMap.keys()].sort((a, b) => a - b);
    const rows = sortedRows.map(r => {
      const cm = rowMap.get(r);
      const arr = [];
      for (let c = 0; c <= maxCol; c++) arr.push(cm.get(c) || '');
      return arr;
    });
    return { rows, total: rows.length };
  }

  const { rows, colNames, dataStartIdx, maxCol, groupRowIdx, headerRowIdx, superRowIdx, hasNumber, nonEmpty } = mapping;

  // Convert data rows to objects
  const data = [];
  let totals = null;
  const toObj = (row) => {
    const obj = {};
    for (let c = 0; c < colNames.length; c++) {
      if (colNames[c] && row[c]) obj[colNames[c]] = row[c];
    }
    return obj;
  };

  for (let i = dataStartIdx; i < rows.length; i++) {
    if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
    const first = rows[i][0]?.trim().toLowerCase();
    if (first === 'итого' || first === 'всего') {
      totals = toObj(rows[i]);
    } else {
      data.push(toObj(rows[i]));
    }
  }

  // Meta: title, params, filters from rows before header (superRow is part of header, not meta)
  const metaEnd = superRowIdx >= 0 ? superRowIdx : (groupRowIdx >= 0 ? groupRowIdx : headerRowIdx);
  let title = '';
  const meta = [];
  for (let i = 0; i < metaEnd; i++) {
    const parts = rows[i].filter(c => c);
    if (!parts.length) continue;
    if (!title) { title = parts.join(' '); continue; }
    meta.push(parts.join(' '));
  }

  return {
    title: title || undefined,
    meta: meta.length ? meta : undefined,
    headers: colNames.filter(n => n),
    data,
    totals: totals || undefined,
    total: data.length,
  };
}
