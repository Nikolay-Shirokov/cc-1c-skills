// web-test dom/filter v1.1 — DOM scripts for filterList / unfilterList
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { COLUMN_MODEL_FN } from './_shared.mjs';

/**
 * Find the first grid cell on the form and return its center coords.
 * Used as a fallback target for Alt+F when there's no search input.
 *
 * Returns `{ x, y } | null`.
 */
export function findFirstGridCellCoordsScript(formNum) {
  return `(() => {
    const p = 'form${formNum}_';
    const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0);
    if (!grid) return null;
    const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
    if (!rows.length) return null;
    const cells = [...rows[0].querySelectorAll('.gridBox')];
    if (!cells.length) return null;
    const r = cells[0].getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Find the grid cell of the first row in the column whose header text matches `field`
 * (fuzzy: exact → startsWith → includes; normalizes ё/е and NBSP).
 *
 * If the column isn't in the grid, returns coords of the first cell + `needDlb: true`
 * so the caller can use DLB to switch FieldSelector after opening the dialog.
 *
 * Returns:
 *   - `{ x, y, needDlb? } `      — coords to click (advanced search target)
 *   - `{ error }`                — `'no_grid' | 'no_rows' | 'no_cells' | 'cell_not_found'`
 */
export function findColumnFirstCellCoordsScript(formNum, field) {
  return `(() => {
    const p = 'form${formNum}_';
    const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0);
    if (!grid) return { error: 'no_grid' };
    ${COLUMN_MODEL_FN}
    const targetField = ${JSON.stringify(field)};
    const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
    if (!rows.length) return { error: 'no_rows' };

    // Column resolution — shared model (dom/_shared.mjs), same as readTable/click. The old
    // positional index (Nth header box → Nth cell box) breaks on multi-row headers, where
    // header and cell counts and order differ.
    const model = buildColumnModel(grid);
    const col = resolveColumnByName(model, targetField);
    if (!col) {
      // Unknown column → click the first cell and let the caller fall back to DLB.
      const cells = [...rows[0].querySelectorAll('.gridBox')];
      if (!cells.length) return { error: 'no_cells' };
      const r0 = cells[0].getBoundingClientRect();
      return { x: Math.round(r0.x + r0.width / 2), y: Math.round(r0.y + r0.height / 2), needDlb: true };
    }
    const cell = cellForColumn(model, rows[0], col);
    if (!cell) return { error: 'cell_not_found' };
    const r = cell.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Read FieldSelector input + its DLB button coords on the advanced search dialog.
 * Returns `{ current, dlbX, dlbY }` (zero coords if DLB not visible).
 */
export function readFieldSelectorInfoScript(dialogForm) {
  return `(() => {
    const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
    const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
    const dlb = document.getElementById(p + 'FieldSelector_DLB');
    return {
      current: fsInput?.value?.trim() || '',
      dlbX: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().x + dlb.getBoundingClientRect().width / 2) : 0,
      dlbY: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().y + dlb.getBoundingClientRect().height / 2) : 0
    };
  })()`;
}

/**
 * Pick a field name in the FieldSelector EDD dropdown (fuzzy: exact → includes,
 * normalizes ё/е and NBSP).
 *
 * Returns:
 *   - `{ x, y, name }`           — coords + matched name to click
 *   - `{ error, available? }`    — `'no_dropdown'` or `'field_not_found'` with list of available names
 */
export function pickFieldInSelectorDropdownScript(field) {
  return `(() => {
    const edd = document.getElementById('editDropDown');
    if (!edd || edd.offsetWidth === 0) return { error: 'no_dropdown' };
    const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
    const target = ny(${JSON.stringify(field.toLowerCase())});
    const items = [...edd.querySelectorAll('div')].filter(el =>
      el.offsetWidth > 0 && el.innerText?.trim() && !el.innerText.includes('\\n'));
    const match = items.find(el => ny(el.innerText.trim().toLowerCase()) === target)
      || items.find(el => ny(el.innerText.trim().toLowerCase()).includes(target));
    if (!match) return { error: 'field_not_found', available: items.map(el => el.innerText.trim()) };
    const r = match.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), name: match.innerText.trim() };
  })()`;
}

/**
 * Read advanced search dialog state — FieldSelector value, Pattern input id+value,
 * and field type flags (isDate via iCalendB button, isRef via iDLB button on Pattern).
 *
 * Returns `{ fieldSelector, patternValue, patternId, isDate, isRef }`.
 */
export function readFilterDialogInfoScript(dialogForm) {
  return `(() => {
    const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
    const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
    const ptInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Pattern/i.test(el.id));
    const ptLabel = ptInput?.closest('label');
    const btns = ptLabel ? [...ptLabel.querySelectorAll('span.btn')].map(b => b.className) : [];
    const isDate = btns.some(c => c.includes('iCalendB'));
    const isRef = !isDate && btns.some(c => c.includes('iDLB'));
    return {
      fieldSelector: fsInput?.value?.trim() || '',
      patternValue: ptInput?.value?.trim() || '',
      patternId: ptInput?.id || '',
      isDate,
      isRef
    };
  })()`;
}

/**
 * Find the × close button on the filter badge whose title matches `field`
 * (exact → includes; normalizes ё/е and NBSP).
 *
 * Returns:
 *   - `{ x, y, field }`          — coords + actual field title from the badge
 *   - `{ error, available }`     — `'not_found'` with list of available badge titles
 */
export function findFilterBadgeCloseScript(formNum, field) {
  return `(() => {
    const p = 'form${formNum}_';
    const norm = s => s?.trim().replace(/\\u00a0/g, ' ').replace(/:$/, '').replace(/\\n/g, ' ') || '';
    const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
    const target = ny(${JSON.stringify(field.toLowerCase())});
    const items = [...document.querySelectorAll('[id^="' + p + '"].trainItem')].filter(el => el.offsetWidth > 0);
    for (const item of items) {
      const titleEl = item.querySelector('.trainName');
      const title = ny(norm(titleEl?.innerText).toLowerCase());
      if (title === target || title.includes(target)) {
        const close = item.querySelector('.trainClose');
        if (close) {
          const r = close.getBoundingClientRect();
          return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), field: norm(titleEl?.innerText) };
        }
      }
    }
    const available = items.map(item => norm(item.querySelector('.trainName')?.innerText));
    return { error: 'not_found', available };
  })()`;
}

/**
 * Find the × close button on the FIRST visible filter badge (for clear-all loop).
 * Returns `{ x, y } | null`.
 */
export function findFirstFilterBadgeCloseScript(formNum) {
  return `(() => {
    const p = 'form${formNum}_';
    const item = [...document.querySelectorAll('[id^="' + p + '"].trainItem')]
      .find(el => el.offsetWidth > 0);
    if (!item) return null;
    const close = item.querySelector('.trainClose');
    if (!close) return null;
    const r = close.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}
