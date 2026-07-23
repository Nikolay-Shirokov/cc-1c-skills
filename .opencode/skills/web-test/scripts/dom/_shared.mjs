// web-test dom shared v1.7 — embedded JS function constants
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Shared function strings embedded into page.evaluate() generators.
 * Не экспортируются наружу через dom.mjs facade — внутренняя кухня.
 */

/** Find visible #modalSurface. 1C may leave multiple #modalSurface in DOM (duplicate id),
 *  e.g. when a second form (drill-down) creates its own alongside a stale one from the first
 *  form. getElementById returns the FIRST in document order, which may be hidden. Scan all. */
export const HAS_VISIBLE_MODAL_FN = `function hasVisibleModal() {
  const all = document.querySelectorAll('#modalSurface');
  for (const el of all) { if (el.offsetWidth > 0) return true; }
  return false;
}`;

/**
 * Click point INSIDE a grid row's first visible text cell — NOT the row-line centre.
 *
 * A wide multi-column row's centre `x = line.x + line.width/2` lands far beyond the
 * form's horizontal viewport (the `.gridLine` spans ALL columns, frozen + scrollable),
 * so `mouse.click` at that X falls on an overlay outside the visible grid and the row
 * is never hit — the click silently does nothing. Seen on narrow modal selection forms
 * with many columns (множественный выбор) and the `not_selectable` bug on selection forms.
 *
 * Picks the first visible non-checkbox cell that HAS text (so center-clicking never
 * toggles a checkbox/picture mark), skips the first column on tree grids (it holds the
 * expand toggle), and clamps X near the left edge (`min(width/2, 60)`) so a wide first
 * column still lands in the viewport.
 *
 * @param line  a `.gridLine` element
 * @param body  the grid's `.gridBody` (for tree detection); may be null
 * @returns `{ x, y }` rounded, or `null` when the row has no usable cell.
 */
export const ROW_CLICK_POINT_FN = `function rowClickPoint(line, body) {
  const isTree = !!(body && body.querySelector('.gridBoxTree'));
  let cells = [...line.children]
    .filter(b => b.offsetWidth > 0)
    .map(b => ({ r: b.getBoundingClientRect(), checkbox: !!b.querySelector('.checkbox'), hasText: !!b.querySelector('.gridBoxText') }));
  if (isTree && cells.length > 1) cells = cells.slice(1);
  const pick = cells.find(c => !c.checkbox && c.hasText) || cells.find(c => !c.checkbox) || cells[0];
  if (!pick) return null;
  return { x: Math.round(pick.r.x + Math.min(pick.r.width / 2, 60)), y: Math.round(pick.r.y + pick.r.height / 2) };
}`;

/**
 * Single source of truth for column derivation on HEADERLESS grids (no `.gridHead`).
 * 1C still puts `colindex` on body cells, so anchoring works without a header.
 * Returns ordered descriptors consumed identically by readers (readTable, getFormState)
 * and resolvers (findCellCoords, findGridCell, scanGridRows) so a synthesized name like
 * "Колонка1" always maps to the same physical cell on both read and write.
 *
 * Descriptor: { name, kind:'data'|'checkbox'|'picture', colindex, subTarget:'checkbox'|'title'|'text'|null }
 *  - colindex   — anchor: find the cell via line.children box with matching getAttribute('colindex').
 *  - subTarget  — node inside that box: 'checkbox' → .checkbox, 'title' → .gridBoxTitle,
 *                 'text' → .gridBoxText, null → box itself.
 *
 * A COMBINED mark-box (one box holding BOTH .checkbox AND non-empty .gridBoxTitle, e.g. the
 * value-list checkbox mark-lists) is split into TWO logical columns sharing one colindex:
 * "(checkbox)" (subTarget:checkbox) + "КолонкаN" (subTarget:title). Data columns are numbered
 * КолонкаN among themselves (checkbox/picture don't consume a number); duplicate
 * "(checkbox)"/"(picture)" get a " 2", " 3" suffix.
 */
