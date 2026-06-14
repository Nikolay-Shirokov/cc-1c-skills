// web-test dom/grid v1.9 — grid resolution + table reading + edit-time helpers
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Resolve a specific grid by semantic name (table parameter).
 * Cascade: exact gridName match → gridName contains → column contains.
 * Returns { gridSelector, gridId, gridName, gridIndex, columns } or { error, available }.
 */
export function resolveGridScript(formNum, tableName) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const target = ${JSON.stringify(tableName.toLowerCase().replace(/ё/g, 'е'))};
    const norm = s => (s || '').replace(/ё/gi, 'е');
    const allGrids = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .filter(g => g.offsetWidth > 0 && g.offsetHeight > 0);
    if (!allGrids.length) return { error: 'no_grids', message: 'No grids found on form' };
    const infos = allGrids.map((g, idx) => {
      const gridId = g.id || '';
      const gridName = gridId.replace(p, '');
      const head = g.querySelector('.gridHead');
      const columns = [];
      if (head) {
        const headLine = head.querySelector('.gridLine') || head;
        [...headLine.children].forEach(box => {
          if (box.offsetWidth === 0) return;
          const textEl = box.querySelector('.gridBoxText');
          const text = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
          if (text) columns.push(text);
        });
      }
      // Visual label from group title element
      const titleEl = document.getElementById(p + gridName + '#title_div')
                   || document.getElementById(p + 'Группа' + gridName + '#title_div');
      const label = titleEl ? (titleEl.innerText?.trim().replace(/:\s*$/, '').replace(/ /g, ' ') || '') : '';
      return { idx, gridId, gridName, label, columns, el: g };
    });
    // 1. Exact gridName match (case-insensitive)
    let found = infos.find(i => norm(i.gridName).toLowerCase() === target);
    // 2. Exact label match
    if (!found) found = infos.find(i => i.label && norm(i.label).toLowerCase() === target);
    // 3. gridName contains target
    if (!found) found = infos.find(i => norm(i.gridName).toLowerCase().includes(target));
    // 4. Label contains target
    if (!found) found = infos.find(i => i.label && norm(i.label).toLowerCase().includes(target));
    // 5. Any column contains target
    if (!found) found = infos.find(i => i.columns.some(c => norm(c).toLowerCase().includes(target)));
    if (found) {
      return {
        gridSelector: found.gridId ? '#' + CSS.escape(found.gridId) : null,
        gridId: found.gridId,
        gridName: found.gridName,
        gridIndex: found.idx,
        columns: found.columns
      };
    }
    return {
      error: 'not_found',
      message: 'Table "' + ${JSON.stringify(tableName)} + '" not found',
      available: infos.map(i => ({ name: i.gridName, ...(i.label ? { label: i.label } : {}), columns: i.columns }))
    };
  })()`;
}

/**
 * Read table/grid data with pagination.
 * Parses grid.innerText — \n separates rows, \t separates cells.
 * First row = column headers.
 * Returns { name, columns[], rows[{col:val}], total, offset, shown }.
 */
export function readTableScript(formNum, { maxRows = 20, offset = 0, gridSelector } = {}) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `[...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0 && g.offsetHeight > 0)`};
    if (!grid) return { error: 'no_table', message: 'No table found on form ${formNum}' };
    const name = grid.id ? grid.id.replace(p, '') : '';

    // Detect a "picture value" cell: a sprite from a picture collection
    // (.gridBoxImg .dIB with background-image .../pictureCollection/picture/<id>?...&gx=<N>).
    // Excludes decorative tree/group markers (gridListH/gridListV/[tree]/gridBoxTree).
    // Returns { gx } — the sprite frame index that encodes the cell state, or null.
    function picInfo(cell) {
      if (!cell) return null;
      if (cell.querySelector('.gridListH, .gridListV, [tree="true"], .gridBoxTree')) return null;
      const dib = cell.querySelector('.gridBoxImg .dIB');
      if (!dib) return null;
      const bg = dib.style.backgroundImage || '';
      if (!bg.includes('pictureCollection/picture/')) return null;
      const m = bg.match(/[?&]gx=(\\d+)/);
      return { gx: m ? m[1] : '0' };
    }

    // DOM-based parsing: gridHead → columns, gridBody → gridLine rows → gridBox cells
    const head = grid.querySelector('.gridHead');
    const body = grid.querySelector('.gridBody');
    if (!head || !body) {
      // Fallback: innerText-based (for non-standard grids)
      const gText = grid.innerText?.trim() || '';
      const lines = gText.split('\\n').filter(Boolean);
      return { name, columns: [], rows: [], total: lines.length, offset: 0, shown: 0,
               hint: 'Grid has no gridHead/gridBody structure' };
    }

    // Extract column headers with X-coordinates for alignment
    const columns = [];
    const headLine = head.querySelector('.gridLine') || head;
    [...headLine.children].forEach(box => {
      if (box.offsetWidth === 0) return;
      const textEl = box.querySelector('.gridBoxText');
      const text = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
      if (!text) {
        // Unnamed column — check if data cells contain checkboxes or pictures.
        // Picture columns have no header text (only an icon + a title tooltip); 1С
        // doesn't expose the technical column name in the DOM, so we name them by
        // the header's title attribute, falling back to '(picture)'.
        const firstLine = body?.querySelector('.gridLine');
        const visibleHeaders = [...headLine.children].filter(c => c.offsetWidth > 0);
        const idx = visibleHeaders.indexOf(box);
        const cells = firstLine ? [...firstLine.children].filter(c => c.offsetWidth > 0) : [];
        const r = box.getBoundingClientRect();
        if (cells[idx]?.querySelector('.checkbox')) {
          columns.push({ text: '(checkbox)', x: r.x, w: r.width, right: r.x + r.width, y: r.y, h: r.height });
        } else if (picInfo(box) || picInfo(cells[idx])) {
          let title = (box.getAttribute('title') || '').trim() || '(picture)';
          // Disambiguate duplicate picture-column names with a numeric suffix.
          if (columns.some(c => c.text === title)) {
            let n = 2;
            while (columns.some(c => c.text === title + ' ' + n)) n++;
            title = title + ' ' + n;
          }
          columns.push({ text: title, x: r.x, w: r.width, right: r.x + r.width, y: r.y, h: r.height });
        }
        return;
      }
      const r = box.getBoundingClientRect();
      columns.push({ text, x: r.x, w: r.width, right: r.x + r.width, y: r.y, h: r.height });
    });

    // Multi-row grid support: detect stacked/merged headers.
    // Group headers by X-range. For each group, count data sub-rows from first line.
    // - Stacked headers (2+ headers at same X) with multiple data rows → match by Y-order
    // - Single merged header with multiple data rows → expand to numbered columns (e.g. "Субконто Дт 1")
    const xGroups = new Map();
    columns.forEach(c => {
      const key = Math.round(c.x) + ':' + Math.round(c.right);
      if (!xGroups.has(key)) xGroups.set(key, []);
      xGroups.get(key).push(c);
    });
    for (const [, hdrs] of xGroups) hdrs.sort((a, b) => a.y - b.y);

    const firstDataLine = body?.querySelector('.gridLine');
    const subRowMap = new Map();
    if (firstDataLine) {
      [...firstDataLine.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const r = box.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        for (const [key, hdrs] of xGroups) {
          const h0 = hdrs[0];
          if (cx >= h0.x && cx < h0.right) {
            if (!subRowMap.has(key)) subRowMap.set(key, []);
            subRowMap.get(key).push({ y: r.y });
            break;
          }
        }
      });
      for (const [, subs] of subRowMap) subs.sort((a, b) => a.y - b.y);
    }

    const multiRowGroups = new Map();
    for (const [key, hdrs] of xGroups) {
      const subs = subRowMap.get(key);
      if (!subs || subs.length <= 1) continue;
      if (hdrs.length >= 2) {
        multiRowGroups.set(key, hdrs);
      } else if (hdrs.length === 1 && subs.length > 1) {
        const base = hdrs[0];
        const baseIdx = columns.indexOf(base);
        columns.splice(baseIdx, 1);
        const expanded = [];
        for (let si = 0; si < subs.length; si++) {
          const numbered = {
            text: base.text + ' ' + (si + 1),
            x: base.x, w: base.w, right: base.right,
            y: base.y + si, h: base.h / subs.length, _subIdx: si
          };
          columns.splice(baseIdx + si, 0, numbered);
          expanded.push(numbered);
        }
        multiRowGroups.set(key, expanded);
      }
    }

    function matchColumn(cellX, cellW, cellY) {
      const cx = cellX + cellW / 2;
      for (const [key, hdrs] of multiRowGroups) {
        const h0 = hdrs[0];
        if (cx >= h0.x && cx < h0.right) {
          const subs = subRowMap.get(key);
          if (subs) {
            const subIdx = subs.findIndex(s => Math.abs(s.y - cellY) < 5);
            if (subIdx >= 0 && subIdx < hdrs.length) return hdrs[subIdx];
          }
          let best = hdrs[0], bestDist = Infinity;
          for (const h of hdrs) {
            const dist = Math.abs(cellY - h.y);
            if (dist < bestDist) { bestDist = dist; best = h; }
          }
          return best;
        }
      }
      return columns.find(c => cx >= c.x && cx < c.right);
    }

    // Extract data rows from gridBody
    const allLines = body.querySelectorAll('.gridLine');
    const total = allLines.length;
    const rows = [];
    const end = Math.min(${offset} + ${maxRows}, total);
    for (let i = ${offset}; i < end; i++) {
      const line = allLines[i];
      if (!line) break;
      const row = {};
      columns.forEach(c => { row[c.text] = ''; });
      [...line.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const textEl = box.querySelector('.gridBoxText');
        const chk = box.querySelector('.checkbox');
        let val;
        if (chk) {
          val = chk.classList.contains('select') ? 'true' : 'false';
        } else {
          val = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
          if (!val) {
            // Empty text → maybe a picture cell. 'pic:<gx>' encodes the sprite frame
            // (state). Absent picture stays '' (truthy check distinguishes presence).
            const pic = picInfo(box);
            if (pic) val = 'pic:' + pic.gx;
            else return;
          }
        }
        // Match cell to column by X+Y overlap (multi-row aware)
        const r = box.getBoundingClientRect();
        const col = matchColumn(r.x, r.width, r.y);
        if (col) {
          row[col.text] = row[col.text] ? row[col.text] + ' / ' + val : val;
        }
      });
      // Detect row kind: group (gridListH), parent/up (gridListV), or element
      const imgBox = line.querySelector('.gridBoxImg');
      if (imgBox) {
        if (imgBox.querySelector('.gridListH')) row._kind = 'group';
        else if (imgBox.querySelector('.gridListV')) row._kind = 'parent';
      }
      // Tree mode: detect expand/collapse state and indent level
      const treeBox = line.querySelector('.gridBoxTree');
      if (treeBox) {
        const treeIcon = imgBox?.querySelector('[tree="true"]');
        if (treeIcon) {
          const bg = treeIcon.style.backgroundImage || '';
          row._tree = bg.includes('gx=0') ? 'expanded' : 'collapsed';
        }
        row._level = imgBox ? imgBox.querySelectorAll('.dIB').length - 1 : 0;
      }
      // Selection state: selRow = selected row in grid
      if (line.classList.contains('selRow') || line.classList.contains('select')) row._selected = true;
      rows.push(row);
    }
    const isTree = !!body.querySelector('.gridBoxTree');
    const hasGroups = rows.some(r => r._kind === 'group');
    // Virtualization-aware hasMore signal. Three sources in priority order:
    //  1. Dynamic-list turn buttons (#vertButtonScroll_<gridId>, sibling of grid).
    //     Buttons carry data-home/data-up (above) and data-down/data-end (below);
    //     class "disabled" on a direction means nothing to show there.
    //  2. Tabular-section scrollbar (#vertScroll_<gridId>, class scrollV) —
    //     track-back/track-next pixel heights tell us above/below precisely.
    //  3. Fallback: scrollHeight>clientHeight for "below"; "above" unknown.
    let hasMore;
    const turnsBox = document.getElementById('vertButtonScroll_' + grid.id);
    if (turnsBox && turnsBox.offsetHeight > 0) {
      const upBtns = turnsBox.querySelectorAll('[data-home], [data-up]');
      const dnBtns = turnsBox.querySelectorAll('[data-down], [data-end]');
      hasMore = {
        above: [...upBtns].some(b => !b.classList.contains('disabled')),
        below: [...dnBtns].some(b => !b.classList.contains('disabled')),
      };
    } else {
      const vsId = 'vertScroll_' + grid.id;
      const vs = document.getElementById(vsId);
      if (vs && vs.classList.contains('scrollV') && vs.offsetWidth > 0) {
        const back = vs.querySelector('[data-track-back]')?.offsetHeight ?? 0;
        const next = vs.querySelector('[data-track-next]')?.offsetHeight ?? 0;
        hasMore = { above: back > 0, below: next > 0 };
      } else {
        hasMore = { below: body.scrollHeight > body.clientHeight };
      }
    }
    const result = { name, columns: columns.map(c => c.text), rows, total, offset: ${offset}, shown: rows.length, hasMore };
    if (isTree) result.viewMode = 'tree';
    if (hasGroups) result.hierarchical = true;
    return result;
  })()`;
}

