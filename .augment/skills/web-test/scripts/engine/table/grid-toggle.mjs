// web-test table/grid-toggle v1.17 — shared icon-detection for grid expand/
// collapse toggles. Used by clickElement's gridGroup/gridParent and
// gridTreeNode branches; the actual mouse click stays in the caller because
// it depends on the caller-local modifier-key handling.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page } from '../core/state.mjs';

/**
 * Locate the toggle icon for the grid row at `target.y`. Inspects the row
 * under that Y-coordinate inside the resolved grid, returns the icon's
 * center coordinates and current expanded state — or `null` if no toggle
 * icon is present (e.g. leaf node or detached row).
 *
 * @param {{y:number, gridId?:string}} target
 * @param {number} formNum
 * @param {object} opts
 * @param {string} opts.iconSelector — CSS selector inside .gridLine
 *   (e.g. '.gridListH, .gridListV' for groups, '.gridBoxImg [tree="true"]' for tree nodes)
 * @param {string} opts.isExpandedExpr — JS expression evaluated in browser
 *   context where `icon` is the matched element; must yield a boolean
 *   (e.g. "icon.classList.contains('gridListV')" or "(icon.style.backgroundImage || '').includes('gx=0')")
 * @returns {Promise<{x:number, y:number, isExpanded:boolean}|null>}
 */
export async function getGridToggleIcon(target, formNum, { iconSelector, isExpandedExpr }) {
  return await page.evaluate(`(() => {
    const p = ${JSON.stringify(`form${formNum}_`)};
    const gridSel = ${JSON.stringify(target.gridId ? '#' + target.gridId : null)};
    const grid = gridSel ? document.querySelector(gridSel) : document.querySelector('[id^="' + p + '"].grid');
    const body = grid?.querySelector('.gridBody');
    if (!body) return null;
    const targetY = ${target.y};
    const lines = [...body.querySelectorAll('.gridLine')];
    for (const line of lines) {
      const lr = line.getBoundingClientRect();
      if (targetY < lr.top || targetY > lr.bottom) continue;
      const icon = line.querySelector(${JSON.stringify(iconSelector)});
      if (icon) {
        const r = icon.getBoundingClientRect();
        const isExpanded = ${isExpandedExpr};
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), isExpanded };
      }
    }
    return null;
  })()`);
}

/**
 * Standard expand/toggle decision: should we click the toggle icon?
 * - `toggle:true` → always click.
 * - `expand:true` → click only if not already expanded.
 * - `expand:false` → click only if currently expanded.
 * - If no icon found (`iconInfo` is null) → click anyway (caller falls back to dblclick).
 *
 * @param {{isExpanded:boolean}|null} iconInfo
 * @param {boolean|undefined} expand
 * @param {boolean|undefined} toggle
 * @returns {boolean}
 */
export function shouldClickToggle(iconInfo, expand, toggle) {
  return toggle || !iconInfo
    || (expand === true && !iconInfo.isExpanded)
    || (expand === false && iconInfo.isExpanded);
}