export const HEADERLESS_GRID_FN = `function synthHeaderlessColumns(grid) {
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
  const body = grid.querySelector('.gridBody');
  if (!body) return [];
  const line = body.querySelector('.gridLine');
  if (!line) return [];
  const cols = [];
  let dataN = 0;
  const uniq = (base) => {
    if (!cols.some(c => c.name === base)) return base;
    let n = 2; while (cols.some(c => c.name === base + ' ' + n)) n++;
    return base + ' ' + n;
  };
  [...line.children].forEach(box => {
    if (box.offsetWidth === 0) return;
    const ci = box.getAttribute('colindex');
    if (ci == null) return;
    const chk = box.querySelector('.checkbox');
    const titleEl = box.querySelector('.gridBoxTitle');
    const textEl = box.querySelector('.gridBoxText');
    const titleTxt = ((titleEl ? titleEl.innerText : '') || '').trim();
    if (chk && titleTxt) {
      cols.push({ name: uniq('(checkbox)'), kind: 'checkbox', colindex: ci, subTarget: 'checkbox' });
      cols.push({ name: 'Колонка' + (++dataN), kind: 'data', colindex: ci, subTarget: 'title' });
    } else if (chk) {
      cols.push({ name: uniq('(checkbox)'), kind: 'checkbox', colindex: ci, subTarget: 'checkbox' });
    } else if (picInfo(box)) {
      cols.push({ name: uniq('(picture)'), kind: 'picture', colindex: ci, subTarget: null });
    } else {
      cols.push({ name: 'Колонка' + (++dataN), kind: 'data', colindex: ci, subTarget: textEl ? 'text' : (titleEl ? 'title' : null) });
    }
  });
  return cols;
}`;

/**
 * Single source of truth for columns of a grid WITH a header — the headed twin of
 * synthHeaderlessColumns above, and for the same reason: a column name must map to the same
 * physical cell for readers (readTable) and resolvers (click, row search, filter, fill).
 *
 * Column identity is `colindex` — 1С's own column id, present on both header boxes and body
 * cells. Geometry is the FALLBACK, used only for cells that have no header of their own
 * (sub-rows of a merged header, e.g. «Субконто Дт» over three stacked cells).
 *
 * Why colindex first: a wide header (ERP task list, «Исполнитель» spanning x 1085…1515) covers
 * the narrow headers below it («Срок» 1085…1251, «Выполнена» 1251…1515). Matching a cell by its
 * center-x alone puts the «Исполнитель» cell (center 1300) into the «Выполнена» group — which
 * both fakes a merged header (phantom «Выполнена 1/2») and glues foreign values together.
 * The write path (grid-edit.mjs) already resolves cells by colindex for exactly this reason.
 *
 * Column: { name, text, title, ci, x, right, y, h, fixed, kind?, subIdx? }
 *  - ci      — anchor; null for expanded sub-columns (their cells carry a different colindex).
 *  - subIdx  — set on «Имя 1/2/3» columns expanded from ONE header over several sub-rows;
 *              such a cell is found by its Y order inside the header's x-range.
 */
