// web-test table/click-row v1.0 — click handlers for grid row targets: gridGroup, gridTreeNode, gridRow.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// All handlers are called by core/click.mjs dispatcher after target is found.
// Each takes (target, ctx) where ctx = { formNum, modifier, dblclick, toggle, expand, ... }
// and returns a form state with `clicked: { kind, name, ... }`.

import { waitForStable } from '../core/wait.mjs';
import { modifierClick, returnFormState } from '../core/helpers.mjs';
import { getGridToggleIcon, shouldClickToggle } from './grid-toggle.mjs';

/**
 * Click handler for gridGroup / gridParent targets (hierarchy mode).
 * With `expand`/`toggle` — click the level-indicator icon to expand/collapse the group.
 * Without — dblclick the row to enter the group / go up to parent.
 */
export async function clickGridGroupTarget(target, ctx) {
  const { formNum, modifier, toggle, expand } = ctx;
  if (expand != null || toggle) {
    // Expand/collapse group — click the triangle icon (.gridListH/.gridListV).
    // expand=true: only expand (skip if already expanded), expand=false: only collapse, toggle: always click.
    const levelIconInfo = await getGridToggleIcon(target, formNum, {
      iconSelector: '.gridListH, .gridListV',
      isExpandedExpr: "icon.classList.contains('gridListV')",
    });
    const shouldClick = shouldClickToggle(levelIconInfo, expand, toggle);
    if (shouldClick) {
      if (levelIconInfo) {
        await modifierClick(levelIconInfo.x, levelIconInfo.y, modifier);
      } else {
        // Fallback: dblclick (standard hierarchy navigation)
        await modifierClick(target.x, target.y, modifier, { dbl: true });
      }
    }
    await waitForStable(formNum);
    return returnFormState({
      clicked: { kind: target.kind, name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) },
      hint: shouldClick ? 'Group toggled. Use readTable to see updated list.' : 'Group already in desired state.',
    });
  }
  // Default: dblclick to enter group / go up to parent
  await modifierClick(target.x, target.y, modifier, { dbl: true });
  await waitForStable(formNum);
  return returnFormState({ clicked: { kind: target.kind, name: target.name, ...(modifier ? { modifier } : {}) } });
}

/**
 * Click handler for gridTreeNode targets (tree-style grid).
 * With `expand`/`toggle` — click the tree icon to expand/collapse.
 * Without — single-click to select the row (no expand).
 */
export async function clickGridTreeNodeTarget(target, ctx) {
  const { formNum, modifier, toggle, expand } = ctx;
  if (expand != null || toggle) {
    // Expand/collapse tree node — click the tree icon [tree="true"].
    const treeIconInfo = await getGridToggleIcon(target, formNum, {
      iconSelector: '.gridBoxImg [tree="true"]',
      isExpandedExpr: '(icon.style.backgroundImage || "").includes("gx=0")',
    });
    const shouldClick = shouldClickToggle(treeIconInfo, expand, toggle);
    if (shouldClick) {
      if (treeIconInfo) {
        await modifierClick(treeIconInfo.x, treeIconInfo.y, modifier);
      } else {
        // Fallback: dblclick on row (works for trees without clickable +/- icons)
        await modifierClick(target.x, target.y, modifier, { dbl: true });
      }
    }
    await waitForStable(formNum);
    return returnFormState({
      clicked: { kind: 'gridTreeNode', name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) },
      hint: shouldClick ? 'Tree node toggled. Use readTable to see updated tree.' : 'Tree node already in desired state.',
    });
  }
  // Default: select row (click text, no expand/collapse)
  await modifierClick(target.x, target.y, modifier);
  await waitForStable(formNum);
  return returnFormState({
    clicked: { kind: 'gridTreeNode', name: target.name, ...(modifier ? { modifier } : {}) },
    hint: 'Row selected. Use { expand: true } to expand/collapse.',
  });
}

/**
 * Click handler for gridRow targets (flat list row).
 * Single click selects the row; `dblclick: true` opens the item.
 */
export async function clickGridRowTarget(target, ctx) {
  const { modifier, dblclick } = ctx;
  await modifierClick(target.x, target.y, modifier, { dbl: !!dblclick });
  await waitForStable();
  return returnFormState({
    clicked: { kind: 'gridRow', name: target.name, ...(dblclick ? { dblclick: true } : {}), ...(modifier ? { modifier } : {}) },
  });
}
