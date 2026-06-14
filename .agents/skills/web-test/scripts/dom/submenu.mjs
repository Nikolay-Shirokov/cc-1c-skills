// web-test dom/submenu v1.0 — popup/submenu reading and clicking
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

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