export const COLUMN_MODEL_FN = HEADERLESS_GRID_FN + `
function picInfoShared(cell) {
  if (!cell) return null;
  if (cell.querySelector('.gridListH, .gridListV, [tree="true"], .gridBoxTree')) return null;
  const dib = cell.querySelector('.gridBoxImg .dIB');
  if (!dib) return null;
  const bg = dib.style.backgroundImage || '';
  if (!bg.includes('pictureCollection/picture/')) return null;
  const m = bg.match(/[?&]gx=(\\d+)/);
  return { gx: m ? m[1] : '0' };
}

function buildColumnModel(grid) {
  const head = grid.querySelector('.gridHead');
  const body = grid.querySelector('.gridBody');
  const empty = { columns: [], byCi: {}, groups: new Map(), subRows: {}, multiRow: {}, headless: !head };
  if (!body) return empty;

  if (!head) {
    const cols = synthHeaderlessColumns(grid).map(c => ({
      name: c.name, text: c.name, title: '', ci: c.colindex, subTarget: c.subTarget,
      kind: c.kind, x: 0, right: 0, y: 0, h: 0, fixed: false,
    }));
    const byCi = {};
    cols.forEach(c => { if (c.ci != null && byCi[c.ci] === undefined) byCi[c.ci] = c; });
    return { columns: cols, byCi, groups: new Map(), subRows: {}, multiRow: {}, headless: true };
  }

  const headLine = head.querySelector('.gridLine') || head;
  const lines = [...body.querySelectorAll('.gridLine')];
  const cellByCi = (line, ci) => [...line.children].find(b => b.offsetWidth > 0 && b.getAttribute('colindex') === ci);
  const columns = [];

  [...headLine.children].forEach(box => {
    if (box.offsetWidth === 0) return;
    const ci = box.getAttribute('colindex');
    const textEl = box.querySelector('.gridBoxText');
    const text = ((textEl || box).innerText || '').trim().replace(/\\n/g, ' ');
    const title = (box.getAttribute('title') || '').trim();
    const r = box.getBoundingClientRect();
    const base = { ci, x: r.x, right: r.x + r.width, y: r.y, h: r.height,
                   fixed: box.classList.contains('gridBoxFix') };
    if (text) { columns.push(Object.assign(base, { name: text, text: text, title: title })); return; }

    // Unnamed header — a column only if its cells hold a checkbox or a picture. 1С doesn't
    // expose the technical name, so it is named by the header tooltip.
    // Sample SEVERAL rows: a picture bound to a Boolean draws nothing for false, so an empty
    // first row is not evidence that the column has no pictures at all.
    let kind = null;
    for (const line of lines.slice(0, 10)) {
      const cell = ci != null ? cellByCi(line, ci) : null;
      if (!cell) continue;
      if (cell.querySelector('.checkbox')) { kind = 'checkbox'; break; }
      if (picInfoShared(cell)) { kind = 'picture'; break; }
    }
    if (!kind && picInfoShared(box)) kind = 'picture';
    if (!kind) return;
    let name = kind === 'checkbox' ? '(checkbox)' : (title || '(picture)');
    if (columns.some(c => c.name === name)) {
      let n = 2;
      while (columns.some(c => c.name === name + ' ' + n)) n++;
      name = name + ' ' + n;
    }
    columns.push(Object.assign(base, { name: name, text: '', title: title, kind: kind }));
  });

  const keyOf = c => Math.round(c.x) + ':' + Math.round(c.right);
  const groups = new Map();
  columns.forEach(c => { const k = keyOf(c); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(c); });
  for (const hdrs of groups.values()) hdrs.sort((a, b) => a.y - b.y);
  const byCi = {};
  columns.forEach(c => { if (c.ci != null && byCi[c.ci] === undefined) byCi[c.ci] = c; });

  // Sub-rows per x-group, measured on the first data line. A cell belongs to the group of its
  // OWN header whenever colindex says so; only header-less cells are placed geometrically.
  const subRows = {};
  if (lines[0]) {
    [...lines[0].children].forEach(box => {
      if (box.offsetWidth === 0) return;
      const ci = box.getAttribute('colindex');
      const own = ci != null ? byCi[ci] : null;
      let key = null;
      const r = box.getBoundingClientRect();
      if (own) key = keyOf(own);
      else {
        const cx = r.x + r.width / 2;
        for (const [k, hdrs] of groups) {
          if (cx >= hdrs[0].x && cx < hdrs[0].right) { key = k; break; }
        }
      }
      if (key == null) return;
      (subRows[key] = subRows[key] || []).push({ y: r.y });
    });
    Object.keys(subRows).forEach(k => subRows[k].sort((a, b) => a.y - b.y));
  }

  // Stacked headers (2+ over several sub-rows) → match by Y order.
  // ONE header over several sub-rows → merged header: expand into «Имя 1..N».
  const multiRow = {};
  for (const [k, hdrs] of groups) {
    const subs = subRows[k];
    if (!subs || subs.length <= 1) continue;
    if (hdrs.length >= 2) { multiRow[k] = hdrs; continue; }
    const base = hdrs[0];
    const at = columns.indexOf(base);
    columns.splice(at, 1);
    if (base.ci != null && byCi[base.ci] === base) delete byCi[base.ci];
    const expanded = [];
    for (let si = 0; si < subs.length; si++) {
      const col = Object.assign({}, base, {
        name: base.name + ' ' + (si + 1), ci: null,
        y: base.y + si, h: base.h / subs.length, subIdx: si,
      });
      columns.splice(at + si, 0, col);
      expanded.push(col);
    }
    groups.set(k, expanded);
    multiRow[k] = expanded;
  }

  return { columns: columns, byCi: byCi, groups: groups, subRows: subRows, multiRow: multiRow, headless: false };
}

/** Cell → column. colindex first; geometry only for cells without a header of their own. */
function columnForCell(model, box) {
  const ci = box.getAttribute('colindex');
  if (ci != null && model.byCi[ci]) return model.byCi[ci];
  const r = box.getBoundingClientRect();
  const cx = r.x + r.width / 2;
  const fixed = box.classList.contains('gridBoxFix');
  for (const k of Object.keys(model.multiRow)) {
    const hdrs = model.multiRow[k];
    if (cx < hdrs[0].x || cx >= hdrs[0].right) continue;
    const subs = model.subRows[k];
    if (subs) {
      const si = subs.findIndex(s => Math.abs(s.y - r.y) < 5);
      if (si >= 0 && si < hdrs.length) return hdrs[si];
    }
    let best = hdrs[0], bd = Infinity;
    for (const h of hdrs) { const d = Math.abs(r.y - h.y); if (d < bd) { bd = d; best = h; } }
    return best;
  }
  return model.columns.find(c => cx >= c.x && cx < c.right && c.fixed === fixed) || null;
}

/** Column → cell inside a given line. Mirror of columnForCell, same precedence. */
function cellForColumn(model, line, col) {
  const boxes = [...line.children].filter(b => b.offsetWidth > 0);
  if (col.subIdx != null) {
    const inGroup = boxes
      .filter(b => {
        const r = b.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        return cx >= col.x && cx < col.right && b.classList.contains('gridBoxFix') === col.fixed;
      })
      .sort((a, b) => a.getBoundingClientRect().y - b.getBoundingClientRect().y);
    return inGroup[col.subIdx] || null;
  }
  if (col.ci != null) {
    const hit = boxes.find(b => b.getAttribute('colindex') === col.ci);
    if (hit) return hit;
  }
  return boxes
    .filter(b => b.classList.contains('gridBoxFix') === col.fixed)
    .find(b => {
      const r = b.getBoundingClientRect();
      const cx = r.x + r.width / 2;
      return cx >= col.x && cx < col.right;
    }) || null;
}

/** Column by user-supplied name: exact → «Группа / Имя» suffix → substring. */
function resolveColumnByName(model, name) {
  const lo = s => (s || '').toLowerCase().replace(/ё/g, 'е').trim();
  const cand = c => [c.name, c.text, c.title].filter(Boolean);
  const n = lo(name);
  const suffix = lo(' / ' + name);
  return model.columns.find(c => cand(c).some(t => lo(t) === n))
      || model.columns.find(c => cand(c).some(t => lo(t).endsWith(suffix)))
      || model.columns.find(c => cand(c).some(t => lo(t).includes(n)))
      || null;
}`;

