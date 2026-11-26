// web-test dom/nav v1.0 — sections panel, tabs bar, function panel commands
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

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
