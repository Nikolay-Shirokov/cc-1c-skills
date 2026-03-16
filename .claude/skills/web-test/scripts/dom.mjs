// web-test dom v1.1 — DOM selectors and semantic mapping for 1C web client
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * DOM selectors and semantic mapping for 1C:Enterprise web client.
 *
 * All functions return JavaScript strings for page.evaluate().
 * They produce clean semantic structures — no DOM IDs or CSS classes leak out.
 * Only non-default property values are included to minimize response size.
 */

// --- Shared function strings (embedded in evaluate scripts) ---

/** Detect active form number. Picks form with most visible elements, skipping form0.
 *  When modalSurface is visible — prefer the highest-numbered form (modal dialog). */
const DETECT_FORM_FN = `function detectForm() {
  const counts = {};
  document.querySelectorAll('input.editInput[id], a.press[id]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const m = el.id.match(/^form(\\d+)_/);
    if (m) counts[m[1]] = (counts[m[1]] || 0) + 1;
  });
  const nums = Object.keys(counts).map(Number);
  if (!nums.length) return null;
  const candidates = nums.filter(n => n > 0);
  if (!candidates.length) return nums[0];
  // When modal surface is visible, prefer the highest-numbered form (modal dialog)
  const modal = document.getElementById('modalSurface');
  if (modal && modal.offsetWidth > 0) {
    const maxForm = Math.max(...candidates);
    if (counts[maxForm] >= 1) return maxForm;
  }
  return candidates.reduce((best, n) => counts[n] > counts[best] ? n : best);
}`;

