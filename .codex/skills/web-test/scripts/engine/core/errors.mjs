// web-test core/errors v1.18 — Error/modal/platform-dialog handling: dismiss, detect, fetch stack from 1C UI.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page } from './state.mjs';
import { checkErrorsScript } from '../../dom.mjs';
import {
  getOpenReportCoordsScript, isErrorDetailLinkVisibleScript,
  readLargestVisibleTextareaScript, clickTopCloudOkButtonScript,
  clickReportCloseButtonScript,
} from '../../dom/errors-stack.mjs';
import { waitForStable } from './wait.mjs';

/**
 * Close startup modals and guide tabs.
 * Strategy: Escape → click default buttons → close extra tabs → repeat.
 */
export async function closeModals() {
  for (let attempt = 0; attempt < 5; attempt++) {
    // 1. Press Escape to dismiss any popup/modal
    await page.keyboard.press('Escape');
    await page.waitForTimeout(1000);

    // 2. Try clicking default "Закрыть"/"OK" buttons
    const clicked = await page.evaluate(`(() => {
      const btns = [...document.querySelectorAll('a.press.pressDefault')].filter(el => el.offsetWidth > 0);
      for (const btn of btns) {
        const text = (btn.innerText?.trim() || '').toLowerCase();
        if (['закрыть', 'ok', 'ок', 'нет', 'отмена'].includes(text)) {
          btn.click();
          return text;
        }
      }
      return null;
    })()`);
    if (clicked) { await page.waitForTimeout(1000); continue; }

    // 3. Close extra tabs (Путеводитель etc.) via openedClose button
    const tabClosed = await page.evaluate(`(() => {
      const btn = document.querySelector('.openedClose');
      if (btn && btn.offsetWidth > 0) { btn.click(); return true; }
      return false;
    })()`);
    if (tabClosed) { await page.waitForTimeout(1000); continue; }

    // Nothing to close — done
    break;
  }
}

/**
 * Check for validation errors / diagnostics after an action.
 * Detects: inline balloon tooltip, messages panel, modal error dialog.
 * Returns { balloon, messages[], modal } or null.
 */
export async function checkForErrors() {
  return await page.evaluate(checkErrorsScript());
}

/**
 * Dismiss pending error modal if present (single OK button dialog).
 * Called at the start of action functions so that a leftover error modal
 * from a previous operation doesn't block the next action.
 * Does NOT dismiss confirmations (Да/Нет — require user decision).
 * Returns the dismissed error object or null.
 */
export async function dismissPendingErrors() {
  // Close leftover platform dialogs first (About, Support Info, Error Report)
  // These block all interaction via modalSurface and are invisible to 1C form detection
  try {
    const pd = await detectPlatformDialogs();
    if (pd.length) await closePlatformDialogs();
  } catch { /* OK */ }
  const err = await checkForErrors();
  if (!err?.modal) return null;
  try {
    // Target pressDefault within the modal's form container specifically
    const formNum = err.modal.formNum;
    const sel = formNum != null
      ? `#form${formNum}_container a.press.pressDefault`
      : 'a.press.pressDefault';
    const btn = await page.$(sel);
    if (btn) { await btn.click({ force: true }); await page.waitForTimeout(500); }
  } catch { /* OK */ }
  await waitForStable();
  return err;
}

/**
 * Detect open platform-level dialogs (About, Support Info, Error Report).
 * Returns array of { type, title? } for each detected dialog, or empty array.
 */
export async function detectPlatformDialogs() {
  return await page.evaluate(() => {
    const result = [];
    // "О программе" dialog
    const about = document.getElementById('aboutContainer');
    if (about && about.offsetWidth > 0) result.push({ type: 'about', title: 'О программе' });
    // "Информация для технической поддержки" (inside a ps*win with errJournalInput)
    const errJ = document.getElementById('errJournalInput');
    if (errJ && errJ.offsetWidth > 0) result.push({ type: 'supportInfo', title: 'Информация для технической поддержки' });
    // "Отчет об ошибке" / "Подробный текст ошибки" — ps*win cloud windows without aboutContainer
    if (!result.length) {
      document.querySelectorAll('[id^="ps"][id$="win"]').forEach(w => {
        if (w.offsetWidth === 0 || w.offsetHeight === 0) return;
        // Skip the main app window (ps*win that contains the 1C forms)
        if (w.querySelector('[id^="form"][id$="_container"]')) return;
        // Check title text
        const titleEl = w.querySelector('[id$="headerTopLine_cmd_Title"]');
        const title = titleEl?.textContent?.trim() || '';
        if (title) result.push({ type: 'platformWindow', title });
      });
    }
    return result;
  });
}

