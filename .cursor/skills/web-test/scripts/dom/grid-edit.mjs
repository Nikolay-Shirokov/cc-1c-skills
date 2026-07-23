// web-test dom/grid-edit v1.3 — DOM scripts for row-fill (grid edit-time operations)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
import { HEADERLESS_GRID_FN, COLUMN_MODEL_FN } from './_shared.mjs';
//
// All helpers below accept an optional `gridSelector`. When passed, they target
// that exact grid; when null/undefined they pick the LAST visible `.grid` on
// the page (this matches the implicit "current grid" used by row-fill).

/** Inline JS fragment that resolves the target grid into `const grid`. */
function gridResolver(gridSelector) {
  return gridSelector
    ? `document.querySelector(${JSON.stringify(gridSelector)})`
    : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`;
}

/**
 * Read the grid's column header texts paired with their `colindex` attribute,
 * fuzzy-match `fieldKeys` (lowercased) against them, and return the keys in
 * left-to-right colindex order.
 *
 * Keys that don't match a column get colindex `999` (pushed to the end);
 * caller is expected to preserve their original relative order.
 *
 * Returns `string[] | null` (null when no grid or no head).
 */
export function sortFieldKeysByColindexScript(gridSelector, fieldKeys) {
  return `(() => {
    ${HEADERLESS_GRID_FN}
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const head = grid.querySelector('.gridHead');
    const cols = [];
    if (head) {
      const headLine = head.querySelector('.gridLine') || head;
      [...headLine.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const t = ((box.querySelector('.gridBoxText') || box).innerText?.trim() || '').toLowerCase();
        const ci = parseInt(box.getAttribute('colindex') || '-1');
        if (t) cols.push({ text: t, colindex: ci });
      });
    } else {
      // Headerless: synthesized columns (КолонкаN/(checkbox)) ordered by colindex
      synthHeaderlessColumns(grid).forEach(c => cols.push({ text: c.name.toLowerCase(), colindex: parseInt(c.colindex) }));
    }
    const keys = ${JSON.stringify(fieldKeys)};
    const mapped = keys.map(k => {
      const exact = cols.find(c => c.text === k);
      if (exact) return { key: k, colindex: exact.colindex };
      const inc = cols.find(c => c.text.includes(k) || k.includes(c.text));
      return { key: k, colindex: inc ? inc.colindex : 999 };
    });
    mapped.sort((a, b) => a.colindex - b.colindex);
    return mapped.map(m => m.key);
  })()`;
}

/**
 * Resolve cell coords for row `row` by matching the first column whose header
 * fuzzy-matches any of `fieldKeys` (lowercased). Falls back to the second
 * visible (non-`.gridBoxComp`) box when no header matches.
 *
 * Returns one of:
 *   - `{ x, y, currentText }`                                  — coords + cell text
 *   - `{ error: 'no_grid' | 'no_grid_body' | 'no_cell' }`
 *   - `{ error: 'row_out_of_range', total }`
 */
export function findCellCoordsByFieldsScript(gridSelector, row, fieldKeys) {
  return `(() => {
    ${COLUMN_MODEL_FN}
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return { error: 'no_grid' };
    const body = grid.querySelector('.gridBody');
    if (!body) return { error: 'no_grid_body' };

    // Column resolution — shared model (dom/_shared.mjs): same names and same physical cell
    // as readTable/click report, including «Имя 1/2/3» of an expanded merged header.
    const model = buildColumnModel(grid);
    const keys = ${JSON.stringify(fieldKeys)};
    let targetCol = null;
    for (const key of keys) {
      targetCol = resolveColumnByName(model, key);
      if (targetCol) break;
    }
    const targetSub = targetCol ? (targetCol.subTarget || null) : null;

    const rows = [...body.querySelectorAll('.gridLine')];
    if (${row} >= rows.length) return { error: 'row_out_of_range', total: rows.length };
    const line = rows[${row}];

    let box = targetCol ? cellForColumn(model, line, targetCol) : null;
    // Fallback: second visible box (skip checkbox/N column)
    if (!box) {
      const boxes = [...line.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
      box = boxes.length > 1 ? boxes[1] : boxes[0];
    }
    if (!box) return { error: 'no_cell' };
    box.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    // subTarget-aware cell node: 'checkbox' → box itself (row-fill then uses findCheckboxAtPoint),
    // 'title' → .gridBoxTitle, else (headed default / 'text') → .gridBoxText || box.
    let cell;
    if (targetSub === 'checkbox') cell = box;
    else if (targetSub === 'title') cell = box.querySelector('.gridBoxTitle') || box;
    else cell = box.querySelector('.gridBoxText') || box;
    const r = cell.getBoundingClientRect();
    const currentText = (cell.innerText?.trim() || '').replace(/\\u00a0/g, ' ');
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), currentText };
  })()`;
}

/**
 * Like `findCellCoordsByFieldsScript` but for a SINGLE key, with extra
 * "no-space/no-dash" fuzzy fallback (e.g. "Группа Контрагентов" header matches
 * key "ГруппаКонтрагентов").
 *
 * Returns `{ x, y, currentText } | null`.
 */
export function findNextCellCoordsByKeyScript(gridSelector, row, key) {
  return `(() => {
    ${COLUMN_MODEL_FN}
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const model = buildColumnModel(grid);
    const kl = ${JSON.stringify(key.toLowerCase())};
    // Extra "no-space/no-dash" fuzz on top of the shared resolver: header «Группа Контрагентов»
    // must match the key «ГруппаКонтрагентов».
    let targetCol = resolveColumnByName(model, kl);
    if (!targetCol) {
      const squash = s => (s || '').toLowerCase().replace(/ё/g, 'е').replace(/[\\s\\-]+/g, '');
      const klNoSpace = squash(kl);
      targetCol = model.columns.find(c => {
        const t = squash(c.name);
        return t && (t.includes(klNoSpace) || klNoSpace.includes(t));
      }) || null;
    }
    if (!targetCol) return null;
    const targetSub = targetCol.subTarget || null;
    const rows = [...body.querySelectorAll('.gridLine')];
    if (${row} >= rows.length) return null;
    const line = rows[${row}];
    const box = cellForColumn(model, line, targetCol);
    if (!box) return null;
    box.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    let cell;
    if (targetSub === 'checkbox') cell = box;
    else if (targetSub === 'title') cell = box.querySelector('.gridBoxTitle') || box;
    else cell = box.querySelector('.gridBoxText') || box;
    const r = cell.getBoundingClientRect();
    const currentText = (cell.innerText?.trim() || '').replace(/\\u00a0/g, ' ');
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), currentText };
  })()`;
}

/**
 * Inspect the element at point `(x, y)`. If it's inside a `.gridBox` containing
 * a `.checkbox`, return `{ checked, x, y }` (coords of the checkbox center for
 * direct click).
 *
 * Returns `null` when there's no cell, or the cell isn't a checkbox cell.
 */
export function findCheckboxAtPointScript(x, y) {
  return `(() => {
    const el = document.elementFromPoint(${x}, ${y});
    const cell = el?.closest('.gridBox');
    if (!cell) return null;
    const chk = cell.querySelector('.checkbox');
    if (!chk) return null;
    const r = chk.getBoundingClientRect();
    return { checked: chk.classList.contains('select'), x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) };
  })()`;
}

/**
 * Find center coords of the first VISIBLE non-`.gridBoxComp` cell on a row
 * OTHER than `row` (used to commit an edit by clicking off the edited row —
 * Escape would cancel in tree grids).
 *
 * For `row === 0`, targets row 1; otherwise targets row 0.
 *
 * Returns `{ x, y } | null` (null when there's no other row).
 */
export function findRowCommitClickCoordsScript(gridSelector, row) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const rows = [...body.querySelectorAll('.gridLine')];
    const otherIdx = ${row} === 0 ? 1 : 0;
    const other = rows[otherIdx];
    if (!other) return null;
    const visBoxes = [...other.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
    const box = visBoxes.length > 1 ? visBoxes[1] : visBoxes[0];
    if (!box) return null;
    const r = box.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Diagnostic: are we in grid edit mode (active INPUT inside `.grid` or
 * `.gridContent`)? Returns an OBJECT (not a boolean) suitable for diagnostics:
 *   - `{ inEdit: true }`                       — good
 *   - `{ inEdit: false, tag: 'DIV' }`          — active element wasn't INPUT
 *   - `{ inEdit: false, hint: 'input not inside grid' }` — input but no grid ancestor
 */
export function getGridEditCheckScript() {
  return `(() => {
    const f = document.activeElement;
    if (!f || f.tagName !== 'INPUT') return { inEdit: false, tag: f?.tagName };
    let node = f;
    while (node) {
      if (node.classList?.contains('grid') || node.classList?.contains('gridContent')) return { inEdit: true };
      node = node.parentElement;
    }
    return { inEdit: false, hint: 'input not inside grid' };
  })()`;
}

/**
 * Read the currently focused element if it's an editable grid cell (INPUT or
 * TEXTAREA inside `.grid` / `.gridContent`). Resolves the header text by
 * matching x-overlap of the input's bounding rect against header boxes.
 *
 * Returns one of:
 *   - `{ tag: 'INPUT', id, fullName, headerText }`   — editable cell
 *   - `{ tag: 'DIV' | 'BODY' | ... }`                 — focused but not an editable cell
 *   - `{ tag: 'none' }`                                — nothing focused
 *
 * `fullName` strips both `form{N}_` prefix and `_i{M}` suffix.
 */
export function readActiveGridCellScript() {
  return `(() => {
    ${HEADERLESS_GRID_FN}
    const f = document.activeElement;
    if (!f) return { tag: 'none' };
    if (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA') {
      const inGrid = (() => { let n = f; while (n) { if (n.classList?.contains('grid') || n.classList?.contains('gridContent')) return true; n = n.parentElement; } return false; })();
      if (inGrid) {
        let headerText = '';
        let grid = f; while (grid && !grid.classList?.contains('grid')) grid = grid.parentElement;
        if (grid) {
          const fr = f.getBoundingClientRect();
          const head = grid.querySelector('.gridHead');
          const hl = head?.querySelector('.gridLine') || head;
          if (hl) for (const h of hl.children) {
            if (h.offsetWidth === 0) continue;
            const hr = h.getBoundingClientRect();
            if (fr.x >= hr.x && fr.x < hr.x + hr.width) {
              const t = h.querySelector('.gridBoxText');
              headerText = (t || h).innerText?.trim() || '';
              break;
            }
          }
          if (!head) {
            // Headerless: the editing INPUT is rendered in an overlay (.inputs) OUTSIDE
            // the .gridBox, so walking ancestors for colindex fails. Resolve colindex by
            // matching the input's x against the body cells (same idea as the headed branch).
            const bl = grid.querySelector('.gridBody .gridLine');
            let ci = null;
            if (bl) for (const b of bl.children) {
              if (b.offsetWidth === 0) continue;
              const br = b.getBoundingClientRect();
              if (fr.x >= br.x && fr.x < br.x + br.width) { ci = b.getAttribute('colindex'); break; }
            }
            if (ci != null) {
              const sc = synthHeaderlessColumns(grid).find(c => c.kind === 'data' && c.colindex === ci);
              if (sc) headerText = sc.name;
            }
          }
        }
        // Classify the cell's choice button (if any): ref (_DLB), calc/date (_CB iCalcB/iCalendB),
        // or bare 'choice' (_CB iCB — value picked from a programmatic list, e.g. НачалоВыбора).
        let buttonKind = null;
        const base = f.id.replace(/_i\\d+$/, '');
        const dlb = document.getElementById(base + '_DLB');
        const cb = document.getElementById(base + '_CB');
        if (dlb && dlb.offsetWidth > 0) buttonKind = 'ref';
        else if (cb && cb.offsetWidth > 0) {
          if (cb.classList.contains('iCalcB')) buttonKind = 'calc';
          else if (cb.classList.contains('iCalendB')) buttonKind = 'date';
          else buttonKind = 'choice';
        }
        return {
          tag: 'INPUT', id: f.id,
          fullName: f.id.replace(/^form\\d+_/, '').replace(/_i\\d+$/, ''),
          headerText, buttonKind
        };
      }
    }
    return { tag: f.tagName || 'none' };
  })()`;
}

/**
 * Return center coords of the element with the given id.
 * Returns `{ x, y } | null`.
 */
export function getElementCenterCoordsByIdScript(elementId) {
  return `(() => {
    const el = document.getElementById(${JSON.stringify(elementId)});
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()`;
}