/** Read form state given prefix p. Returns { fields, buttons, tabs, texts, hyperlinks, table, iframes }. */
const READ_FORM_FN = `function readForm(p) {
  const result = {};
  const fields = [];
  const buttons = [];
  const formTabs = [];
  const texts = [];
  const hyperlinks = [];

  // Fields (inputs)
  document.querySelectorAll('input.editInput[id^="' + p + '"]').forEach(el => {
    if (el.offsetWidth === 0) return;
    const name = el.id.replace(p, '').replace(/_i\\d+$/, '');
    const titleEl = document.getElementById(p + name + '#title_text')
      || document.getElementById(p + name + '#title_div');
    const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ');
    const actions = [];
    if (document.getElementById(p + name + '_DLB')?.offsetWidth > 0) actions.push('select');
    if (document.getElementById(p + name + '_OB')?.offsetWidth > 0) actions.push('open');
    if (document.getElementById(p + name + '_CLR')?.offsetWidth > 0) actions.push('clear');
    if (document.getElementById(p + name + '_CB')?.offsetWidth > 0) actions.push('pick');
    const field = { name, value: el.value || '' };
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
    const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ');
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
    const label = titleEl?.innerText?.trim() || '';
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
      const label = labelEl?.innerText?.trim() || 'option' + idx;
      radioGroups[groupName].push({ index: parseInt(idx), label, selected: el.classList.contains('select') });
    } else if (!id.includes('#')) {
      // Base element = option 0 (no #0#radio suffix)
      if (!radioGroups[id]) radioGroups[id] = [];
      const labelEl = document.getElementById(p + id + '#0#radio_text');
      const label = labelEl?.innerText?.trim() || 'option0';
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
    const text = span?.textContent?.trim() || el.innerText?.trim() || '';
    if (!text && !el.classList.contains('pressCommand')) return;
    const btn = { name: text || idName };
    if (el.classList.contains('pressDefault')) btn.default = true;
    if (el.classList.contains('pressDisabled')) btn.disabled = true;
    buttons.push(btn);
  });

  // Frame buttons
  document.querySelectorAll('[id^="' + p + '"].frameButton, [id^="' + p + '"] .frameButton').forEach(el => {
    if (el.offsetWidth === 0) return;
    const text = el.innerText?.trim();
    if (!text) return;
    buttons.push({ name: text, frame: true });
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
          if (text) columns.push(text);
        });
      }
      const rowCount = body ? body.querySelectorAll('.gridLine').length : 0;
      // Visual label from group title (e.g. "Входящие:" for grid "Входящие")
      const titleEl = document.getElementById(p + name + '#title_div')
                   || document.getElementById(p + 'Группа' + name + '#title_div');
      const label = titleEl ? (titleEl.innerText?.trim().replace(/:\\s*$/, '').replace(/\\u00a0/g, ' ') || null) : null;
      return { name, columns, rowCount, ...(label ? { label } : {}) };
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
        if (!cb) return null;
        const label = (val?.label || cb.label || cb.name).replace(/:$/, '').trim();
        const s = { name: label, enabled: !!cb.value };
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

// --- Exported script generators ---

/**
 * Detect the active form number.
 * Picks the form with the most visible elements (excluding form0 = home page).
 */
export function detectFormScript() {
  return `(() => {
    ${DETECT_FORM_FN}
    return detectForm();
  })()`;
}

/** Read sections panel (left sidebar). */
export function readSectionsScript() {
  return `(() => {
    const sections = [];
    document.querySelectorAll('[id^="themesCell_theme_"]').forEach(el => {
      const entry = { name: el.innerText?.trim() || '' };
      if (el.classList.contains('select')) entry.active = true;
      sections.push(entry);
    });
    return sections;
  })()`;
}

/** Read open tabs bar. */
export function readTabsScript() {
  return `(() => {
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
    const tabs = [];
    document.querySelectorAll('[id^="openedCell_cmd_"]').forEach(el => {
      const text = norm(el.innerText);
      if (!text) return;
      const entry = { name: text };
      if (el.classList.contains('select')) entry.active = true;
      tabs.push(entry);
    });
    return tabs;
  })()`;
}

/** Switch to a tab by name (fuzzy match). Returns matched name or { error, available }. */
export function switchTabScript(name) {
  return `(() => {
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
    const target = ${JSON.stringify(name.toLowerCase().replace(/ё/g, 'е'))};
    const tabs = [...document.querySelectorAll('[id^="openedCell_cmd_"]')].filter(el => el.offsetWidth > 0 && norm(el.innerText));
    let best = tabs.find(el => norm(el.innerText).toLowerCase() === target);
    if (!best) best = tabs.find(el => norm(el.innerText).toLowerCase().includes(target));
    if (best) { best.click(); return norm(best.innerText); }
    return { error: 'not_found', available: tabs.map(el => norm(el.innerText)) };
  })()`;
}

/** Read commands in the function panel (current section). */
export function readCommandsScript() {
  return `(() => {
    const groups = [];
    const container = document.querySelector('#funcPanel_container table tr');
    if (!container) return groups;
    for (const td of container.children) {
      const commands = [];
      td.querySelectorAll('[id^="cmd_"][id$="_txt"]').forEach(el => {
        if (el.offsetWidth === 0) return;
        commands.push(el.innerText?.trim() || '');
      });
      if (commands.length > 0) groups.push(commands);
    }
    return groups;
  })()`;
}

/**
 * Read full form state for a given form number.
 * Uses shared READ_FORM_FN.
 */
export function readFormScript(formNum) {
  const p = `form${formNum}_`;
  return `(() => {
    ${READ_FORM_FN}
    return readForm(${JSON.stringify(p)});
  })()`;
}

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
      const label = titleEl ? (titleEl.innerText?.trim().replace(/:\s*$/, '').replace(/\u00a0/g, ' ') || '') : '';
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
      if (!text) return;
      const r = box.getBoundingClientRect();
      columns.push({ text, x: r.x, w: r.width, right: r.x + r.width });
    });

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
        const val = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
        if (!val) return;
        // Match cell to column by X-coordinate overlap
        const r = box.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        const col = columns.find(c => cx >= c.x && cx < c.right);
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
      rows.push(row);
    }
    const isTree = !!body.querySelector('.gridBoxTree');
    const hasGroups = rows.some(r => r._kind === 'group');
    const result = { name, columns: columns.map(c => c.text), rows, total, offset: ${offset}, shown: rows.length };
    if (isTree) result.viewMode = 'tree';
    if (hasGroups) result.hierarchical = true;
    return result;
  })()`;
}

/**
 * Combined: detect form + read form + read open tabs.
 * Single evaluate call instead of 3. Used by browser.getFormState().
 */
export function getFormStateScript() {
  return `(() => {
    ${DETECT_FORM_FN}
    ${READ_FORM_FN}
    const formNum = detectForm();
    if (formNum === null) return { form: null, message: 'No form detected' };
    const p = 'form' + formNum + '_';
    const formData = readForm(p);
    // Open tabs bar
    const openTabs = [];
    document.querySelectorAll('[id^="openedCell_cmd_"]').forEach(el => {
      const text = el.innerText?.trim();
      if (!text) return;
      const entry = { name: text };
      if (el.classList.contains('select')) entry.active = true;
      openTabs.push(entry);
    });
    const activeTab = openTabs.find(t => t.active)?.name || null;
    return { form: formNum, activeTab, ...formData };
  })()`;
}

/**
 * Navigate to a section by name (fuzzy match).
 * Returns the matched section name, or { error, available }.
 */
export function navigateSectionScript(name) {
  return `(() => {
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ').replace(/[\\r\\n]+/g, ' ').replace(/  +/g, ' ') || '').replace(/ё/gi, 'е');
    const target = ${JSON.stringify(name.toLowerCase().replace(/ё/g, 'е').replace(/[\r\n]+/g, ' ').replace(/  +/g, ' '))};
    const els = [...document.querySelectorAll('[id^="themesCell_theme_"]')];
    let bestEl = els.find(el => norm(el.innerText).toLowerCase() === target);
    if (!bestEl) bestEl = els.find(el => norm(el.innerText).toLowerCase().includes(target));
    if (bestEl) { bestEl.click(); return norm(bestEl.innerText); }
    return { error: 'not_found', available: els.map(el => norm(el.innerText)).filter(Boolean) };
  })()`;
}

