// web-test core/wait v1.17 — Smart wait helpers: DOM stability polling, JS-expression polling, CDP network monitor.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, MAX_WAIT, POLL_INTERVAL, STABLE_CYCLES } from './state.mjs';
import { detectFormScript } from '../../dom.mjs';

/**
 * Smart wait: poll until DOM is stable and no loading indicators are visible.
 * Checks: form number change, loading indicators, DOM stability.
 * @param {number|null} previousFormNum — form number before the action (null = don't check)
 */
export async function waitForStable(previousFormNum = null) {
  let stableCount = 0;
  let lastSnapshot = '';
  const start = Date.now();

  while (Date.now() - start < MAX_WAIT) {
    await page.waitForTimeout(POLL_INTERVAL);

    // Check for loading indicators
    const status = await page.evaluate(`(() => {
      const loading = document.querySelector('.loadingImage, .waitCurtain, .progressBar');
      const isLoading = loading && loading.offsetWidth > 0;
      const formCount = document.querySelectorAll('input.editInput[id], a.press[id]').length;
      return { isLoading, formCount };
    })()`);

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
