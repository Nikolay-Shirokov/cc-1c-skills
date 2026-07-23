// web-test forms/click-group v1.0 — click handler for collapsible/popup form-group titles.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Reuses the tree/grid expand vocabulary so the model has ONE mental model:
//   clickElement('<заголовок группы>', { expand: true })  — раскрыть (идемпотентно)
//   clickElement('<заголовок группы>', { expand: false }) — свернуть (идемпотентно)
//   clickElement('<заголовок группы>', { toggle: true })  — переключить
//   clickElement('<заголовок группы>')                    — переключить (голый клик)
//
// target.collapsed приходит из findClickTargetScript (по display первого контент-сиблинга).

import { waitForStable } from '../core/wait.mjs';
import { modifierClick, returnFormState } from '../core/helpers.mjs';
import { shouldClickToggle } from '../table/grid-toggle.mjs';

export async function clickFormGroupTarget(target, ctx) {
  const { formNum, modifier, toggle, expand } = ctx;
  // shouldClickToggle ждёт { isExpanded }; при неизвестном состоянии (undefined) кликаем всегда.
  const state = target.collapsed == null ? null : { isExpanded: !target.collapsed };
  const shouldClick = shouldClickToggle(state, expand, toggle);
  if (shouldClick) await modifierClick(target.x, target.y, modifier);
  await waitForStable(formNum);
  return returnFormState({
    clicked: { kind: 'formGroup', name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) },
    hint: shouldClick
      ? 'Group toggled. Call getFormState — its groups[].collapsed and revealed/hidden content update.'
      : 'Group already in desired state.',
  });
}