/**
 * Open a command from function panel by name (fuzzy match).
 */
export function openCommandScript(name) {
  return `(() => {
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
    const target = ${JSON.stringify(name.toLowerCase().replace(/ё/g, 'е'))};
    const els = [...document.querySelectorAll('[id^="cmd_"][id$="_txt"]')].filter(el => el.offsetWidth > 0);
    let bestEl = els.find(el => norm(el.innerText).toLowerCase() === target);
    if (!bestEl) bestEl = els.find(el => norm(el.innerText).toLowerCase().includes(target));
    if (bestEl) { bestEl.click(); return norm(bestEl.innerText); }
    return { error: 'not_found', available: els.map(el => norm(el.innerText)).filter(Boolean) };
  })()`;
}

/**
 * Find a clickable element on the current form (button, hyperlink, tab, frame button).
 * Returns { id, kind, name } for Playwright page.click(), or { error, available }.
 * Supports synonym matching: visible text AND internal name from DOM ID.
 * Fuzzy order: exact name -> exact label -> includes name -> includes label.
 */
export function findClickTargetScript(formNum, text, { tableName, gridSelector } = {}) {
  const p = `form${formNum}_`;
  return `(() => {
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
    const target = ${JSON.stringify(text.toLowerCase().replace(/ё/g, 'е'))};
    const p = ${JSON.stringify(p)};
    const tableName = ${JSON.stringify(tableName || '')};
    const gridSelector = ${JSON.stringify(gridSelector || '')};
    const items = [];

    // Buttons (a.press)
    [...document.querySelectorAll('a.press[id^="' + p + '"]')].filter(el => el.offsetWidth > 0).forEach(el => {
      const idName = el.id.replace(p, '');
      if (/_(?:DLB|CLR|OB|CB)$/.test(idName)) return;
      const span = el.querySelector('.submenuText') || el.querySelector('span');
      const text = norm(span?.textContent) || norm(el.innerText);
      if (!text && !el.classList.contains('pressCommand')) return;
      const isSubmenu = /^(?:Подменю|allActions)/i.test(idName);
      items.push({ id: el.id, name: text || idName, label: idName, kind: isSubmenu ? 'submenu' : 'button' });
    });

    // Hyperlinks (staticTextHyper)
    [...document.querySelectorAll('[id^="' + p + '"].staticTextHyper')].filter(el => el.offsetWidth > 0).forEach(el => {
      const idName = el.id.replace(p, '');
      const text = norm(el.innerText);
      items.push({ id: el.id, name: text, label: idName, kind: 'hyperlink' });
    });

    // Frame buttons
    [...document.querySelectorAll('[id^="' + p + '"] .frameButton, [id^="' + p + '"].frameButton')].filter(el => el.offsetWidth > 0).forEach(el => {
      const text = norm(el.innerText);
      if (!text) return;
      items.push({ id: el.id, name: text, label: '', kind: 'frameButton' });
    });

    // Checkboxes (div.checkbox) — match by label or internal name
    [...document.querySelectorAll('[id^="' + p + '"].checkbox')].filter(el => el.offsetWidth > 0).forEach(el => {
      const idName = el.id.replace(p, '');
      const titleEl = document.getElementById(p + idName + '#title_text');
      const label = norm(titleEl?.innerText || '').replace(/:/g, '').trim();
      items.push({ id: el.id, name: label || idName, label: idName, kind: 'checkbox' });
    });

    // Tabs (scoped to form)
    [...document.querySelectorAll('[data-content]')].filter(el => {
      if (el.offsetWidth === 0) return false;
      let node = el.parentElement;
      while (node) {
        if (node.id && node.id.startsWith(p)) return true;
        node = node.parentElement;
      }
      return false;
    }).forEach(el => {
      items.push({ id: el.id, name: el.dataset.content, label: '', kind: 'tab' });
    });

    // Navigation panel items (FormNavigationPanel) — in parent page{N}
    const formEl = document.querySelector('[id^="' + p + '"]');
    if (formEl) {
      let pageEl = formEl.parentElement;
      while (pageEl && !(pageEl.id && /^page\\d+$/.test(pageEl.id))) pageEl = pageEl.parentElement;
      if (pageEl) {
        pageEl.querySelectorAll('.navigationItem').forEach(el => {
          if (el.offsetWidth === 0) return;
          const nameEl = el.querySelector('.navigationItemName');
          const text = norm(nameEl?.innerText || '');
          if (!text) return;
          items.push({ id: el.id, name: text, label: '', kind: 'navigation' });
        });
      }
    }

    // When table is specified, scope button search to grid's parent container
    if (gridSelector) {
      const gridEl = document.querySelector(gridSelector);
      if (gridEl) {
        // Find parent container that has id with formPrefix and contains the grid
        let container = gridEl.parentElement;
        while (container && container !== document.body) {
          if (container.id && container.id.startsWith(p)) break;
          container = container.parentElement;
        }
        // Filter items to those inside the container
        const containerItems = container && container !== document.body
          ? items.filter(i => { const el = document.getElementById(i.id); return el && container.contains(el); })
          : [];
        // Try fuzzy match within container first
        let cf = containerItems.find(i => i.name.toLowerCase() === target);
        if (!cf) cf = containerItems.find(i => i.label && i.label.toLowerCase() === target);
        if (!cf && target.length >= 4) cf = containerItems.find(i => i.name.toLowerCase().includes(target));
        if (!cf && target.length >= 4) cf = containerItems.find(i => i.label && i.label.toLowerCase().includes(target));
        if (cf) return { id: cf.id, kind: cf.kind, name: cf.name };
        // Fallback: filter by gridName id-prefix (e.g. ИсходящиеКоманднаяПанель_Добавить)
        const gridName = gridEl.id ? gridEl.id.replace(p, '') : '';
        if (gridName) {
          const prefixItems = items.filter(i => i.label && i.label.includes(gridName));
          let pf = prefixItems.find(i => i.name.toLowerCase() === target);
          if (!pf && target.length >= 4) pf = prefixItems.find(i => i.label && i.label.toLowerCase().includes(target));
          if (!pf && target.length >= 4) pf = prefixItems.find(i => i.name.toLowerCase().includes(target));
          if (pf) return { id: pf.id, kind: pf.kind, name: pf.name };
        }
      }
      // Fall through to unscoped search
    }

    // Fuzzy match: exact name -> exact label -> startsWith name -> startsWith label -> includes name -> includes label
    // Skip includes() for short strings (< 4 chars) to avoid false positives
    // e.g. "Да" matching "КомандаУстановитьВсе"
    let found = items.find(i => i.name.toLowerCase() === target);
    if (!found) found = items.find(i => i.label && i.label.toLowerCase() === target);
    if (!found) found = items.find(i => i.name.toLowerCase().startsWith(target));
    if (!found) found = items.find(i => i.label && i.label.toLowerCase().startsWith(target));
    if (!found && target.length >= 4) found = items.find(i => i.name.toLowerCase().includes(target));
    if (!found && target.length >= 4) found = items.find(i => i.label && i.label.toLowerCase().includes(target));

    if (found) {
      return { id: found.id, kind: found.kind, name: found.name };
    }

    // Grid rows — fallback: search in table rows (for hierarchical/tree navigation)
    // Search ALL visible grids (or specific grid when table parameter is set)
    let grids;
    if (gridSelector) {
      const g = document.querySelector(gridSelector);
      grids = g ? [g] : [];
    } else {
      grids = [...document.querySelectorAll('[id^="' + p + '"].grid')].filter(g => g.offsetWidth > 0);
    }
    for (const grid of grids) {
      const body = grid.querySelector('.gridBody');
      if (!body) continue;
      const lines = [...body.querySelectorAll('.gridLine')];
      for (const line of lines) {
        const textBoxes = [...line.querySelectorAll('.gridBoxText')].filter(b => b.offsetWidth > 0);
        const rowTexts = textBoxes.map(b => b.innerText?.trim() || '').filter(Boolean);
        const firstCell = rowTexts[0]?.toLowerCase() || '';
        const rowText = rowTexts.join(' ').toLowerCase();
        if (firstCell === target || rowText === target || (target.length >= 4 && (firstCell.includes(target) || rowText.includes(target)))) {
          const imgBox = line.querySelector('.gridBoxImg');
          const isGroup = imgBox?.querySelector('.gridListH') !== null;
          const isParent = imgBox?.querySelector('.gridListV') !== null;
          const isTreeNode = line.querySelector('.gridBoxTree') !== null;
          const hasChildren = line.querySelector('[tree="true"]') !== null;
          let kind;
          if (isGroup) kind = 'gridGroup';
          else if (isParent) kind = 'gridParent';
          else if (isTreeNode && hasChildren) kind = 'gridTreeNode';
          else kind = 'gridRow';
          const r = line.getBoundingClientRect();
          return { id: '', kind, name: rowTexts[0] || '', gridId: grid.id,
            x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
        }
      }
    }

    return { error: 'not_found', available: items.map(i => i.name).filter(Boolean) };
  })()`;
}

