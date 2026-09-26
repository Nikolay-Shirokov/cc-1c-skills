// web-test forms/click-form v1.1 — click handler for form-element targets: button, tab, submenu, link, field-focus.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Called by core/click.mjs dispatcher after target is found.
// Owns the CDP network-monitor lifecycle for button clicks (server roundtrip waits),
// post-click submenu detection (split buttons like "Создать на основании"),
// and confirmation hint propagation in the final state.

import { page, ACTION_WAIT } from '../core/state.mjs';
import {
  detectFormScript, readSubmenuScript,
} from '../../dom.mjs';
import { checkForErrors } from '../core/errors.mjs';
import { waitForStable, startNetworkMonitor } from '../core/wait.mjs';
import { safeClick, returnFormState, isInputFocused } from '../core/helpers.mjs';

/**
 * Click a form target (button, tab, submenu, link) using its resolved {kind, id, x, y, name}.
 * Handles three special concerns:
 *   1. **netMonitor** for `kind: 'button'` — captures CDP requests started by the click
 *      so we can wait for them (when the form doesn't change) before stabilising.
 *   2. **Submenu detection** — both pre-click (`kind: 'submenu'` already known) and
 *      post-click (split buttons like "Создать на основании" which open a popup).
 *      Returns `submenu[]` items as a hint for the caller.
 *   3. **Confirmation propagation** — if a confirmation dialog opens as a result of the
 *      click, surface `confirmation` and `hint` fields on the returned state so the
 *      caller can react with Да/Нет/Отмена on the next call.
 */
export async function clickFormTarget(target, ctx) {
  const { formNum, timeout } = ctx;
  let netMonitor = null;

  try {
    // CDP network monitor BEFORE the click for buttons — captures all server requests
    // triggered by the click so we can wait for them after.
    if (target.kind === 'button') {
      try { netMonitor = await startNetworkMonitor(); } catch {}
    }

    // Tabs without ID — use coordinate click to avoid global [data-content] ambiguity
    if (target.kind === 'tab' && !target.id && target.x && target.y) {
      await page.mouse.click(target.x, target.y);
    } else {
      const selector = `[id="${target.id}"]`;
      // Use Playwright click for proper mousedown/mouseup events
      await safeClick(selector, { timeout: 5000 });
    }

    // Pre-known submenu button — read popup items and return them as hints
    if (target.kind === 'submenu') {
      await page.waitForTimeout(ACTION_WAIT);
      const submenuItems = await page.evaluate(readSubmenuScript());
      const extras = { clicked: { kind: 'submenu', name: target.name } };
      if (Array.isArray(submenuItems)) {
        extras.submenu = submenuItems.map(i => i.name);
        extras.hint = 'Call web_click again with a submenu item name to select it';
      }
      return returnFormState(extras);
    }

    await waitForStable(formNum);

    // Check if the click opened a popup/submenu (split buttons like "Создать на основании")
    const openedPopup = await page.evaluate(readSubmenuScript());
    if (Array.isArray(openedPopup) && openedPopup.length > 0) {
      return returnFormState({
        clicked: { kind: 'submenu', name: target.name },
        submenu: openedPopup.map(i => i.name),
        hint: 'Call web_click again with a submenu item name to select it',
      });
    }

    // For buttons that trigger server-side operations (post, write, etc.),
    // the DOM may stabilise BEFORE the server response arrives.
    // The CDP monitor (started before click) lets us wait for all in-flight requests
    // to complete (300ms debounce) or for a modal/balloon/confirm to appear.
    // Skip for grid edit mode (e.g. "Добавить" row) — no server round-trip expected.
    if (target.kind === 'button') {
      const postForm = await page.evaluate(detectFormScript());
      if (postForm === formNum) {
        const inGridEdit = await page.evaluate(`(() => {
          const f = document.activeElement;
          if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
          let n = f; while (n) { if (n.classList?.contains('grid')) return true; n = n.parentElement; }
          return false;
        })()`);
        if (!inGridEdit && netMonitor) {
          await netMonitor.waitDone(timeout);
          await waitForStable();
        }
      }
    }

    // Build final state with confirmation propagation
    // (the one custom branch deliberately skipped by Phase 2 — surfaces confirmation
    //  + hint when a save/delete dialog opened as a result of the click).
    const extras = { clicked: { kind: target.kind, name: target.name } };
    const err = await checkForErrors();
    if (err?.confirmation) {
      extras.confirmation = err.confirmation;
      extras.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
    return returnFormState(extras);
  } finally {
    if (netMonitor) try { await netMonitor.cleanup(); } catch {}
  }
}

/**
 * Focus a form input field (last-resort target kind: 'field') by clicking the input itself —
 * does NOT change its value. Lets the caller then drive focus-dependent shortcuts
 * (F4 selection form, Shift+F4 clear, etc.) via getPage().keyboard.
 * Returns flat form state with `focused: { field, id, ok }`; `ok` reflects whether the
 * input actually received focus (false for disabled/readonly fields). Never throws on ok=false.
 */
export async function focusFormField(target, ctx) {
  const selector = `[id="${target.id}"]`;
  await safeClick(selector, { timeout: 5000 });
  await waitForStable(ctx.formNum);
  const ok = await isInputFocused({ allowTextarea: true });
  return returnFormState({ focused: { field: target.name, id: target.id, ok } });
}