/**
 * Close any platform-level dialogs that may be left open (about, support info, error report).
 * These are NOT 1C forms — they are platform UI overlays invisible to getFormState().
 * Each close is wrapped in try/catch to avoid cascading failures.
 */
export async function closePlatformDialogs() {
  await page.evaluate(() => {
    // "Подробный текст ошибки" OK button (inside error report detail view)
    // It's a cloud window with its own OK button — look for visible pressDefault in small ps*win
    const psWins = document.querySelectorAll('[id^="ps"][id$="win"]');
    for (const w of psWins) {
      if (w.offsetWidth === 0) continue;
      // Check if this is a small dialog (error detail, about, support info)
      const closeBtn = w.querySelector('[id$="_cmd_CloseButton"]');
      if (closeBtn && closeBtn.offsetWidth > 0) {
        try { closeBtn.click(); } catch {}
      }
    }
    // "Информация для технической поддержки" — extOkBtn
    const extOk = document.getElementById('extOkBtn');
    if (extOk && extOk.offsetWidth > 0) try { extOk.click(); } catch {}
    // "О программе" — aboutOkButton
    const aboutOk = document.getElementById('aboutOkButton');
    if (aboutOk && aboutOk.offsetWidth > 0) try { aboutOk.click(); } catch {}
  });
  await page.waitForTimeout(300);
}

/**
 * Parse raw error stack text into structured entries.
 * Input: raw text from errJournalInput (first block) or "Подробный текст ошибки" textarea.
 * Returns { raw, timestamp?, entries: [{location, code}] }
 */
function parseErrorStack(raw) {
  if (!raw) return null;
  const result = { raw, entries: [] };
  // Extract timestamp if present (format: DD.MM.YYYY HH:MM:SS)
  const tsMatch = raw.match(/^(\d{2}\.\d{2}\.\d{4}\s+\d{1,2}:\d{2}:\d{2})/m);
  if (tsMatch) result.timestamp = tsMatch[1];
  // Extract {Module.Path(lineNum)}: code entries
  const entryRe = /\{([^}]+)\}:\s*(.+)/g;
  let m;
  while ((m = entryRe.exec(raw)) !== null) {
    result.entries.push({ location: m[1].trim(), code: m[2].trim() });
  }
  return result.entries.length > 0 ? result : null;
}

/**
 * Fetch error call stack from the 1C platform UI.
 * Uses two strategies:
 *   Path 1 (hasReport=true): Click OpenReport link → "подробный текст ошибки" → read textarea
 *   Path 2 (fallback): Hamburger → "О программе" → "Информация для техподдержки" → errJournalInput
 *
 * Always closes the error modal and any platform dialogs it opened.
 * Returns parsed stack object or null on failure.
 *
 * @param {number} formNum - form number of the error modal (e.g. 6 for form6_)
 * @param {boolean} hasReport - true if OpenReport link is available
 */
export async function fetchErrorStack(formNum, hasReport) {
  try {
    // Platform exception modals are initially unstable — they redraw within ~1s.
    // The initial state may lack the OpenReport link. Re-check after a short delay.
    if (!hasReport) {
      await page.waitForTimeout(1500);
      hasReport = await page.evaluate((fn) => {
        const el = document.getElementById('form' + fn + '_OpenReport#text');
        return !!(el && el.offsetWidth > 2 && el.textContent.trim());
      }, formNum);
    }
    if (hasReport) return await fetchStackViaReport(formNum);
    return await fetchStackViaHamburger(formNum);
  } catch {
    return null;
  } finally {
    // Ensure all platform dialogs are closed
    try { await closePlatformDialogs(); } catch {}
    // Ensure the error modal itself is closed
    try {
      const sel = formNum != null
        ? `#form${formNum}_container a.press.pressDefault`
        : 'a.press.pressDefault';
      const btn = await page.$(sel);
      if (btn) await btn.click({ force: true });
      await page.waitForTimeout(300);
    } catch {}
  }
}