/**
 * Find a field's action button (DLB, OB, CLR, CB) by fuzzy field name.
 * Returns { fieldName, buttonId, buttonType } or { error, available }.
 */
export function findFieldButtonScript(formNum, fieldName, buttonSuffix = 'DLB') {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const target = ${JSON.stringify(fieldName.toLowerCase().replace(/ё/g, 'е'))};
    const suffix = ${JSON.stringify(buttonSuffix)};
    const allFields = [];
    document.querySelectorAll('input.editInput[id^="' + p + '"], textarea[id^="' + p + '"]').forEach(el => {
      if (el.offsetWidth === 0) return;
      const name = el.id.replace(p, '').replace(/_i\\d+$/, '');
      const titleEl = document.getElementById(p + name + '#title_text')
        || document.getElementById(p + name + '#title_div');
      const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/:$/, '');
      allFields.push({ name, label });
    });
    // Also collect checkboxes for DCS pair matching
    const allCheckboxes = [];
    document.querySelectorAll('[id^="' + p + '"].checkbox').forEach(el => {
      if (el.offsetWidth === 0) return;
      const name = el.id.replace(p, '');
      const titleEl = document.getElementById(p + name + '#title_text');
      const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/:$/, '');
      allCheckboxes.push({ inputId: el.id, name, label });
    });
    // Build DCS pairs: checkbox label → paired value field
    const dcsPairs = {};
    for (const f of [...allFields, ...allCheckboxes]) {
      const m = f.name.match(/^(.+Элемент\\d+)(Использование|Значение)$/);
      if (!m) continue;
      if (!dcsPairs[m[1]]) dcsPairs[m[1]] = {};
      dcsPairs[m[1]][m[2]] = f;
    }
    let found = allFields.find(f => f.name.toLowerCase() === target);
    if (!found) found = allFields.find(f => f.label && f.label.toLowerCase() === target);
    if (!found) found = allFields.find(f => f.name.toLowerCase().includes(target));
    if (!found) found = allFields.find(f => f.label && f.label.toLowerCase().includes(target));
    // DCS pair: match checkbox or value label → resolve to paired value field
    let dcsCheckbox = null;
    if (!found) {
      for (const pair of Object.values(dcsPairs)) {
        const cb = pair['Использование'];
        const val = pair['Значение'];
        if (!cb || !val) continue;
        const pairLabel = ((val.label || cb.label || '').replace(/:$/, '')).toLowerCase();
        if (pairLabel && (pairLabel === target || pairLabel.includes(target) || target.includes(pairLabel))) {
          found = val;
          dcsCheckbox = cb;
          break;
        }
      }
    }
    if (!found) {
      return { error: 'field_not_found', available: allFields.map(f => f.label ? f.name + ' (' + f.label + ')' : f.name) };
    }
    const btnId = p + found.name + '_' + suffix;
    const btn = document.getElementById(btnId);
    if (!btn || btn.offsetWidth === 0) {
      return { error: 'button_not_found', fieldName: found.name, message: suffix + ' button not visible for field ' + found.name };
    }
    const result = { fieldName: found.name, buttonId: btnId, buttonType: suffix };
    if (dcsCheckbox) result.dcsCheckbox = { inputId: dcsCheckbox.inputId };
    return result;
  })()`;
}

/**
 * Read open popup/submenu items.
 * Looks for absolutely positioned visible popup containers with a.press items inside.
 * Returns [{ id, name }] or { error }.
 */
export function readSubmenuScript() {
  return `(() => {
    const items = [];
    const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');

    // 1. DLB dropdown (#editDropDown with .eddText items)
    const edd = document.getElementById('editDropDown');
    if (edd && edd.offsetWidth > 0 && edd.offsetHeight > 0) {
      edd.querySelectorAll('.eddText').forEach(el => {
        if (el.offsetWidth === 0) return;
        const text = norm(el.innerText);
        if (!text) return;
        const r = el.getBoundingClientRect();
        items.push({ id: '', name: text, kind: 'dropdown',
          x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
      });
      // Detect "Показать все" link in EDD footer
      // Structure: div.eddBottom > div > span.hyperlink "Показать все"
      let showAllEl = edd.querySelector('.eddBottom .hyperlink');
      if (!showAllEl || showAllEl.offsetWidth === 0) {
        // Fallback: scan all visible elements for text match
        const candidates = [...edd.querySelectorAll('a.press, a, span, div')]
          .filter(el => el.offsetWidth > 0 && el.children.length === 0);
        showAllEl = candidates.find(el => {
          const t = norm(el.innerText).toLowerCase();
          return t === 'показать все' || t === 'show all';
        });
      }
      if (showAllEl) {
        const r = showAllEl.getBoundingClientRect();
        items.push({ id: showAllEl.id || '', name: norm(showAllEl.innerText), kind: 'showAll',
          x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
      }
      if (items.length > 0) return items;
    }

    // 2. Cloud submenu (allActions / command panel menus — div.cloud with .submenuText items)
    // Read ALL visible high-z clouds (main menu + nested submenus)
    const clouds = [...document.querySelectorAll('.cloud')].filter(c => c.offsetWidth > 0 && c.offsetHeight > 0);
    const seen = new Set();
    clouds.forEach(c => {
      const z = parseInt(getComputedStyle(c).zIndex) || 0;
      if (z <= 1000) return;
      c.querySelectorAll('.submenuText').forEach(el => {
        if (el.offsetWidth === 0) return;
        const text = norm(el.innerText);
        if (!text || seen.has(text)) return;
        seen.add(text);
        const block = el.closest('.submenuBlock');
        if (block && block.classList.contains('submenuBlockDisabled')) return;
        const hasSub = block && /_sub$/.test(block.id);
        const r = el.getBoundingClientRect();
        items.push({ id: block?.id || '', name: text, kind: hasSub ? 'submenuArrow' : 'submenu',
          x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
      });
    });
    if (items.length > 0) return items;

    // 3. Submenu popups — find the topmost positioned container with non-form a.press items
    const popups = [...document.querySelectorAll('div')].filter(c => {
      const style = getComputedStyle(c);
      return (style.position === 'absolute' || style.position === 'fixed')
        && c.offsetWidth > 0 && c.offsetHeight > 0;
    }).sort((a, b) => {
      const za = parseInt(getComputedStyle(a).zIndex) || 0;
      const zb = parseInt(getComputedStyle(b).zIndex) || 0;
      return zb - za;
    });
    for (const container of popups) {
      // Only direct a.press children or those not nested in another positioned div
      const menuItems = [...container.querySelectorAll('a.press')].filter(el => {
        if (el.offsetWidth === 0) return false;
        if (el.id && /^form\\d+_/.test(el.id)) return false;
        // Skip if this a.press is inside a deeper positioned container
        let parent = el.parentElement;
        while (parent && parent !== container) {
          const ps = getComputedStyle(parent).position;
          if (ps === 'absolute' || ps === 'fixed') return false;
          parent = parent.parentElement;
        }
        return true;
      });
      if (menuItems.length < 2) continue; // Not a real menu
      const seen = new Set();
      menuItems.forEach(el => {
        const text = norm(el.innerText);
        if (!text) return;
        if (seen.has(text)) return;
        seen.add(text);
        const r = el.getBoundingClientRect();
        items.push({ id: el.id || '', name: text, kind: 'submenu',
          x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
      });
      if (items.length > 0) break; // Found the popup menu
    }

    if (items.length === 0) return { error: 'no_popup', message: 'No open popup/submenu found' };
    return items;
  })()`;
}

/**
 * Click a popup/dropdown item by text match (evaluate-based for items without IDs).
 * Returns true if clicked, false if not found.
 */
export function clickPopupItemScript(text) {
  return `(() => {
    const target = ${JSON.stringify(text.toLowerCase().replace(/ё/g, 'е'))};
    // 1. DLB dropdown (#editDropDown .eddText items)
    const edd = document.getElementById('editDropDown');
    if (edd && edd.offsetWidth > 0) {
      for (const el of edd.querySelectorAll('.eddText')) {
        if (el.offsetWidth === 0) continue;
        const t = el.innerText?.trim() || '';
        if (t.toLowerCase() === target || t.toLowerCase().includes(target)) {
          el.click();
          return t;
        }
      }
    }

    // 2. Submenu popups (a.press in absolutely positioned containers)
    const containers = [...document.querySelectorAll('div')].filter(c => {
      const style = getComputedStyle(c);
      return (style.position === 'absolute' || style.position === 'fixed')
        && c.offsetWidth > 0 && c.offsetHeight > 0;
    });
    for (const container of containers) {
      const items = [...container.querySelectorAll('a.press')]
        .filter(el => el.offsetWidth > 0);
      for (const el of items) {
        const t = el.innerText?.trim() || '';
        if (t.toLowerCase() === target || t.toLowerCase().includes(target)) {
          el.click();
          return t;
        }
      }
    }
    return null;
  })()`;
}

/**
 * Check for validation errors / diagnostics after an action.
 * Detects three patterns:
 *   1. Inline balloon tooltip (div.balloon with .balloonMessage)
 *   2. Messages panel (div.messages with msg0, msg1... grid rows)
 *   3. Modal error dialog (high-numbered form with pressDefault + static texts)
 * Returns { balloon, messages[], modal } or null if no errors.
 */
export function checkErrorsScript() {
  return `(() => {
    const result = {};

    // 1. Inline balloon tooltip
    const balloon = document.querySelector('.balloon');
    if (balloon && balloon.offsetWidth > 0) {
      const msg = balloon.querySelector('.balloonMessage');
      const title = balloon.querySelector('.balloonTitle');
      if (msg) {
        result.balloon = {
          title: title?.innerText?.trim() || 'Ошибка',
          message: msg.innerText?.trim() || ''
        };
        // Count navigation arrows to indicate total errors
        const fwd = balloon.querySelector('.balloonJumpFwd');
        const back = balloon.querySelector('.balloonJumpBack');
        const fwdDisabled = fwd?.classList.contains('disabled');
        const backDisabled = back?.classList.contains('disabled');
        if (fwd && !fwdDisabled) result.balloon.hasNext = true;
        if (back && !backDisabled) result.balloon.hasPrev = true;
      }
    }

    // 2. Messages panel (div.messages — pick visible one, multiple may exist across tabs)
    const msgPanels = [...document.querySelectorAll('.messages')].filter(el => el.offsetWidth > 0);
    for (const msgPanel of msgPanels) {
      const msgs = [];
      msgPanel.querySelectorAll('[id^="msg"]').forEach(line => {
        if (line.offsetWidth === 0) return;
        const textEl = line.querySelector('.gridBoxText');
        const text = (textEl || line).innerText?.trim();
        if (text) msgs.push(text);
      });
      if (msgs.length > 0) { result.messages = msgs; break; }
    }

    // 3+4. Modal dialogs: confirmation (multiple buttons) or error (single pressDefault)
    // Uses form container ancestry to group buttons — pressButton elements often lack form-prefixed IDs
    // Note: 1C shows some modals WITHOUT #modalSurface (e.g. "Не удалось записать" uses ps*win floating window)
    // so we always scan for small forms with button patterns, regardless of modalSurface state
    const formButtons = {};
    [...document.querySelectorAll('a.press.pressButton')].forEach(btn => {
      if (btn.offsetWidth === 0) return;
      const container = btn.closest('[id$="_container"]');
      const m = container?.id?.match(/^form(\\d+)_/);
      if (!m) return;
      const fn = m[1];
      if (!formButtons[fn]) formButtons[fn] = [];
      formButtons[fn].push(btn);
    });

    for (const [fn, buttons] of Object.entries(formButtons)) {
      const p = 'form' + fn + '_';
      const elCount = document.querySelectorAll('[id^="' + p + '"]').length;
      if (elCount > 100) continue; // Skip large content forms
      if (buttons.length > 1) {
        // Confirmation dialog (multiple buttons: Да/Нет, OK/Отмена, etc.)
        // Must have a Message element — real 1C confirmations always have form{N}_Message.
        // Without it, this is just a regular form with multiple buttons (e.g. EPF form).
        const msgEl = document.getElementById(p + 'Message');
        if (!msgEl || msgEl.offsetWidth === 0) continue;
        const message = msgEl.innerText?.trim() || '';
        const btnNames = buttons.map(el => {
          const b = { name: el.innerText?.trim() || '' };
          if (el.classList.contains('pressDefault')) b.default = true;
          return b;
        }).filter(b => b.name);
        result.confirmation = { message, buttons: btnNames.map(b => b.name), formNum: parseInt(fn) };
        break;
      }
    }

    // Single-button modal: error dialog with pressDefault + staticText
    // Skip forms with input fields — those are data entry forms (e.g. register record),
    // not error dialogs. Real error modals only have staticText + buttons.
    if (!result.confirmation) {
      for (const [fn, buttons] of Object.entries(formButtons)) {
        const p = 'form' + fn + '_';
        const elCount = document.querySelectorAll('[id^="' + p + '"]').length;
        if (elCount > 100) continue;
        if (buttons.length !== 1 || !buttons[0].classList.contains('pressDefault')) continue;
        const hasInputs = document.querySelectorAll('input.editInput[id^="' + p + '"]').length > 0;
        if (hasInputs) continue;
        const texts = [...document.querySelectorAll('[id^="' + p + '"].staticText')]
          .filter(el => el.offsetWidth > 0)
          .map(el => el.innerText?.trim())
          .filter(Boolean);
        if (texts.length > 0) {
          result.modal = { message: texts.join(' '), formNum: parseInt(fn), button: buttons[0].innerText?.trim() || '' };
          break;
        }
      }
    }

    return (result.balloon || result.messages || result.modal || result.confirmation) ? result : null;
  })()`;
}

/**
 * Resolve field names to element IDs for Playwright page.fill().
 * Returns [{ field, inputId, name, label }] or [{ field, error, available }].
 * Supports synonym matching: internal name AND visible label.
 * Fuzzy order: exact name -> exact label -> includes name -> includes label.
 */
export function resolveFieldsScript(formNum, fields) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const fieldNames = ${JSON.stringify(Object.keys(fields))};
    const results = [];

    // Build field map with name + label for synonym matching
    const allFields = [];
    document.querySelectorAll('input.editInput[id^="' + p + '"], textarea[id^="' + p + '"]').forEach(el => {
      if (el.offsetWidth === 0) return;
      const name = el.id.replace(p, '').replace(/_i\\d+$/, '');
      const titleEl = document.getElementById(p + name + '#title_text')
        || document.getElementById(p + name + '#title_div');
      const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/:$/, '');
      const last = { inputId: el.id, name, label };
      if (document.getElementById(p + name + '_DLB')?.offsetWidth > 0) last.hasSelect = true;
      allFields.push(last);
    });
    // Checkboxes
    document.querySelectorAll('[id^="' + p + '"].checkbox').forEach(el => {
      if (el.offsetWidth === 0) return;
      const name = el.id.replace(p, '');
      const titleEl = document.getElementById(p + name + '#title_text');
      const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/:$/, '');
      const checked = el.classList.contains('checked') || el.classList.contains('checkboxOn') || el.classList.contains('select');
      allFields.push({ inputId: el.id, name, label, isCheckbox: true, checked });
    });
    // Radio button groups — base element = option 0, others are #N#radio
    const radioSeen = new Set();
    document.querySelectorAll('[id^="' + p + '"].radio').forEach(el => {
      if (el.offsetWidth === 0) return;
      const id = el.id.replace(p, '');
      // Skip if already processed or if it's a sub-element (#N#radio)
      const m = id.match(/^(.+?)#(\\d+)#radio$/);
      const groupName = m ? m[1] : (!id.includes('#') ? id : null);
      if (!groupName || radioSeen.has(groupName)) return;
      radioSeen.add(groupName);
      const titleEl = document.getElementById(p + groupName + '#title_text');
      const label = (titleEl?.innerText?.trim() || '').replace(/\\n/g, ' ').replace(/:$/, '');
      // Collect options: option 0 is the base element, options 1+ have #N#radio
      const options = [];
      // Option 0: base element
      const base = document.getElementById(p + groupName);
      if (base && base.classList.contains('radio') && base.offsetWidth > 0) {
        const textEl = document.getElementById(p + groupName + '#0#radio_text');
        options.push({ index: 0, label: textEl?.innerText?.trim() || '', selected: base.classList.contains('select') });
      }
      // Options 1+
      for (let i = 1; i < 20; i++) {
        const opt = document.getElementById(p + groupName + '#' + i + '#radio');
        if (!opt || opt.offsetWidth === 0) break;
        const textEl = document.getElementById(p + groupName + '#' + i + '#radio_text');
        options.push({ index: i, label: textEl?.innerText?.trim() || '', selected: opt.classList.contains('select') });
      }
      allFields.push({ inputId: p + groupName, name: groupName, label, isRadio: true, options });
    });

    // Build DCS pairs: checkbox label → paired value field
    const dcsPairs = {};
    for (const f of allFields) {
      const m = f.name.match(/^(.+Элемент\\d+)(Использование|Значение)$/);
      if (!m) continue;
      if (!dcsPairs[m[1]]) dcsPairs[m[1]] = {};
      dcsPairs[m[1]][m[2]] = f;
    }

    for (const fieldName of fieldNames) {
      const target = fieldName.toLowerCase().replace(/\\n/g, ' ').replace(/:$/, '');
      // Fuzzy: exact name -> exact label -> includes name -> includes label
      let found = allFields.find(f => f.name.toLowerCase() === target);
      if (!found) found = allFields.find(f => f.label && f.label.toLowerCase() === target);
      if (!found) found = allFields.find(f => f.name.toLowerCase().includes(target));
      if (!found) found = allFields.find(f => f.label && f.label.toLowerCase().includes(target));
      // DCS pair: match checkbox or value label → resolve to paired value field
      if (!found) {
        for (const pair of Object.values(dcsPairs)) {
          const cb = pair['Использование'];
          const val = pair['Значение'];
          if (!cb || !val) continue;
          const pairLabel = ((val.label || cb.label || '').replace(/:$/, '')).toLowerCase();
          if (pairLabel && (pairLabel === target || pairLabel.includes(target) || target.includes(pairLabel))) {
            found = val;
            found._dcsCheckbox = cb;
            break;
          }
        }
      }

      if (found) {
        const entry = { field: fieldName, inputId: found.inputId, name: found.name, label: found.label };
        if (found.isCheckbox) { entry.isCheckbox = true; entry.checked = found.checked; }
        if (found.isRadio) { entry.isRadio = true; entry.options = found.options; }
        if (found.hasSelect) entry.hasSelect = true;
        if (found._dcsCheckbox) {
          entry.dcsCheckbox = { inputId: found._dcsCheckbox.inputId, checked: found._dcsCheckbox.checked };
          delete found._dcsCheckbox;
        }
        results.push(entry);
      } else {
        const available = allFields.map(f => f.label ? f.name + ' (' + f.label + ')' : f.name);
        results.push({ field: fieldName, error: 'not_found', available });
      }
    }
    return results;
  })()`;
}