// ─── Edit-time grid helpers (for fillTableRow / row-fill) ────────────────────
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
 * Find center coords of a target row for click-select (used by deleteTableRow).
 * Picks the second visible gridBox container in the row (skips row-number/checkbox col).
 *
 * Returns `{ x, y, total } | { error: 'no_grid'|'no_grid_body'|'row_out_of_range'|'no_cell', total? }`.
 */
export function findDeleteRowCoordsScript(gridSelector, row) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
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
  })()`;
}

/**
 * Count `.gridLine` rows in the body of the target grid.
 * Returns the row count, or `0` when grid/body absent.
 */
export function countGridRowsScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    const body = grid?.querySelector('.gridBody');
    return body ? body.querySelectorAll('.gridLine').length : 0;
  })()`;
}

/**
 * Is the target grid a tree grid? (presence of `.gridBoxTree`)
 * Returns boolean.
 */
export function isTreeGridScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    return grid ? !!grid.querySelector('.gridBoxTree') : false;
  })()`;
}

/**
 * Return center coords of the grid's `.gridHead` element.
 * Used as a click target to commit a pending cell edit (clicking the header
 * defocuses the input without selecting another row).
 *
 * Returns `{ x, y } | null`.
 */
export function findGridHeadCenterCoordsScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const head = grid.querySelector('.gridHead');
    if (!head) return null;
    const r = head.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Return the index of the currently selected row in the target grid, or
 * fall back to the last row when nothing is selected.
 *
 * Returns row index, or `-1` when no rows.
 */
export function getSelectedOrLastRowIndexScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return -1;
    const body = grid.querySelector('.gridBody');
    if (!body) return -1;
    const lines = [...body.querySelectorAll('.gridLine')];
    const sel = lines.findIndex(l => l.classList.contains('selected'));
    return sel >= 0 ? sel : lines.length - 1;
  })()`;
}

