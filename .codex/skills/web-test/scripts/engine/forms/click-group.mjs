// web-test forms/click-group v1.2 — click handler for collapsible/popup form-group titles.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Reuses the tree/grid expand vocabulary so the model has ONE mental model:
//   clickElement('<group title>', { expand: true })  — reveal (idempotent)
//   clickElement('<group title>', { expand: false }) — hide (idempotent)
//   clickElement('<group title>', { toggle: true })  — flip
//   clickElement('<group title>')                    — flip (bare click)
//
// target.collapsed comes from findClickTargetScript (groupCollapsed in dom/_shared.mjs).

import { page } from '../core/state.mjs';
import { scrollGroupIntoViewScript } from '../../dom.mjs';
import { waitForStable } from '../core/wait.mjs';
import { modifierClick, returnFormState } from '../core/helpers.mjs';
import { shouldClickToggle } from '../table/grid-toggle.mjs';

// Group captions repeat across a form's blocks («Показать детализацию» in every block), and a
// collapsible group swaps its own caption when expanded (CollapsedRepresentationTitle:
// «Показать детализацию» ↔ «Скрыть детализацию»). Compare normalised so a real caption swap
// is not confused with nbsp/ё spelling differences.
const norm = (s) => (s || '').replace(/ /g, ' ').replace(/ё/gi, 'е').trim().toLowerCase();

export async function clickFormGroupTarget(target, ctx) {
  const { formNum, modifier, toggle, expand } = ctx;
  // shouldClickToggle expects { isExpanded }; with an unknown state (undefined) always click.
  const state = target.collapsed == null ? null : { isExpanded: !target.collapsed };
  const shouldClick = shouldClickToggle(state, expand, toggle);
  if (shouldClick) {
    // The target is clicked by coordinates, and on a long form those go stale or fall outside
    // the viewport — the click then silently does nothing. Scroll the title into view and take
    // a fresh point.
    const pt = await page.evaluate(scrollGroupIntoViewScript(formNum, target.label));
    await modifierClick(pt?.x ?? target.x, pt?.y ?? target.y, modifier);
  }
  await waitForStable(formNum);
  const result = await returnFormState({
    clicked: { kind: 'formGroup', name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) },
    hint: shouldClick
      ? 'Group toggled. Call getFormState — its groups[].collapsed and revealed/hidden content update.'
      : 'Group already in desired state.',
  });

  // The technical name is the stable key: it finds the entry in groups[] and clicks the same
  // group again. The caption cannot do that — it changes when the group expands.
  const after = (result.groups || []).find(g => g.name === target.label);
  if (target.label) result.clicked.group = target.label;
  if (after) {
    result.clicked.title = after.title;
    if (norm(after.title) !== norm(target.name)) {
      result.hint += ` The group is now titled "${after.title}"`
        + ` — click it by that caption or by its technical name "${target.label}".`;
    }
  }

  // Postcondition: a click that toggled nothing is a silent lie (same rule as the disabled
  // guard in core/click.mjs). Checked ONLY when a click actually happened and the state is
  // readable: with collapsed == null (unrecognised layout) there is nothing to compare against.
  if (shouldClick && target.collapsed != null) {
    if (after && after.collapsed === target.collapsed) {
      throw new Error(`clickElement: group "${target.name}" did not toggle `
        + `(collapsed stayed ${after.collapsed})`);
    }
  }
  return result;
}