/**
 * Path 1: Fetch stack via OpenReport link (for platform exceptions).
 * The error modal must still be open with a visible "Сформировать отчет об ошибке" link.
 */
async function fetchStackViaReport(formNum) {
  // 1. Get coordinates of the OpenReport link and click via mouse (modalSurface blocks JS clicks)
  const coords = await page.evaluate(getOpenReportCoordsScript(formNum));
  if (!coords) return null;

  await page.mouse.click(coords.x, coords.y);

  // 2. Wait for "Отчет об ошибке" dialog — look for "подробный текст ошибки" link
  let found = false;
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(500);
    found = await page.evaluate(isErrorDetailLinkVisibleScript());
    if (found) break;
  }
  if (!found) return null;

  // 3. Click "подробный текст ошибки"
  await page.getByText('подробный текст ошибки').click();
  await page.waitForTimeout(2000);

  // 4. Read the textarea with detailed error text (find the largest visible textarea)
  const raw = await page.evaluate(readLargestVisibleTextareaScript());

  // 5. Close "Подробный текст ошибки" dialog (click its OK button)
  try {
    await page.evaluate(clickTopCloudOkButtonScript());
    await page.waitForTimeout(300);
  } catch {}

  // 6. Close "Отчет об ошибке" dialog (click its × close button)
  try {
    await page.evaluate(clickReportCloseButtonScript());
    await page.waitForTimeout(300);
  } catch {}

  return parseErrorStack(raw);
}

/**
 * Path 2: Fetch stack via hamburger menu → "О программе" → "Информация для техподдержки".
 * Works for all error types including simple ВызватьИсключение.
 * The error modal is closed first to allow access to the hamburger menu.
 */
async function fetchStackViaHamburger(formNum) {
  // 1. Close the error modal first
  try {
    const sel = formNum != null
      ? `#form${formNum}_container a.press.pressDefault`
      : 'a.press.pressDefault';
    const btn = await page.$(sel);
    if (btn) await btn.click({ force: true });
    await page.waitForTimeout(500);
  } catch {}

  // 2. Click hamburger menu
  await page.click('#captionbarMore', { timeout: 5000 });
  await page.waitForTimeout(1000);

  // 3. Click "О программе..."
  await page.getByText('О программе...', { exact: true }).click({ timeout: 5000 });
  await page.waitForTimeout(2000);

  // 4. Click "Информация для технической поддержки"
  await page.click('#aboutHyperLink', { timeout: 5000 });

  // 5. Wait for errJournalInput to appear and be filled
  let raw = null;
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(500);
    raw = await page.evaluate(() => {
      const el = document.getElementById('errJournalInput');
      return (el && el.offsetWidth > 0 && el.value.length > 50) ? el.value : null;
    });
    if (raw) break;
  }
  if (!raw) return null;

  // 6. Parse first error block (most recent — before first separator)
  const separator = / - - - - /;
  const errSection = raw.indexOf('\n\n') !== -1 ? raw.substring(raw.indexOf('\n\n')) : raw;
  // Find the "Ошибки:" section
  const errIdx = raw.indexOf('Ошибки:');
  let errorText = errIdx !== -1 ? raw.substring(errIdx + 'Ошибки:'.length).trim() : raw;
  // Take first block (before first separator line)
  const lines = errorText.split('\n');
  const firstBlockLines = [];
  let inBlock = false;
  for (const line of lines) {
    if (separator.test(line)) {
      if (inBlock) break; // end of first block
      inBlock = true;
      continue;
    }
    if (inBlock) firstBlockLines.push(line);
  }
  const firstBlock = firstBlockLines.join('\n').trim();

  // 7. Close support info and about dialogs (done in finally via closePlatformDialogs)
  return parseErrorStack(firstBlock || errorText);
}