/**
 * Scan a form's grid for a row matching `searchLower` (case- and ё-insensitive,
 * NBSP-normalised). Match order: exact → startsWith → includes.
 *
 * When `searchLower` is empty, returns coords of the first row (fallback).
 *
 * Returns `{ rowCount, x, y, isGroup } | { rowCount: 0 } | null`.
 */
export function scanGridRowsScript(formNum, searchLower) {
  return `(() => {
    const p = 'form${formNum}_';
    const grid = document.querySelector('[id^="' + p + '"].grid, [id^="' + p + '"] .grid');
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const lines = [...body.querySelectorAll('.gridLine')];
    if (!lines.length) return { rowCount: 0 };
    const searchLower = ${JSON.stringify(searchLower || '')};
    let sel = null;
    if (searchLower) {
      const norm = s => (s || '').replace(/\\u00a0/g, ' ').trim().toLowerCase().replace(/ё/gi, 'е');
      const rowData = lines.map(l => ({ el: l, text: norm(l.innerText) }));
      sel = rowData.find(r => r.text === searchLower)?.el
        || rowData.find(r => r.text.startsWith(searchLower))?.el
        || rowData.find(r => r.text.includes(searchLower))?.el;
    } else {
      sel = lines[0]; // empty search → first row
    }
    if (!sel) return null;
    const imgBox = sel.querySelector('.gridBoxImg');
    const isGroup = imgBox ? !!imgBox.querySelector('.gridListH') : false;
    const r = sel.getBoundingClientRect();
    return { rowCount: lines.length, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), isGroup };
  })()`;
}

