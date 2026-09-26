// web-test dom/edd v1.0 — DOM scripts for the #editDropDown autocomplete popup
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Read the `#editDropDown` autocomplete popup.
 *
 * Returns `{ visible: false }` when EDD is absent/hidden, or
 * `{ visible: true, items: [{ name, x, y }] }` with center coords suitable
 * for `page.mouse.click(x, y)`.
 *
 * Note: `page.mouse.click` is often intercepted by `div.surface` overlays
 * from DLB — prefer `clickEddItemViaDispatchScript` for those cases.
 */
export function readEddScript() {
  return `(() => {
    const edd = document.getElementById('editDropDown');
    if (!edd || edd.offsetWidth === 0) return { visible: false };
    const eddTexts = [...edd.querySelectorAll('.eddText')].filter(el => el.offsetWidth > 0);
    return {
      visible: true,
      items: eddTexts.map(el => {
        const r = el.getBoundingClientRect();
        return { name: el.innerText?.trim() || '', x: r.x + r.width / 2, y: r.y + r.height / 2 };
      })
    };
  })()`;
}

/**
 * Is the EDD popup currently visible? Returns boolean.
 * Lighter than `readEddScript` when only presence matters.
 */
export function isEddVisibleScript() {
  return `(() => {
    const edd = document.getElementById('editDropDown');
    return !!(edd && edd.offsetWidth > 0);
  })()`;
}

/**
 * Click an EDD item by name via `dispatchEvent` — bypasses `div.surface`
 * overlays from DLB that intercept `page.mouse.click`.
 *
 * Matching is fuzzy: exact (with optional `(suffix)` strip) → includes,
 * normalizes ё/е and NBSP.
 *
 * Returns the clicked item's innerText (trimmed), or `null` when no match.
 */
export function clickEddItemViaDispatchScript(itemName) {
  return `(() => {
    const edd = document.getElementById('editDropDown');
    if (!edd || edd.offsetWidth === 0) return null;
    const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
    const target = ny(${JSON.stringify(itemName.toLowerCase())});
    const items = [...edd.querySelectorAll('.eddText')].filter(el => el.offsetWidth > 0);
    function clickEl(el) {
      const r = el.getBoundingClientRect();
      const opts = { bubbles: true, cancelable: true, clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
      el.dispatchEvent(new MouseEvent('mousedown', opts));
      el.dispatchEvent(new MouseEvent('mouseup', opts));
      el.dispatchEvent(new MouseEvent('click', opts));
      return el.innerText.trim();
    }
    // Pass 1: exact match (prefer over partial)
    for (const el of items) {
      const t = ny((el.innerText?.trim() || '').toLowerCase());
      if (t === target) return clickEl(el);
      const stripped = t.replace(/\\s*\\([^)]*\\)\\s*$/, '');
      if (stripped === target) return clickEl(el);
    }
    // Pass 2: partial match
    for (const el of items) {
      const t = ny((el.innerText?.trim() || '').toLowerCase());
      if (t.includes(target) || target.includes(t.replace(/\\s*\\([^)]*\\)\\s*$/, ''))) return clickEl(el);
    }
    return null;
  })()`;
}

/**
 * Click the "Показать все" / "Show all" link in the EDD footer via
 * `dispatchEvent`. Tries `.eddBottom .hyperlink` first, then falls back
 * to scanning for span/div/a with the literal text.
 *
 * Returns boolean — whether the link was found and clicked.
 */
export function clickShowAllInEddScript() {
  return `(() => {
    const edd = document.getElementById('editDropDown');
    if (!edd || edd.offsetWidth === 0) return false;
    let el = edd.querySelector('.eddBottom .hyperlink');
    if (!el || el.offsetWidth === 0) {
      const candidates = [...edd.querySelectorAll('span, div, a')]
        .filter(e => e.offsetWidth > 0 && e.children.length === 0);
      el = candidates.find(e => {
        const t = (e.innerText?.trim() || '').toLowerCase();
        return t === 'показать все' || t === 'show all';
      });
    }
    if (!el) return false;
    const r = el.getBoundingClientRect();
    const opts = { bubbles: true, cancelable: true, clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.dispatchEvent(new MouseEvent('click', opts));
    return true;
  })()`;
}
