// web-test dom shared v1.0 — embedded JS function constants
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

/** Detect active form number. Picks form with most visible elements, skipping form0.
 *  When modalSurface is visible — prefer the highest-numbered form (modal dialog). */
export const DETECT_FORM_FN = HAS_VISIBLE_MODAL_FN + `
function detectForm() {
  const counts = {};
  document.querySelectorAll('input.editInput[id], textarea[id], a.press[id]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const m = el.id.match(/^form(\\d+)_/);
    if (m) counts[m[1]] = (counts[m[1]] || 0) + 1;
  });
  const nums = Object.keys(counts).map(Number);
  if (!nums.length) return null;
  const candidates = nums.filter(n => n > 0);
  if (!candidates.length) return nums[0];
  // When modal surface is visible, prefer the highest-numbered form (modal dialog)
  if (hasVisibleModal()) {
    const maxForm = Math.max(...candidates);
    if (counts[maxForm] >= 1) return maxForm;
  }
  return candidates.reduce((best, n) => counts[n] > counts[best] ? n : best);
}`;

/** Detect all open forms + modal state. Returns { activeForm, allForms, formCount, modal }.
 *  Works even when the open-windows tab bar is hidden. */
export const DETECT_FORMS_FN = HAS_VISIBLE_MODAL_FN + `
function detectForms() {
  const counts = {};
  document.querySelectorAll('input.editInput[id], textarea[id], a.press[id]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const m = el.id.match(/^form(\\d+)_/);
    if (m) counts[m[1]] = (counts[m[1]] || 0) + 1;
  });
  const nums = Object.keys(counts).map(Number);
  return { allForms: nums.sort((a, b) => a - b), formCount: nums.length, modal: hasVisibleModal() };
}`;

/** Read form state given prefix p. Returns { fields, buttons, tabs, texts, hyperlinks, table, iframes }. */
export const READ_FORM_FN = `function readForm(p) {
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
    buttons.push({ name: text || idName, frame: true });
  });

  // Tumbler items
  document.querySelectorAll('[id^="' + p + '"].tumblerItem').forEach(el => {
    if (el.offsetWidth === 0) return;
    const text = el.innerText?.trim();
    const idName = el.id?.replace(p, '') || '';
    buttons.push({ name: text || idName, tumbler: true });
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

  if (fields.length) result.fields = fields;
  if (buttons.length) result.buttons = buttons;
  if (formTabs.length) result.tabs = formTabs;
  if (navigation.length) result.navigation = navigation;
  if (texts.length) result.texts = texts;
  if (hyperlinks.length) result.hyperlinks = hyperlinks;

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