// ─── Cell-click DOM scripts (for clickElement({row, column}) on grids) ───────

/**
 * Resolve a target cell in a grid by (row, column).
 *  - `column` matched: exact (case+ё-insensitive) → endsWith ' / X' → includes.
 *  - `row`: number = index in current DOM window; object = {col: value, ...} filter
 *    (matches first non-group/parent row where every column condition passes).
 *
 * Returns `{ x, y, cellX, cellRight, gridX, gridRight, columnText, rowIdx, cellText, visible } | { error, ... }`.
 *
 * Visibility (`visible`) is true when the cell is fully within the grid's horizontal viewport.
 * Callers should horizontally scroll first if `visible === false`.
 */
export function findGridCellScript(formNum, gridSelector, { row, column }) {
  const p = `form${formNum}_`;
  return `(() => {
    const norm = s => (s || '').replace(/\\u00a0/g, ' ').replace(/ё/gi, 'е').trim();
    const lo = s => norm(s).toLowerCase();

    const p = ${JSON.stringify(p)};
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `[...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
           .find(g => g.offsetWidth > 0 && g.offsetHeight > 0)`};
    if (!grid) return { error: 'no_grid' };
    const head = grid.querySelector('.gridHead');
    const body = grid.querySelector('.gridBody');
    if (!head || !body) return { error: 'no_grid_structure' };

    // Header X-ranges (mirror of readTableScript logic, simplified). We also
    // remember whether each header is frozen (gridBoxFix) — frozen and scrollable
    // columns can share X coordinates after horizontal scroll, so cell matching
    // must respect the frozen/scrollable partition.
    const headLine = head.querySelector('.gridLine') || head;
    const headers = [...headLine.children]
      .filter(c => c.offsetWidth > 0)
      .map(c => {
        const textEl = c.querySelector('.gridBoxText');
        const text = (textEl || c).innerText?.trim().replace(/\\n/g, ' ') || '';
        // Picture/icon columns have no header text — fall back to the title tooltip
        // (mirrors readTable naming) so they can still be targeted for clicking.
        const title = (c.getAttribute('title') || '').trim();
        const r = c.getBoundingClientRect();
        return { text, title, name: text || title, x: r.x, right: r.x + r.width, fixed: c.classList.contains('gridBoxFix') };
      })
      .filter(h => h.name);

    const resolveCol = (name) => {
      const suffix = ' / ' + name;
      const cand = h => [h.text, h.title].filter(Boolean);
      return headers.find(h => cand(h).some(t => lo(t) === lo(name)))
          || headers.find(h => cand(h).some(t => t.endsWith(suffix)))
          || headers.find(h => cand(h).some(t => lo(t).includes(lo(name))));
    };

    const targetCol = ${JSON.stringify(column)};
    const col = resolveCol(targetCol);
    if (!col) return { error: 'column_not_found', column: targetCol, available: headers.map(h => h.name) };

    const lines = [...body.querySelectorAll('.gridLine')];
    if (lines.length === 0) return { error: 'empty_grid' };

    // Match cell to column by X overlap, but only among cells with the same
    // fixed/scrollable kind as the header. After horizontal scroll a scrollable
    // cell may have the same x as a frozen one — without this guard cellAtColX
    // would silently return the frozen cell for a scrollable header.
    const cellAtColX = (line, c) => [...line.children]
      .filter(b => b.offsetWidth > 0 && b.classList.contains('gridBoxFix') === c.fixed)
      .find(b => {
        const r = b.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        return cx >= c.x && cx < c.right;
      });
    const cellText = (b) => norm(b?.querySelector('.gridBoxText')?.innerText || b?.innerText || '');

    const target = ${JSON.stringify(row)};
    let line, rowIdx;
    if (typeof target === 'number') {
      if (target < 0 || target >= lines.length) {
        return { error: 'row_out_of_range', row: target, loaded: lines.length };
      }
      line = lines[target];
      rowIdx = target;
    } else if (target && typeof target === 'object') {
      const entries = Object.entries(target);
      const colsByKey = {};
      for (const [k] of entries) {
        const c = resolveCol(k);
        if (!c) return { error: 'filter_column_not_found', column: k, available: headers.map(h => h.name) };
        colsByKey[k] = c;
      }
      const matches = (ln) => {
        for (const [k, v] of entries) {
          const c = colsByKey[k];
          const cell = cellAtColX(ln, c);
          const txt = cellText(cell);
          const wanted = lo(v);
          if (!txt) return false;
          const t = txt.toLowerCase();
          if (!(t === wanted || t.includes(wanted))) return false;
        }
        return true;
      };
      rowIdx = lines.findIndex(matches);
      if (rowIdx < 0) return { error: 'row_not_found', filter: target };
      line = lines[rowIdx];
    } else {
      return { error: 'invalid_row_type' };
    }

    const cell = cellAtColX(line, col);
    if (!cell) return { error: 'cell_not_in_dom', column: col.name, rowIdx };
    const r = cell.getBoundingClientRect();
    const gridBox = grid.getBoundingClientRect();
    // Frozen columns (.gridBoxFix) stay pinned at the left edge of the grid even
    // when the rest scrolls horizontally. For non-frozen cells, "visible" means
    // inside the SCROLLABLE viewport (right of any frozen columns). Frozen cells
    // are always visible by definition.
    const isFixed = cell.classList.contains('gridBoxFix');
    let scrollableLeft = gridBox.x;
    if (!isFixed) {
      [...line.children].forEach(b => {
        if (b.offsetWidth > 0 && b.classList.contains('gridBoxFix')) {
          const br = b.getBoundingClientRect();
          if (br.x + br.width > scrollableLeft) scrollableLeft = br.x + br.width;
        }
      });
    }
    // "Visible enough to click" — the cell's CENTER is inside the scrollable area
    // and the cell's right edge is inside the grid. Strict left-edge check would
    // reject cells that 1С rendered touching the frozen-column boundary (off by 1px).
    const center = r.x + r.width / 2;
    const visible = center >= scrollableLeft && center <= (gridBox.x + gridBox.width) && (r.x + r.width) <= (gridBox.x + gridBox.width);
    return {
      x: Math.round(r.x + r.width / 2),
      y: Math.round(r.y + r.height / 2),
      cellX: Math.round(r.x), cellRight: Math.round(r.x + r.width),
      gridX: Math.round(gridBox.x), gridRight: Math.round(gridBox.x + gridBox.width),
      scrollableLeft: Math.round(scrollableLeft),
      columnText: col.name, rowIdx, isFixed,
      cellText: cellText(cell),
      visible
    };
  })()`;
}

/**
 * Pick coordinates for a focus-click on a safe cell within the grid.
 *
 * Used both for vertical reveal-loop focus and for horizontal-scroll edge focus.
 * The caller passes a profile that selects which row, which cells to exclude,
 * and (for horizontal scroll) which edge of the row to take.
 *
 * @param {string} gridSelector
 * @param {object} opts
 * @param {number} [opts.rowIdx]   - Pick from this row; falls back to first non-group/parent data row.
 * @param {'ArrowRight'|'ArrowLeft'} [opts.direction]
 *   - When set, restricts to non-frozen FULLY visible cells and picks the edge
 *     cell in that direction (rightmost for ArrowRight, leftmost for ArrowLeft).
 *   - When omitted, picks a generic safe cell (skips first column to avoid tree-toggles).
 *
 * Always prefers non-checkbox cells (center-click on a checkbox would toggle it).
 *
 * Returns `{ x, y } | null`.
 */
export function findFocusCellScript(gridSelector, { rowIdx, direction } = {}) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const lines = [...body.querySelectorAll('.gridLine')];
    if (!lines.length) return null;

    const rowIdx = ${rowIdx == null ? 'null' : JSON.stringify(rowIdx)};
    const direction = ${direction ? JSON.stringify(direction) : 'null'};

    const line = (rowIdx != null && lines[rowIdx])
      || lines.find(ln => {
        const imgBox = ln.querySelector('.gridBoxImg');
        return !imgBox?.querySelector('.gridListH, .gridListV');
      })
      || lines[0];
    if (!line) return null;

    let candidates;
    if (direction) {
      // Horizontal-scroll mode: edge cell in the scrollable area, exclude frozen.
      const gridBox = grid.getBoundingClientRect();
      let scrollableLeft = gridBox.x;
      [...line.children].forEach(b => {
        if (b.offsetWidth > 0 && b.classList.contains('gridBoxFix')) {
          const br = b.getBoundingClientRect();
          if (br.x + br.width > scrollableLeft) scrollableLeft = br.x + br.width;
        }
      });
      const visible = [...line.children]
        .filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxFix'))
        .map(b => ({ b, r: b.getBoundingClientRect(), checkbox: !!b.querySelector('.checkbox') }))
        .filter(({ r }) => r.x >= scrollableLeft && (r.x + r.width) <= (gridBox.x + gridBox.width));
      if (!visible.length) return null;
      visible.sort((a, b) => a.r.x - b.r.x);
      candidates = direction === 'ArrowRight' ? [...visible].reverse() : visible;
    } else {
      // Generic focus mode (used by reveal-loop): pick the FIRST visible cell —
      // typically a Reference column (Номенклатура in документах) which doesn't
      // auto-enter edit mode on click. Number/Date/String cells auto-edit and
      // break subsequent PageDown navigation.
      // For tree grids (presence of .gridBoxTree), skip first column to avoid
      // toggling expand/collapse of the row.
      const isTree = !!body.querySelector('.gridBoxTree');
      const cells = [...line.children]
        .filter(b => b.offsetWidth > 0)
        .map(b => ({ b, r: b.getBoundingClientRect(), checkbox: !!b.querySelector('.checkbox') }));
      if (!cells.length) return null;
      candidates = isTree && cells.length > 1 ? cells.slice(1) : cells;
    }
    const pick = candidates.find(v => !v.checkbox) || candidates[0];
    if (!pick) return null;
    return { x: Math.round(pick.r.x + pick.r.width / 2), y: Math.round(pick.r.y + pick.r.height / 2) };
  })()`;
}

/**
 * Snapshot grid state for reveal-loop end detection.
 * Returns `{ firstText, lastText, lineCount, selIdx, hasBelow }`.
 *
 * `firstText`/`lastText` use the first cell's `.gridBoxText` content.
 * `hasBelow` is derived from scrollbar widget tracks when visible, else from scrollHeight>clientHeight.
 */
export function snapshotGridScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const lines = body.querySelectorAll('.gridLine');
    // Full-row signature: join EVERY cell's text, not just the first column.
    // A low-cardinality first column (e.g. all "Товар 0X") would otherwise make
    // two different windows look identical and abort the reveal-loop early.
    const txt = ln => ln ? [...ln.querySelectorAll('.gridBoxText')].map(b => (b.innerText || '').trim()).join('|') : '';
    const selIdx = [...lines].findIndex(l => l.classList.contains('selRow') || l.classList.contains('select'));
    // hasBelow priority: (1) dynamic-list turn buttons, (2) tabular scrollbar tracks, (3) scrollHeight.
    let hasBelow;
    const turnsBox = document.getElementById('vertButtonScroll_' + grid.id);
    if (turnsBox && turnsBox.offsetHeight > 0) {
      const dnBtns = turnsBox.querySelectorAll('[data-down], [data-end]');
      hasBelow = [...dnBtns].some(b => !b.classList.contains('disabled'));
    } else {
      const vs = document.getElementById('vertScroll_' + grid.id);
      if (vs && vs.classList.contains('scrollV') && vs.offsetWidth > 0) {
        hasBelow = (vs.querySelector('[data-track-next]')?.offsetHeight ?? 0) > 0;
      } else {
        hasBelow = body.scrollHeight > body.clientHeight;
      }
    }
    return {
      firstText: txt(lines[0]),
      lastText: txt(lines[lines.length - 1]),
      lineCount: lines.length,
      selIdx,
      hasBelow
    };
  })()`;
}