// Селекторы детекции формы. EDIT_SEL — «редактируемые» контролы (поля/кнопки): их наличие
// исторически = «это форма». Но страницы настроек/справки (напр. «Интернет-поддержка и сервисы»)
// собраны только из гиперссылок/frameButton/групп и НЕ имеют ни одного из этих трёх → форма не
// детектировалась (form=null). ANY_SEL добавляет контентные/интерактивные классы декораций, чтобы
// такие формы регистрировались. form0 (рабочий стол, тоже полон гиперссылок) исключается фильтром n>0.
const FORM_DETECT_EDIT_SEL = 'input.editInput[id], textarea[id], a.press[id]';
const FORM_DETECT_ANY_SEL = FORM_DETECT_EDIT_SEL + ', .staticTextHyper[id], .frameButton[id], .checkbox[id], .radio[id], .tumblerItem[id], .grid[id]';

/** Detect active form number. Picks form with most visible elements, skipping form0.
 *  When modalSurface is visible — prefer the highest-numbered form (modal dialog). */
export const DETECT_FORM_FN = HAS_VISIBLE_MODAL_FN + `
function detectForm() {
  const editSel = ${JSON.stringify(FORM_DETECT_EDIT_SEL)};
  const anySel = ${JSON.stringify(FORM_DETECT_ANY_SEL)};
  const editCounts = {};   // строгие поля/кнопки
  const anyCounts = {};    // + контентные декорации
  document.querySelectorAll(anySel).forEach(el => {
    if (el.offsetWidth === 0) return;
    const m = el.id.match(/^form(\\d+)_/);
    if (!m) return;
    anyCounts[m[1]] = (anyCounts[m[1]] || 0) + 1;
    if (el.matches(editSel)) editCounts[m[1]] = (editCounts[m[1]] || 0) + 1;
  });
  const nums = Object.keys(anyCounts).map(Number);
  if (!nums.length) return null;
  const candidates = nums.filter(n => n > 0);
  if (!candidates.length) return nums[0];
  // When modal surface is visible, prefer the highest-numbered form (modal dialog)
  if (hasVisibleModal()) {
    const maxForm = Math.max(...candidates);
    if (anyCounts[maxForm] >= 1) return maxForm;
  }
  // Двухуровневый выбор: пока есть формы с редактируемыми контролами — выбираем по ним (прежнее
  // поведение, обычные формы не сдвигаются). Только когда у ВСЕХ кандидатов их нет (info-страница) —
  // выбираем по расширенному счёту.
  const editable = candidates.filter(n => editCounts[n] > 0);
  const pool = editable.length ? editable : candidates;
  const metric = editable.length ? editCounts : anyCounts;
  return pool.reduce((best, n) => metric[n] > metric[best] ? n : best);
}`;

/** Detect all open forms + modal state. Returns { activeForm, allForms, formCount, modal }.
 *  Works even when the open-windows tab bar is hidden. */
