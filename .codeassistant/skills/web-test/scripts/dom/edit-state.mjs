// web-test dom/edit-state v1.1 — focus and popup detection inside the 1C web client
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Is the currently focused element an INPUT (optionally TEXTAREA too)?
 * Returns boolean.
 *
 * @param {object} [opts]
 * @param {boolean} [opts.allowTextarea=false] — also return true for TEXTAREA.
 */
export function isInputFocusedScript({ allowTextarea = false } = {}) {
  const cond = allowTextarea
    ? `f.tagName === 'INPUT' || f.tagName === 'TEXTAREA'`
    : `f.tagName === 'INPUT'`;
  return `(() => {
    const f = document.activeElement;
    return !!(f && (${cond}));
  })()`;
}

/**
 * Is the currently focused INPUT/TEXTAREA inside a `.grid` ancestor?
 * Used to verify grid edit-mode (active cell editor).
 *
 * @param {string} [gridSelector] — when given, only `true` if the focused input
 *   is inside that specific grid. Without it — any `.grid` ancestor counts.
 *
 * Returns boolean.
 */
export function isInputFocusedInGridScript(gridSelector) {
  const sel = gridSelector ? JSON.stringify(gridSelector) : 'null';
  return `(() => {
    const f = document.activeElement;
    if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
    const sel = ${sel};
    if (sel) {
      const grid = document.querySelector(sel);
      return !!(grid && grid.contains(f));
    }
    let n = f;
    while (n) {
      if (n.classList?.contains('grid')) return true;
      n = n.parentElement;
    }
    return false;
  })()`;
}

/**
 * Is a calculator (`.calculate`) or calendar (`.frameCalendar`) popup visible?
 * Returns `'calculator' | 'calendar' | null`.
 *
 * For the "popup gone" check, callers use: `!await findOpenPopup()`.
 */
export function findOpenPopupScript() {
  return `(() => {
    const calc = document.querySelector('.calculate');
    if (calc && calc.offsetWidth > 0) return 'calculator';
    const cal = document.querySelector('.frameCalendar');
    if (cal && cal.offsetWidth > 0) return 'calendar';
    return null;
  })()`;
}