/**
 * Resolve the click target kind for `clickElement({row, column})`.
 *
 * Routing:
 *  - `tableName` specified: try to match a visible grid by name (exact → contains).
 *    If matched → grid. Else if form has a spreadsheet iframe → spreadsheet. Else error.
 *  - `tableName` omitted: spreadsheet iframe present → spreadsheet (backward-compat).
 *    Else first visible grid. Else error.
 *
 * Returns `{ kind: 'spreadsheet' } | { kind: 'grid', gridSelector, gridName } | { error, ... }`.
 */
export function resolveCellTargetScript(formNum, tableName) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const tableName = ${JSON.stringify(tableName || '')};
    // Spreadsheet = iframe under form prefix with non-trivial width.
    const hasSpreadsheet = [...document.querySelectorAll('iframe')].some(f => {
      if (f.offsetWidth < 100) return false;
      let el = f.parentElement;
      for (let d = 0; el && d < 30; d++, el = el.parentElement) {
        if (el.id && el.id.startsWith(p)) return true;
      }
      return false;
    });
    const grids = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .filter(g => g.offsetWidth > 0 && g.offsetHeight > 0);
    const norm = s => (s || '').replace(/ё/gi, 'е').toLowerCase();

    if (tableName) {
      const target = norm(tableName);
      const matched = grids.find(g => norm(g.id.replace(p, '')) === target)
                   || grids.find(g => norm(g.id.replace(p, '')).includes(target));
      if (matched) {
        return { kind: 'grid', gridSelector: '#' + CSS.escape(matched.id), gridName: matched.id.replace(p, '') };
      }
      if (hasSpreadsheet) return { kind: 'spreadsheet' };
      return { error: 'table_not_found', table: tableName, availableGrids: grids.map(g => g.id.replace(p, '')) };
    }
    if (hasSpreadsheet) return { kind: 'spreadsheet' };
    if (grids.length > 0) {
      const g = grids[0];
      return { kind: 'grid', gridSelector: '#' + CSS.escape(g.id), gridName: g.id.replace(p, '') };
    }
    return { error: 'no_spreadsheet_or_grid' };
  })()`;
}
