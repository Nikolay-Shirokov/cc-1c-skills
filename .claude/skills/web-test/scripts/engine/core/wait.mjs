// web-test core/wait v1.18 — Smart wait helpers: DOM stability polling, JS-expression polling, CDP network monitor.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, MAX_WAIT, BUSY_MAX_WAIT, POLL_INTERVAL, STABLE_CYCLES } from './state.mjs';
import { detectFormScript } from '../../dom.mjs';

/**
 * Smart wait: poll until DOM is stable and no loading indicators are visible.
 * Checks: form number change, loading indicators, busy state window, DOM stability.
 * @param {number|null} previousFormNum — form number before the action (null = don't check)
 */
export async function waitForStable(previousFormNum = null) {
  let stableCount = 0;
  let lastSnapshot = '';
  const start = Date.now();
  let deadline = start + MAX_WAIT;

  while (Date.now() < deadline) {
    await page.waitForTimeout(POLL_INTERVAL);

    // Check for loading indicators
    const status = await page.evaluate(`(() => {
      const loading = document.querySelector('.loadingImage, .waitCurtain, .progressBar');
      const isLoading = loading && loading.offsetWidth > 0;
      // While a dynamic list is still searching, 1C floats a state window over the grid
      // ("Поиск…") — and NOTHING else in the DOM says so: the old rows stay put, the element
      // counters below don't move, so the page looks perfectly stable with stale data.
      // Match busy markers by text, never "state window present": the same carrier also holds
      // TERMINAL report messages ("Отчет не сформирован", "Не установлено значение параметра"),
      // and waiting for those to disappear would hang until the timeout on every report.
      const busy = [...document.querySelectorAll('.stateWindowSupportSurface')].some(el =>
        el.offsetWidth > 0 && /^\\s*(Поиск|Ожид|Searching|Please wait)/i.test(el.innerText || ''));
      const formCount = document.querySelectorAll('input.editInput[id], a.press[id]').length;
      return { isLoading, busy, formCount };
    })()`);

    // A visible busy indicator outranks DOM stability — it is the only evidence we get that the
    // server is still working. Push the deadline while it lasts (bounded by BUSY_MAX_WAIT) instead
    // of reporting "stable": returning mid-search is what handed a caller the previous rows and
    // let the next click open the wrong document.
    if (status.busy) {
      deadline = Math.min(Date.now() + MAX_WAIT, start + BUSY_MAX_WAIT);
      stableCount = 0;
      continue;
    }

    if (status.isLoading) {
      stableCount = 0;
      continue;
    }

    // Check DOM stability by comparing element count snapshot
    const snapshot = String(status.formCount);
    if (snapshot === lastSnapshot) {
      stableCount++;
    } else {
      stableCount = 0;
      lastSnapshot = snapshot;
    }

    // If form was expected to change, ensure it did
    if (previousFormNum !== null && stableCount === 1) {
      const currentForm = await page.evaluate(detectFormScript());
      if (currentForm !== previousFormNum) {
        // Form changed — still wait for stability
      }
    }

    if (stableCount >= STABLE_CYCLES) return;
  }
  // Fallback: max wait reached
}

/**
 * Start monitoring network activity via CDP.
 * Must be called BEFORE the click so it captures all server requests.
 * Returns a monitor object with waitDone() and cleanup() methods.
 */
export async function startNetworkMonitor() {
  const client = await page.context().newCDPSession(page);
  await client.send('Network.enable');

  let pending = 0;
  let total = 0;
  let lastZeroTime = null;
  const DEBOUNCE = 300;

  client.on('Network.requestWillBeSent', () => {
    pending++;
    total++;
    lastZeroTime = null;
  });
  client.on('Network.loadingFinished', () => {
    if (--pending === 0) lastZeroTime = Date.now();
  });
  client.on('Network.loadingFailed', () => {
    if (--pending === 0) lastZeroTime = Date.now();
  });

  return {
    /** Wait until all network requests complete (300ms debounce) or UI element appears. */
    async waitDone(timeout = 10000) {
      const start = Date.now();
      while (Date.now() - start < timeout) {
        await page.waitForTimeout(50);

        // Check for UI elements (modal, balloon, confirm)
        const ui = await page.evaluate(`(() => {
          const modal = document.querySelector('#modalSurface:not([style*="display: none"])');
          const balloon = document.querySelector('.balloon');
          const confirm = document.querySelector('.confirm');
          return !!(modal || balloon || confirm);
        })()`);
        if (ui) return;

        // CDP debounce: pending===0 held for DEBOUNCE ms
        if (total > 0 && pending === 0 && lastZeroTime !== null) {
          if (Date.now() - lastZeroTime >= DEBOUNCE) return;
        }
      }
    },
    /** Detach CDP session. Always call this when done. */
    async cleanup() {
      await client.send('Network.disable').catch(() => {});
      await client.detach().catch(() => {});
    }
  };
}

/**
 * Poll until a JS expression returns truthy, or timeout (ms) expires.
 * Resolves early — typically within 100-300ms instead of fixed delays.
 */
export async function waitForCondition(evalScript, timeout = 2000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    const result = await page.evaluate(evalScript);
    if (result) return result;
    await page.waitForTimeout(100);
  }
  return null;
}