export const DETECT_FORMS_FN = HAS_VISIBLE_MODAL_FN + `
function detectForms() {
  const anySel = ${JSON.stringify(FORM_DETECT_ANY_SEL)};
  const counts = {};
  document.querySelectorAll(anySel).forEach(el => {
    if (el.offsetWidth === 0) return;
    const m = el.id.match(/^form(\\d+)_/);
    if (m) counts[m[1]] = (counts[m[1]] || 0) + 1;
  });
  const nums = Object.keys(counts).map(Number);
  return { allForms: nums.sort((a, b) => a - b), formCount: nums.length, modal: hasVisibleModal() };
}`;

/** Read form state given prefix p. Returns { fields, buttons, tabs, texts, hyperlinks, table, iframes }. */
export const READ_FORM_FN = HEADERLESS_GRID_FN + `
function readForm(p) {
  const result = {};
  const fields = [];
  const buttons = [];
  const formTabs = [];
  const texts = [];
  const hyperlinks = [];
  // Normalize non-breaking spaces to regular spaces
  const nbsp = s => (s || '').replace(/\\u00a0/g, ' ');

  // Fields (inputs)
  document.querySelectorAll('input.editInput[id^="' + p + '"]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const name = el.id.replace(p, '').replace(/_i\\d+$/, '');
    const titleEl = document.getElementById(p + name + '#title_text')
      || document.getElementById(p + name + '#title_div');
    const label = nbsp((titleEl?.innerText?.trim() || '').replace(/\\n/g, ' '));
    const actions = [];
    if (document.getElementById(p + name + '_DLB')?.offsetWidth > 0) actions.push('select');
    if (document.getElementById(p + name + '_OB')?.offsetWidth > 0) actions.push('open');
    if (document.getElementById(p + name + '_CLR')?.offsetWidth > 0) actions.push('clear');
    if (document.getElementById(p + name + '_CB')?.offsetWidth > 0) actions.push('pick');
    const field = { name, value: el.value || '' };
    // Multi-value reference fields keep their value in .chipsItem chips, not in input.value
    if (!field.value) {
      const labelEl = document.getElementById(p + name);
      if (labelEl) {
        const chipTexts = [...labelEl.querySelectorAll('.chipsItem .chipsTitle')]
          .map(c => nbsp(c.innerText?.trim() || ''))
          .filter(Boolean);
        if (chipTexts.length) field.value = chipTexts.join(', ');
      }
    }
    if (label && label !== name) field.label = label;
    if (el.readOnly) field.readonly = true;
    if (el.disabled) field.disabled = true;
    if (el.type && el.type !== 'text') field.type = el.type;
    if (document.activeElement === el) field.focused = true;
    if (actions.length) field.actions = actions;
    if (el.closest('.inputsBox')?.classList.contains('markIncomplete')) field.required = true;
    fields.push(field);
  });

  // Textareas
  document.querySelectorAll('textarea[id^="' + p + '"]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const name = el.id.replace(p, '').replace(/_i\\d+$/, '');
    const titleEl = document.getElementById(p + name + '#title_text')
      || document.getElementById(p + name + '#title_div');
    const label = nbsp((titleEl?.innerText?.trim() || '').replace(/\\n/g, ' '));
    const field = { name, value: el.value || '', type: 'textarea' };
    if (label && label !== name) field.label = label;
    if (el.readOnly) field.readonly = true;
    if (el.disabled) field.disabled = true;
    if (document.activeElement === el) field.focused = true;
    if (el.closest('.inputsBox')?.classList.contains('markIncomplete')) field.required = true;
    fields.push(field);
  });

  // Checkboxes
  document.querySelectorAll('[id^="' + p + '"].checkbox').forEach(el => {
    if (el.offsetWidth === 0) return;
    const name = el.id.replace(p, '');
    const titleEl = document.getElementById(p + name + '#title_text');
    const label = nbsp(titleEl?.innerText?.trim() || '');
    const field = {
      name,
      value: el.classList.contains('checked') || el.classList.contains('checkboxOn') || el.classList.contains('select'),
      type: 'checkbox'
    };
    if (label && label !== name) field.label = label;
    if (el.classList.contains('checkboxDisabled')) field.disabled = true;
    fields.push(field);
  });

  // Radio buttons — base element is option 0, others are #N#radio (N >= 1)
  const radioGroups = {};
  document.querySelectorAll('[id^="' + p + '"].radio').forEach(el => {
    if (el.offsetWidth === 0) return;
    const id = el.id.replace(p, '');
    const m = id.match(/^(.+?)#(\\d+)#radio$/);
    if (m) {
      // Options 1, 2, ... have explicit #N#radio suffix
      const [, groupName, idx] = m;
      if (!radioGroups[groupName]) radioGroups[groupName] = [];
      const labelEl = document.getElementById(p + groupName + '#' + idx + '#radio_text');
      const label = nbsp(labelEl?.innerText?.trim() || 'option' + idx);
      radioGroups[groupName].push({ index: parseInt(idx), label, selected: el.classList.contains('select') });
    } else if (!id.includes('#')) {
      // Base element = option 0 (no #0#radio suffix)
      if (!radioGroups[id]) radioGroups[id] = [];
      const labelEl = document.getElementById(p + id + '#0#radio_text');
      const label = nbsp(labelEl?.innerText?.trim() || 'option0');
      radioGroups[id].unshift({ index: 0, label, selected: el.classList.contains('select') });
    }
  });
  for (const [name, options] of Object.entries(radioGroups)) {
    const titleEl = document.getElementById(p + name + '#title_text');
    const label = titleEl?.innerText?.trim() || '';
    const selected = options.find(o => o.selected);
    const field = {
      name,
      value: selected?.label || '',
      type: 'radio',
      options: options.map(o => o.label)
    };
    if (label && label !== name) field.label = label;
    if (document.getElementById(p + name)?.classList.contains('radioDisabled')) field.disabled = true;
    fields.push(field);
  }

  // Buttons (a.press)
  document.querySelectorAll('a.press[id^="' + p + '"]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const idName = el.id.replace(p, '');
    if (/_(?:DLB|CLR|OB|CB)$/.test(idName)) return;
    const span = el.querySelector('.submenuText') || el.querySelector('span');
    const text = nbsp(span?.textContent?.trim() || el.innerText?.trim() || '');
    if (!text && !el.classList.contains('pressCommand')) return;
    const btn = { name: text || idName };
    if (el.classList.contains('pressDefault')) btn.default = true;
    if (el.classList.contains('pressDisabled')) btn.disabled = true;
    // Icon-only buttons: expose tooltip from DOM title attribute (1C puts title on parent .framePress)
    if (!text) {
      const tip = nbsp(el.title || el.parentElement?.title || '');
      if (tip) btn.tooltip = tip;
    }
    buttons.push(btn);
  });

  // Frame buttons
  document.querySelectorAll('[id^="' + p + '"].frameButton, [id^="' + p + '"] .frameButton').forEach(el => {
    if (el.offsetWidth === 0) return;
    const text = nbsp(el.innerText?.trim() || '');
    const idName = el.id?.replace(p, '') || '';
    if (!text && !idName) return;
    // frameButton disabled uses the same class as a.press buttons (pressDisabled).
    const btn = { name: text || idName, frame: true };
    if (el.classList.contains('pressDisabled')) btn.disabled = true;
    buttons.push(btn);
  });

  // Tumbler items. Disabled state lives on the group element .frameTumbler
  // (class tumblerDisabled), not on the individual segments.
  document.querySelectorAll('[id^="' + p + '"].tumblerItem').forEach(el => {
    if (el.offsetWidth === 0) return;
    const text = el.innerText?.trim();
    const idName = el.id?.replace(p, '') || '';
    const btn = { name: text || idName, tumbler: true };
    if (el.closest('.frameTumbler')?.classList.contains('tumblerDisabled')) btn.disabled = true;
    buttons.push(btn);
  });

  // Tabs — scoped to form by checking ancestor IDs
  document.querySelectorAll('[data-content]').forEach(el => {
    if (el.offsetWidth === 0) return;
    let node = el.parentElement;
    let inForm = false;
    while (node) {
      if (node.id && node.id.startsWith(p)) { inForm = true; break; }
      node = node.parentElement;
    }
    if (!inForm) return;
    const tab = { name: el.dataset.content };
    if (el.classList.contains('select')) tab.active = true;
    formTabs.push(tab);
  });

  // Static texts and hyperlinks
  document.querySelectorAll('[id^="' + p + '"].staticText').forEach(el => {
    if (el.offsetWidth === 0) return;
    const name = el.id.replace(p, '');
    if (name.endsWith('_div') || name.includes('#title')) return;
    const text = el.innerText?.trim();
    if (!text) return;
    if (el.classList.contains('staticTextHyper')) {
      hyperlinks.push({ name: text });
    } else {
      const titleEl = document.getElementById(p + name + '#title_text');
      const label = titleEl?.innerText?.trim() || '';
      const entry = { name, value: text };
      if (label) entry.label = label;
      texts.push(entry);
    }
  });

  // Tables/grids — collect ALL visible grids
  const allGrids = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
    .filter(g => g.offsetWidth > 0 && g.offsetHeight > 0);
  if (allGrids.length > 0) {
    const tables = allGrids.map(grid => {
      const name = grid.id ? grid.id.replace(p, '') : '';
      const head = grid.querySelector('.gridHead');
      const body = grid.querySelector('.gridBody');
      const columns = [];
      if (head) {
        const headLine = head.querySelector('.gridLine') || head;
        [...headLine.children].forEach(box => {
          if (box.offsetWidth === 0) return;
          const textEl = box.querySelector('.gridBoxText');
          const text = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
          if (text) {
            const r = box.getBoundingClientRect();
            columns.push({ text, x: r.x, right: r.x + r.width, y: r.y, h: r.height });
          } else {
            // Unnamed column — check if data cells contain checkboxes
            const firstLine = body?.querySelector('.gridLine');
            if (firstLine) {
              const visibleHeaders = [...headLine.children].filter(c => c.offsetWidth > 0);
              const idx = visibleHeaders.indexOf(box);
              const cells = [...firstLine.children].filter(c => c.offsetWidth > 0);
              if (cells[idx]?.querySelector('.checkbox')) {
                columns.push({ text: '(checkbox)', x: 0, right: 0, y: 0, h: 0 });
              }
            }
          }
        });
        // Expand single merged headers with multiple data sub-rows (e.g. "Субконто Дт" → 1/2/3)
        const firstLine = body?.querySelector('.gridLine');
        if (firstLine && columns.length > 0) {
          const xGrp = new Map();
          columns.forEach(c => {
            const k = Math.round(c.x) + ':' + Math.round(c.right);
            if (!xGrp.has(k)) xGrp.set(k, []);
            xGrp.get(k).push(c);
          });
          for (const [k, hdrs] of xGrp) {
            if (hdrs.length !== 1) continue;
            let cnt = 0;
            [...firstLine.children].forEach(box => {
              if (box.offsetWidth === 0) return;
              const r = box.getBoundingClientRect();
              const cx = r.x + r.width / 2;
              if (cx >= hdrs[0].x && cx < hdrs[0].right) cnt++;
            });
            if (cnt > 1) {
              const base = hdrs[0];
              const baseIdx = columns.indexOf(base);
              columns.splice(baseIdx, 1);
              for (let si = 0; si < cnt; si++) {
                columns.splice(baseIdx + si, 0, { text: base.text + ' ' + (si + 1), x: base.x, right: base.right, y: 0, h: 0 });
              }
            }
          }
        }
      } else if (body) {
        // Headerless grid — synthesize columns by colindex (single source).
        synthHeaderlessColumns(grid).forEach(c => columns.push({ text: c.name, x: 0, right: 0, y: 0, h: 0 }));
      }
      const colNames = columns.map(c => c.text);
      const rowCount = body ? body.querySelectorAll('.gridLine').length : 0;
      // Visual label from group title (e.g. "Входящие:" for grid "Входящие")
      const titleEl = document.getElementById(p + name + '#title_div')
                   || document.getElementById(p + 'Группа' + name + '#title_div');
      const label = titleEl ? (titleEl.innerText?.trim().replace(/:\\s*$/, '').replace(/\\u00a0/g, ' ') || null) : null;
      return { name, columns: colNames, rowCount, ...(label ? { label } : {}) };
    });
    result.tables = tables;
    // Backward compat: table = first grid summary
    const first = tables[0];
    result.table = { present: true, columns: first.columns, rowCount: first.rowCount };
  }

  // Active filters (train badges above grid: *СостояниеПросмотра)
  const filters = [];
  document.querySelectorAll('[id^="' + p + '"].trainItem').forEach(el => {
    if (el.offsetWidth === 0) return;
    const titleEl = el.querySelector('.trainName');
    const valueEl = el.querySelector('.trainTitle');
    if (!titleEl && !valueEl) return;
    const field = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/\\s*:$/, '').trim();
    const value = valueEl?.innerText?.trim()?.replace(/\\n/g, ' ') || '';
    if (field || value) filters.push({ field, value });
  });
  // Also check search field value
  const searchInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
    .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
  if (searchInput?.value) {
    filters.push({ type: 'search', value: searchInput.value });
  }
  if (filters.length) result.filters = filters;

  // Navigation panel (FormNavigationPanel) — lives in parent page{N} container
  const navigation = [];
  const formEl = document.querySelector('[id^="' + p + '"]');
  if (formEl) {
    let pageEl = formEl.parentElement;
    while (pageEl && !(pageEl.id && /^page\\d+$/.test(pageEl.id))) pageEl = pageEl.parentElement;
    if (pageEl) {
      pageEl.querySelectorAll('.navigationItem').forEach(el => {
        if (el.offsetWidth === 0) return;
        const nameEl = el.querySelector('.navigationItemName');
        const text = (nameEl?.innerText?.trim() || '').replace(/\\u00a0/g, ' ');
        if (!text) return;
        const nav = { name: text };
        if (el.classList.contains('select')) nav.active = true;
        navigation.push(nav);
      });
    }
  }

  // Iframes
  let iframeCount = 0;
  document.querySelectorAll('[id^="' + p + '"] iframe, iframe[id^="' + p + '"]').forEach(el => {
    if (el.offsetWidth > 0 && el.offsetHeight > 0) iframeCount++;
  });
  if (iframeCount) result.iframes = iframeCount;

  // Collapsible / popup groups — surface that part of the form is hidden + its state.
  // Идентификация раскрываемой группы (есть заголовок <base>#title_text и один из признаков):
  //   • заголовок — гиперссылка (.staticTextHyper: ControlRepresentation=TitleHyperlink);
  //   • рядом кнопка-каретка <base>#titleBtn (ControlRepresentation=Picture);
  //   • есть панель <base>#panel_div — это ВСПЛЫВАЮЩАЯ (popup) группа.
  // Обычные (несворачиваемые) группы не имеют ничего из этого — их не показываем.
  // Состояние:
  //   • popup: display панели <base>#panel_div (none → закрыта);
  //   • collapsible: DOM у 1С плоский (контент — сиблинги под mainGroup, не вложены), но при
  //     глубинном обходе Form.xml ПЕРВЫЙ контент-сиблинг сразу за #title_div — всегда дочерний
  //     элемент группы (свободные соседи идут после всех детей). Его display = состояние.
  const groups = [];
  document.querySelectorAll('[id^="' + p + '"][id$="#title_text"]').forEach(tt => {
    if (tt.offsetWidth === 0 && tt.offsetHeight === 0) return;
    const base = tt.id.slice(0, -('#title_text'.length));
    const panelDiv = document.getElementById(base + '#panel_div');   // popup-маркер
    const isHyper = tt.classList.contains('staticTextHyper');
    const hasBtn = !!document.getElementById(base + '#titleBtn');
    if (!isHyper && !hasBtn && !panelDiv) return; // обычная (несворачиваемая) группа
    const g = { name: base.replace(p, ''), title: nbsp(tt.innerText?.trim() || '') };
    if (panelDiv) {
      g.behavior = 'popup';
      g.collapsed = getComputedStyle(panelDiv).display === 'none';
    } else {
      const contentSib = document.getElementById(base + '#title_div')?.nextElementSibling;
      if (contentSib) g.collapsed = getComputedStyle(contentSib).display === 'none';
    }
    groups.push(g);
  });

  if (fields.length) result.fields = fields;
  if (buttons.length) result.buttons = buttons;
  if (formTabs.length) result.tabs = formTabs;
  if (navigation.length) result.navigation = navigation;
  if (texts.length) result.texts = texts;
  if (hyperlinks.length) result.hyperlinks = hyperlinks;
  if (groups.length) result.groups = groups;

  // Group DCS report settings into readable format
  if (result.fields) {
    const dcsRe = /^(.+Элемент(\\d+))(Использование|Значение|ВидСравнения)$/;
    const dcsGroups = {};
    const dcsNames = new Set();
    for (const f of result.fields) {
      const m = f.name.match(dcsRe);
      if (!m) continue;
      if (!dcsGroups[m[1]]) dcsGroups[m[1]] = { _n: parseInt(m[2]) };
      dcsGroups[m[1]][m[3]] = f;
      dcsNames.add(f.name);
    }
    const dcsEntries = Object.entries(dcsGroups).sort((a, b) => a[1]._n - b[1]._n);
    if (dcsEntries.length) {
      result.reportSettings = dcsEntries.map(([, g]) => {
        const cb = g['Использование'];
        const val = g['Значение'];
        if (!cb && !val) return null;
        // No checkbox present (class="staticText" instead of .checkbox) — setting is always enabled
        const label = (val?.label || cb?.label || val?.name || cb?.name || '').replace(/:$/, '').trim();
        const s = { name: label, enabled: cb ? !!cb.value : true };
        if (val) {
          s.value = val.value || '';
          if (val.actions && val.actions.length) s.actions = val.actions;
        }
        return s;
      }).filter(Boolean);
      result.fields = result.fields.filter(f => !dcsNames.has(f.name));
      if (!result.fields.length) delete result.fields;
    }
  }

  return result;
}`;
