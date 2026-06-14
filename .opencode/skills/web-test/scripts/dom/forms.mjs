// web-test dom/forms v1.6 — form detection, content read, click-target/field-button resolution
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { DETECT_FORM_FN, READ_FORM_FN } from './_shared.mjs';

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
      const item = { id: el.id, name: text || idName, label: idName, kind: isSubmenu ? 'submenu' : 'button' };
      // Icon-only buttons: use tooltip for fuzzy match (1C puts title on parent .framePress)
      if (!text) { const tip = norm(el.title || el.parentElement?.title || ''); if (tip) item.tooltip = tip; }
      items.push(item);
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
      const idName = el.id.replace(p, '');
      if (!text && !idName) return;
      items.push({ id: el.id, name: text || idName, label: text ? '' : idName, kind: 'frameButton' });
    });

    // Tumbler items (toggle switch segments)
    [...document.querySelectorAll('[id^="' + p + '"].tumblerItem')].filter(el => el.offsetWidth > 0).forEach(el => {
      const idName = el.id.replace(p, '');
      const text = norm(el.innerText);
      items.push({ id: el.id, name: text || idName, label: idName, kind: 'tumbler' });
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
      const r = el.getBoundingClientRect();
      items.push({ id: el.id, name: el.dataset.content, label: '', kind: 'tab',
        x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
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
        if (cf) { const res = { id: cf.id, kind: cf.kind, name: cf.name }; if (cf.x != null) { res.x = cf.x; res.y = cf.y; } return res; }
        // Fallback: filter by gridName id-prefix (e.g. ИсходящиеКоманднаяПанель_Добавить)
        const gridName = gridEl.id ? gridEl.id.replace(p, '') : '';
        if (gridName) {
          const prefixItems = items.filter(i => i.label && i.label.includes(gridName));
          let pf = prefixItems.find(i => i.name.toLowerCase() === target);
          if (!pf && target.length >= 4) pf = prefixItems.find(i => i.label && i.label.toLowerCase().includes(target));
          if (!pf && target.length >= 4) pf = prefixItems.find(i => i.name.toLowerCase().includes(target));
          if (pf) { const res = { id: pf.id, kind: pf.kind, name: pf.name }; if (pf.x != null) { res.x = pf.x; res.y = pf.y; } return res; }
        }
      }
      // Fall through to unscoped search
    }

    // Fuzzy match: exact name -> exact label -> exact tooltip -> startsWith name -> startsWith label -> includes name -> includes label -> includes tooltip
    // Skip includes() for short strings (< 4 chars) to avoid false positives
    // e.g. "Да" matching "КомандаУстановитьВсе"
    let found = items.find(i => i.name.toLowerCase() === target);
    if (!found) found = items.find(i => i.label && i.label.toLowerCase() === target);
    if (!found) found = items.find(i => i.tooltip && i.tooltip.toLowerCase() === target);
    if (!found) found = items.find(i => i.name.toLowerCase().startsWith(target));
    if (!found) found = items.find(i => i.label && i.label.toLowerCase().startsWith(target));
    if (!found && target.length >= 4) found = items.find(i => i.name.toLowerCase().includes(target));
    if (!found && target.length >= 4) found = items.find(i => i.label && i.label.toLowerCase().includes(target));
    if (!found && target.length >= 4) found = items.find(i => i.tooltip && i.tooltip.toLowerCase().includes(target));

    if (found) {
      const res = { id: found.id, kind: found.kind, name: found.name };
      if (found.x != null) { res.x = found.x; res.y = found.y; }
      return res;
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
        const rowTexts = textBoxes.map(b => norm(b.innerText) || '').filter(Boolean);
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

    // Form input fields — LAST resort: focus a field by name/label without changing its value.
    // Only when no table scope is given ("если нет уточнения таблицы"): grid cells are handled elsewhere.
    // Reached only after every clickable target (button/link/tab/nav/grid row) failed to match,
    // so collisions between a field name and a real control are unlikely.
    const fields = [];
    if (!tableName) {
      [...document.querySelectorAll('input.editInput[id^="' + p + '"], textarea[id^="' + p + '"]')].forEach(el => {
        if (el.offsetWidth === 0) return;
        // Skip inputs inside a grid — those are table cells, not form fields.
        let n = el.parentElement; let inGrid = false;
        while (n) { if (n.classList && n.classList.contains('grid')) { inGrid = true; break; } n = n.parentElement; }
        if (inGrid) return;
        const idName = el.id.replace(p, '').replace(/_i\\d+$/, '');
        const titleEl = document.getElementById(p + idName + '#title_text') || document.getElementById(p + idName + '#title_div');
        const label = norm(titleEl?.innerText || '').replace(/:/g, '').trim();
        fields.push({ id: el.id, name: idName, label });
      });
      let ff = fields.find(f => f.label && f.label.toLowerCase() === target);
      if (!ff) ff = fields.find(f => f.name.toLowerCase() === target);
      if (!ff) ff = fields.find(f => f.label && f.label.toLowerCase().startsWith(target));
      if (!ff) ff = fields.find(f => f.name.toLowerCase().startsWith(target));
      if (!ff && target.length >= 4) ff = fields.find(f => f.label && f.label.toLowerCase().includes(target));
      if (!ff && target.length >= 4) ff = fields.find(f => f.name.toLowerCase().includes(target));
      if (ff) return { id: ff.id, kind: 'field', name: ff.label || ff.name };
    }

    const available = items.map(i => i.tooltip ? i.name + ' [' + i.tooltip + ']' : i.name).filter(Boolean);
    for (const f of fields) { const nm = f.label || f.name; if (nm && !available.includes(nm)) available.push(nm); }
    return { error: 'not_found', available };
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
      const cbEl = document.getElementById(p + name + '_CB');
      if (cbEl?.offsetWidth > 0) {
        last.hasPick = true;
        if (cbEl.classList.contains('iCalendB')) last.isDate = true;
        else if (cbEl.classList.contains('iCalcB')) last.isCalc = true;
      }
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
        if (found.hasPick) entry.hasPick = true;
        if (found.isDate) entry.isDate = true;
        if (found.isCalc) entry.isCalc = true;
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

/**
 * Detect a new form opened above `prevFormNum`. Two modes:
 *   default (broad) — counts any visible `[id]` element; finds dialogs whose
 *     `a.press` buttons have empty IDs. Used by selectValue / fillTableRow.
 *   `{ strict: true }` — only counts visible interactive elements
 *     (`input.editInput[id], a.press[id]`); used by fillReferenceField.
 *
 * Returns the highest new form number or `null`.
 */
export function detectNewFormScript(prevFormNum, { strict = false } = {}) {
  const selector = strict ? 'input.editInput[id], a.press[id]' : '[id]';
  const visibleCheck = strict
    ? 'el.offsetWidth === 0'
    : 'el.offsetWidth === 0 && el.offsetHeight === 0';
  return `(() => {
    const forms = {};
    document.querySelectorAll(${JSON.stringify(selector)}).forEach(el => {
      if (${visibleCheck}) return;
      const m = el.id.match(/^form(\\d+)_/);
      if (m) forms[m[1]] = true;
    });
    const nums = Object.keys(forms).map(Number).filter(n => n > ${prevFormNum});
    return nums.length > 0 ? Math.max(...nums) : null;
  })()`;
}

/**
 * Find the search input on a list form (matches `SearchString` / `ПоискаСтроки` id).
 * Returns `{ id, value } | null`.
 */
export function findSearchInputScript(formNum) {
  return `(() => {
    const p = 'form${formNum}_';
    const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
    return el ? { id: el.id, value: el.value || '' } : null;
  })()`;
}

/**
 * Find a visible `a.press` button by its exact innerText (after trim).
 * Returns `{ x, y } | null` for `page.mouse.click(x, y)`.
 *
 * Used for modal dialog buttons (Найти, OK) where page.click may be blocked.
 */
export function findNamedButtonScript(buttonText) {
  return `(() => {
    const btns = [...document.querySelectorAll('a.press')].filter(el => el.offsetWidth > 0);
    const btn = btns.find(el => el.innerText?.trim() === ${JSON.stringify(buttonText)});
    if (!btn) return null;
    const r = btn.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Find a CompareType radio button by index (1 = "contains", 2 = "exact", etc.)
 * on a search/filter dialog.
 *
 * Returns:
 *   - `{ already: true }`        — the group is disabled OR the radio is already selected
 *   - `{ x, y } | null`          — coords to click, or null if radio not present
 */
export function findCompareTypeRadioScript(dialogForm, radioIndex) {
  return `(() => {
    const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
    const group = document.getElementById(p + 'CompareType');
    if (group && group.classList.contains('disabled')) return { already: true };
    const el = document.getElementById(p + 'CompareType#' + ${JSON.stringify(String(radioIndex))} + '#radio');
    if (!el || el.offsetWidth === 0) return null;
    if (el.classList.contains('select')) return { already: true };
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Is any element of `form{dialogForm}_` currently visible?
 * Used to poll dialog dismissal after Escape.
 */
export function isFormVisibleScript(dialogForm) {
  return `(() => {
    const p = 'form${dialogForm}_';
    return [...document.querySelectorAll('[id^="' + p + '"]')].some(el => el.offsetWidth > 0);
  })()`;
}

/**
 * Find the Pattern input id on a search/filter dialog. Returns `id | null`.
 */
export function findPatternInputIdScript(dialogForm) {
  return `(() => {
    const p = 'form${dialogForm}_';
    const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Pattern/i.test(el.id));
    return el ? el.id : null;
  })()`;
}

/**
 * Is the given form a type selection dialog ("Выбор типа данных")?
 *
 * Detection signals (any one is sufficient):
 *   - `form{N}_OK` element exists      (selection forms use "Выбрать", not "OK")
 *   - `form{N}_ValueList` grid exists  (specific to type/value list dialogs)
 *   - window title contains "Выбор типа" on a visible `.toplineBoxTitle`
 *
 * Returns boolean.
 */
export function isTypeDialogScript(formNum) {
  return `(() => {
    const p = 'form' + ${formNum} + '_';
    const hasOK = !!document.getElementById(p + 'OK');
    const hasValueList = !!document.getElementById(p + 'ValueList');
    const hasTitle = [...document.querySelectorAll('.toplineBoxTitle')]
      .some(el => el.offsetWidth > 0 && /выбор типа/i.test(el.getAttribute('title') || ''));
    return hasOK || hasValueList || hasTitle;
  })()`;
}

/**
 * Click the "Показать все" / "Show all" link inside the "нет в списке"
 * cloud popup via `dispatchEvent`. Returns boolean — whether clicked.
 */
export function clickShowAllInNotInListCloudScript() {
  return `(() => {
    for (const el of document.querySelectorAll('div')) {
      if (el.offsetWidth === 0 || el.offsetHeight === 0) continue;
      const s = getComputedStyle(el);
      if (s.position !== 'absolute' && s.position !== 'fixed') continue;
      if ((parseInt(s.zIndex) || 0) < 100) continue;
      if (!(el.innerText || '').includes('нет в списке')) continue;
      const links = [...el.querySelectorAll('a, span, div')]
        .filter(e => e.offsetWidth > 0 && e.children.length === 0);
      const showAll = links.find(e => {
        const t = (e.innerText?.trim() || '').toLowerCase();
        return t === 'показать все' || t === 'show all';
      });
      if (showAll) {
        const r = showAll.getBoundingClientRect();
        const opts = { bubbles:true, cancelable:true,
          clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
        showAll.dispatchEvent(new MouseEvent('mousedown', opts));
        showAll.dispatchEvent(new MouseEvent('mouseup', opts));
        showAll.dispatchEvent(new MouseEvent('click', opts));
        return true;
      }
      return false;
    }
    return false;
  })()`;
}

/**
 * Is the "нет в списке" cloud popup visible? 1C shows it as a positioned div
 * (absolute/fixed, high z-index) whose text contains "нет в списке".
 * Returns boolean.
 */
export function isNotInListCloudVisibleScript() {
  return `(() => {
    const divs = document.querySelectorAll('div');
    for (const el of divs) {
      if (el.offsetWidth === 0 || el.offsetHeight === 0) continue;
      const style = getComputedStyle(el);
      if (style.position !== 'absolute' && style.position !== 'fixed') continue;
      const z = parseInt(style.zIndex) || 0;
      if (z < 100) continue;
      if ((el.innerText || '').includes('нет в списке')) return true;
    }
    return false;
  })()`;
}

/**
 * Find a child form opened above `prevFormNum` whose `form{N}_{buttonName}` button is visible.
 * Used by type-dialog Ctrl+F flow to locate the "Найти" sub-dialog form number.
 * Returns the form number or `null`.
 */
export function findChildFormByButtonScript(prevFormNum, buttonName, range = 20) {
  return `(() => {
    for (let n = ${prevFormNum} + 1; n < ${prevFormNum} + ${range}; n++) {
      const btn = document.getElementById('form' + n + '_' + ${JSON.stringify(buttonName)});
      if (btn && btn.offsetWidth > 0) return n;
    }
    return null;
  })()`;
}

/**
 * Read visible rows of a type-dialog ValueList grid and return rows that fuzzy-match `typeNorm`.
 *
 * `typeNorm` should already be lowercased, NBSP-normalized, ё→е normalized (use `normYo`).
 *
 * Returns `{ visible: string[], matches: Array<{ text, x, y }> }`.
 */
export function readTypeDialogVisibleRowsScript(formNum, typeNorm) {
  return `(() => {
    const grid = document.getElementById('form${formNum}_ValueList');
    if (!grid) return { visible: [], matches: [] };
    const body = grid.querySelector('.gridBody');
    if (!body) return { visible: [], matches: [] };
    const lines = body.querySelectorAll('.gridLine');
    const norm = s => (s || '').replace(/\\u00a0/g, ' ').trim();
    const typeNorm = ${JSON.stringify(typeNorm)};
    const visible = [];
    const matches = [];
    for (const line of lines) {
      const text = norm(line.innerText);
      if (!text) continue;
      visible.push(text);
      if (text.toLowerCase().replace(/ё/gi, 'е').includes(typeNorm)) {
        const r = line.getBoundingClientRect();
        matches.push({ text, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
      }
    }
    return { visible, matches };
  })()`;
}
