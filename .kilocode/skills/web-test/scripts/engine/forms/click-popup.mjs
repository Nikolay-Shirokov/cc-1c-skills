// web-test forms/click-popup v1.0 — click handlers for in-form popups: confirmation dialogs and open submenus.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Both handlers run BEFORE clickElement's regular target-finding flow:
//   - clickConfirmationButton intercepts when a pending confirmation dialog is open
//   - tryClickPopupItem intercepts when a submenu/popup is open from a previous click

import { page, ACTION_WAIT, normYo } from '../core/state.mjs';
import { readSubmenuScript } from '../../dom.mjs';
import { waitForStable } from '../core/wait.mjs';
import { returnFormState } from '../core/helpers.mjs';

/**
 * Click a button in the currently-open confirmation dialog (Да/Нет/Отмена, etc).
 * Caller is responsible for verifying that a confirmation is actually pending
 * (via checkForErrors().confirmation) before invoking this handler.
 *
 * Throws if no button matching `text` is found in the dialog.
 */
export async function clickConfirmationButton(text) {
  const btnResult = await page.evaluate(`(() => {
    const norm = s => s?.trim().replace(/\\u00a0/g, ' ') || '';
    const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
    const target = ny(${JSON.stringify(text.toLowerCase())});
    const btns = [...document.querySelectorAll('a.press.pressButton')].filter(el => el.offsetWidth > 0);
    let best = btns.find(el => ny(norm(el.innerText).toLowerCase()) === target);
    if (!best) best = btns.find(el => ny(norm(el.innerText).toLowerCase()).includes(target));
    if (best) {
      const r = best.getBoundingClientRect();
      return { name: norm(best.innerText), x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) };
    }
    return { error: 'not_found', available: btns.map(el => norm(el.innerText)).filter(Boolean) };
  })()`);
  if (btnResult?.error) {
    throw new Error(`clickElement: "${text}" not found among confirmation buttons. Available: ${btnResult.available?.join(', ') || 'none'}`);
  }
  await page.mouse.click(btnResult.x, btnResult.y);
  await waitForStable();
  return returnFormState({ clicked: { kind: 'confirmation', name: btnResult.name } });
}

/**
 * Try to click an item inside an already-open submenu/popup.
 *
 * Returns a form-state result on match (kind: 'popupItem' or 'submenuArrow'),
 * or `null` if the requested text doesn't match any visible popup item — in
 * which case the caller should fall through to regular form-element finding.
 *
 * @param {string} text — fuzzy-matched against item labels (NBSP/ё-normalised)
 * @param {Array} popupItems — items already read via readSubmenuScript()
 */
export async function tryClickPopupItem(text, popupItems) {
  const target = normYo(text.toLowerCase());
  let found = popupItems.find(i => normYo(i.name.toLowerCase()) === target);
  if (!found) found = popupItems.find(i => normYo(i.name.toLowerCase()).includes(target));
  if (!found) return null;

  // submenuArrow items (group headers like "Создать", "Печать") — hover to expand nested submenu
  if (found.kind === 'submenuArrow') {
    // page.hover(selector) is more reliable than page.mouse.move(x,y) —
    // some submenu groups don't expand with plain mouse.move
    if (found.id) {
      await page.hover(`[id="${found.id}"]`);
    } else {
      await page.mouse.move(found.x, found.y);
    }
    await page.waitForTimeout(ACTION_WAIT);
    const nestedItems = await page.evaluate(readSubmenuScript());
    const extras = { clicked: { kind: 'submenuArrow', name: found.name } };
    if (Array.isArray(nestedItems)) {
      extras.submenu = nestedItems.map(i => i.name);
      extras.hint = 'Call web_click again with a submenu item name to select it';
    }
    return returnFormState(extras);
  }

  // Regular submenu/dropdown items — trusted events required.
  // Use mouse.click(x,y) when in viewport; use :visible selector for clipped items
  // (same ID can exist hidden in parent cloud AND visible in nested cloud).
  const vpHeight = await page.evaluate('window.innerHeight');
  if (found.x && found.y && found.y > 0 && found.y < vpHeight) {
    await page.mouse.click(found.x, found.y);
  } else if (found.id) {
    await page.click(`[id="${found.id}"]:visible`);
  } else if (found.x && found.y) {
    await page.mouse.click(found.x, found.y);
  }
  await waitForStable();
  return returnFormState({ clicked: { kind: 'popupItem', name: found.name } });
}
