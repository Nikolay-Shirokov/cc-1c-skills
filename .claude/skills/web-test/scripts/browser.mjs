// web-test browser v1.16 — Playwright browser management for 1C web client
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Playwright browser management for 1C web client.
 *
 * Maintains a single browser instance across MCP tool calls.
 * Handles connection, navigation, waiting, screenshots.
 */
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'child_process';
import { statSync, mkdirSync, existsSync as fsExistsSync, writeFileSync, readFileSync, rmSync, readdirSync } from 'fs';
import { dirname, resolve as pathResolve, join as pathJoin, basename, extname } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';
import {
  readSectionsScript, readTabsScript, readCommandsScript,
  readFormScript, navigateSectionScript, openCommandScript,
  findClickTargetScript, findFieldButtonScript, readSubmenuScript,
  resolveFieldsScript, getFormStateScript,
  detectFormScript, readTableScript, checkErrorsScript,
  switchTabScript, resolveGridScript
} from './dom.mjs';

// Module-level state, constants, normYo and resolveProjectPath live in core/state.mjs.
// Imported as live bindings — reads stay current; writes go through setters.
import {
  browser, page, sessionPrefix, seanceId, recorder,
  lastCaptions, lastRecordingDuration, highlightMode,
  persistentUserDataDir, preserveClipboard,
  contexts, activeContextName, activeMode,
  setBrowser, setPage, setSessionPrefix, setSeanceId, setRecorder,
  setLastCaptions, setLastRecordingDuration, setHighlightMode,
  setPersistentUserDataDir, setActiveContextName, setActiveMode,
  setClipboardWarnLogged,
  LOAD_TIMEOUT, INIT_TIMEOUT, ACTION_WAIT, MAX_WAIT, POLL_INTERVAL, STABLE_CYCLES,
  EXT_ID, projectRoot, resolveProjectPath, normYo,
  isConnected, ensureConnected, getPage, setPreserveClipboard,
} from './core/state.mjs';

export { isConnected, getPage, setPreserveClipboard, ensureConnected };
export async function saveClipboard() {
  if (!page) return;
  try {
    await page.evaluate(async () => {
      try {
        const items = await navigator.clipboard.read();
        const saved = [];
        for (const item of items) {
          const types = {};
          for (const t of item.types) types[t] = await item.getType(t);
          saved.push(types);
        }
        window.__webTestSavedClipboard = saved;
        delete window.__webTestClipboardError;
      } catch (e) {
        window.__webTestSavedClipboard = null;
        window.__webTestClipboardError = e?.name || String(e);
      }
    });
  } catch {
    // page.evaluate itself failed (closed page, navigation in flight) — skip.
  }
}
export async function restoreClipboard() {
  if (!page) return;
  let err = null;
  try {
    err = await page.evaluate(async () => {
      const saved = window.__webTestSavedClipboard;
      const captured = window.__webTestClipboardError || null;
      delete window.__webTestSavedClipboard;
      delete window.__webTestClipboardError;
      try {
        if (!saved || saved.length === 0) {
          // Save failed (e.g. CF_HDROP from Explorer not readable via Clipboard API)
          // or buffer was empty. Either way, the test's writeText already destroyed
          // any prior native formats in the OS clipboard, so explicitly clear here
          // to avoid leaking the test value into the user's clipboard.
          await navigator.clipboard.writeText('');
          return captured;
        }
        const items = saved.map(types => new ClipboardItem(types));
        await navigator.clipboard.write(items);
        return null;
      } catch (e) {
        return e?.name || String(e);
      }
    });
  } catch {
    return;
  }
  if (err && !clipboardWarnLogged) {
    setClipboardWarnLogged(true);
    console.error(`[web-test] clipboard preserve skipped: ${err} (logged once per session)`);
  }
}

/**
 * Paste `text` via OS clipboard (the only trusted-paste path that 1C respects
 * for autocomplete and Cyrillic). Wraps the writeText+confirm-key pair in a
 * narrow save/restore so a user's clipboard survives the test run — the window
 * between save and restore is microseconds.
 *
 * - `confirm` — key (string) or sequence (array) to press after writeText.
 *   Defaults to 'Control+V'. Use ['Control+a', 'Control+v'] for select-all-then-paste,
 *   or 'Shift+F11' for the goto-link dialog.
 * - `postDelay` — ms to wait between confirm-press and restore, for dialogs
 *   that read clipboard asynchronously (e.g. Shift+F11). Default 0.
 */
export async function pasteText(text, { confirm = 'Control+V', postDelay = 0 } = {}) {
  if (!page) return;
  if (preserveClipboard) await saveClipboard();
  try {
    await page.evaluate(`navigator.clipboard.writeText(${JSON.stringify(String(text))})`);
    if (Array.isArray(confirm)) {
      for (const key of confirm) await page.keyboard.press(key);
    } else if (confirm) {
      await page.keyboard.press(confirm);
    }
    if (postDelay) await page.waitForTimeout(postDelay);
  } finally {
    if (preserveClipboard) await restoreClipboard();
  }
}

// ============================================================
// Session lifecycle + multi-context — extracted to core/session.mjs
// ============================================================
export {
  connect, disconnect, attach, detach, getSession,
  createContext, setActiveContext, listContexts, getActiveContext,
  hasContext, closeContext,
} from './core/session.mjs';

// ============================================================
// Wait + error/modal handling — extracted to core/{wait,errors}.mjs
// ============================================================
import {
  waitForStable, waitForCondition, startNetworkMonitor,
} from './core/wait.mjs';
import {
  closeModals, checkForErrors, dismissPendingErrors, fetchErrorStack,
  _detectPlatformDialogs, _closePlatformDialogs,
} from './core/errors.mjs';
import {
  safeClick, findFieldInputId, readEdd, returnFormState,
  detectNewForm as helperDetectNewForm,
} from './core/helpers.mjs';
import { getGridToggleIcon, shouldClickToggle } from './table/grid-toggle.mjs';
// Re-export only what was publicly exported before the refactor.
// waitForStable/waitForCondition/startNetworkMonitor/closeModals/checkForErrors/
// dismissPendingErrors are internal helpers — imported above for local use only.
export { fetchErrorStack } from './core/errors.mjs';

/* getPage moved to core/state.mjs */

/**
 * Get current page state: active section, tabs.
 * Combined into a single evaluate call.
 */
export async function getPageState() {
  ensureConnected();
  const { sections, tabs } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    tabs: ${readTabsScript()}
  })`);
  const activeSection = sections.find(s => s.active)?.name || null;
  const activeTab = tabs.find(t => t.active)?.name || null;
  return { activeSection, activeTab, sections, tabs };
}

/** Read section panel + commands in a single evaluate call. */
export async function getSections() {
  ensureConnected();
  const { sections, commands } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    commands: ${readCommandsScript()}
  })`);
  const activeSection = sections.find(s => s.active)?.name || null;
  return { activeSection, sections, commands };
}

/** Navigate to a section by name. Returns new state with commands. */
export async function navigateSection(name) {
  ensureConnected();
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(name); await page.waitForTimeout(500); await unhighlight(); } catch {}
  const result = await page.evaluate(navigateSectionScript(name));
  if (result?.error) {
    const avail = result.available?.filter(Boolean);
    if (avail?.length === 0) throw new Error(`navigateSection: "${name}" not found. Section panel is in icon-only mode — text labels are hidden. Switch to "Text" or "Picture and text" display mode in 1C settings (View → Section Panel → Display Mode)`);
    throw new Error(`navigateSection: "${name}" not found. Available: ${avail?.join(', ') || 'none'}`);
  }

  await waitForStable();
  const { sections, commands } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    commands: ${readCommandsScript()}
  })`);
  return { navigated: result, sections, commands };
}

/** Read commands of the current section. */
export async function getCommands() {
  ensureConnected();
  return await page.evaluate(readCommandsScript());
}

/** Open a command from function panel by name. Returns new form state. */
export async function openCommand(name) {
  ensureConnected();
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(name); await page.waitForTimeout(500); await unhighlight(); } catch {}
  const formBefore = await page.evaluate(detectFormScript());
  const result = await page.evaluate(openCommandScript(name));
  if (result?.error) throw new Error(`openCommand: "${name}" not found. Available: ${result.available?.join(', ') || 'none'}`);

  await waitForStable(formBefore);
  return await returnFormState();
}

/** Switch to an open tab by name (fuzzy match). Returns updated form state. */
export async function switchTab(name) {
  ensureConnected();
  const result = await page.evaluate(switchTabScript(name));
  if (result?.error) throw new Error(`switchTab: "${name}" not found. Available: ${result.available?.join(', ') || 'none'}`);
  await waitForStable();
  return await getFormState();
}

// English → Russian metadata type mapping for e1cib navigation links
const E1CIB_TYPE_MAP = {
  'catalog': 'Справочник', 'catalogs': 'Справочник',
  'document': 'Документ', 'documents': 'Документ',
  'commonmodule': 'ОбщийМодуль',
  'enum': 'Перечисление', 'enums': 'Перечисление',
  'dataprocessor': 'Обработка', 'dataprocessors': 'Обработка',
  'report': 'Отчет', 'reports': 'Отчет',
  'accumulationregister': 'РегистрНакопления',
  'informationregister': 'РегистрСведений',
  'accountingregister': 'РегистрБухгалтерии',
  'calculationregister': 'РегистрРасчета',
  'chartofaccounts': 'ПланСчетов',
  'chartofcharacteristictypes': 'ПланВидовХарактеристик',
  'chartofcalculationtypes': 'ПланВидовРасчета',
  'businessprocess': 'БизнесПроцесс',
  'task': 'Задача',
  'exchangeplan': 'ПланОбмена',
  'constant': 'Константа',
};

// Types that open via e1cib/app/ (reports and data processors have their own app forms)
const E1CIB_APP_TYPES = new Set(['Отчет', 'Обработка']);

function normalizeE1cibUrl(url) {
  // Already a full e1cib link
  if (url.startsWith('e1cib/')) return url;
  // "ТипОбъекта.Имя" or "EnglishType.Имя" — translate type, pick list/ or app/ prefix
  const dot = url.indexOf('.');
  if (dot > 0) {
    const typePart = url.substring(0, dot);
    const namePart = url.substring(dot + 1);
    const ruType = E1CIB_TYPE_MAP[typePart.toLowerCase()] || typePart;
    const prefix = E1CIB_APP_TYPES.has(ruType) ? 'e1cib/app' : 'e1cib/list';
    return `${prefix}/${ruType}.${namePart}`;
  }
  return `e1cib/list/${url}`;
}

/**
 * Open an external data processor or report (EPF/ERF) via File → Open menu.
 * Handles the security confirmation dialog on first open.
 * @param {string} filePath - path to EPF/ERF file (absolute or relative to cwd)
 * @returns {Promise<object>} form state of the opened processor/report
 */
export async function openFile(filePath) {
  ensureConnected();
  await dismissPendingErrors();
  const absPath = resolveProjectPath(filePath.replace(/\\/g, '/'));

  const MAX_ATTEMPTS = 2; // 1st may trigger security dialog, 2nd is the real open
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const formBefore = await page.evaluate(detectFormScript());

    // 1. Ctrl+O opens 1C's "Выбор файлов" dialog
    await page.keyboard.press('Control+o');

    // 2. Wait for the file selection dialog
    const dialogOk = await waitForCondition(`(() => {
      const ok = document.querySelector('#fileSelectDialogOk');
      return ok && ok.offsetWidth > 0 ? true : false;
    })()`, 3000);
    if (!dialogOk) throw new Error("File selection dialog did not open (Ctrl+O)");

    // 3. Click "выберите с диска" to trigger the native OS file picker
    let fileChooser;
    try {
      [fileChooser] = await Promise.all([
        page.waitForEvent('filechooser', { timeout: 5000 }),
        page.click('a.underline.pointer'),
      ]);
    } catch (e) {
      // Try closing the dialog before throwing
      await page.keyboard.press('Escape');
      throw new Error(`File chooser did not appear: ${e.message}`);
    }

    // 4. Set the file path and click OK
    await fileChooser.setFiles(absPath);
    await page.waitForTimeout(500);
    await page.click('#fileSelectDialogOk');
    await waitForStable(formBefore);

    // 5. Check for security dialog
    const err = await checkForErrors();
    if (err?.confirmation) {
      // Security confirmation — click the positive button (Продолжить/Да/OK)
      const positiveBtn = err.confirmation.buttons.find(b =>
        /продолжить|да|ok|yes|открыть/i.test(b)
      ) || err.confirmation.buttons[0];
      if (positiveBtn) {
        const btns = await page.$$(`#form${err.confirmation.formNum}_container a.press.pressButton`);
        for (const b of btns) {
          const txt = (await b.textContent())?.trim();
          if (txt === positiveBtn) { await b.click(); break; }
        }
        await waitForStable(formBefore);
      }
      // After confirmation, check if EPF form appeared or a follow-up dialog showed.
      // Check form change FIRST — avoids confusing a small EPF form with a modal dialog.
      const formAfter = await page.evaluate(detectFormScript());
      if (formAfter != null && formAfter !== formBefore) {
        // New form appeared — but is it the EPF or an informational dialog?
        // Informational "re-open" dialogs are tiny (< 20 elements).
        const elCount = await page.evaluate(`document.querySelectorAll('[id^="form${formAfter}_"]').length`);
        if (elCount < 20) {
          // Likely an info dialog — check and dismiss
          const err2 = await checkForErrors();
          if (err2?.modal) {
            await dismissPendingErrors();
            await waitForStable(formBefore);
            continue; // retry open cycle
          }
        }
        // It's the real EPF form
        const state = await getFormState();
        state.opened = { file: absPath, attempt: attempt + 1 };
        return state;
      }
      // Form didn't appear — retry
      continue;
    }

    // No security dialog — check if form appeared
    if (err?.modal) {
      throw new Error(`Error opening file: ${err.modal.message}`);
    }
    const formAfter = await page.evaluate(detectFormScript());
    if (formAfter != null && formAfter !== formBefore) {
      const state = await getFormState();
      state.opened = { file: absPath, attempt: attempt + 1 };
      return state;
    }
  }

  throw new Error(`Form did not open after ${MAX_ATTEMPTS} attempts for: ${absPath}`);
}

/** Navigate to a 1C navigation link via Shift+F11 dialog. Returns new form state. */
export async function navigateLink(url) {
  ensureConnected();
  await dismissPendingErrors();
  const link = normalizeE1cibUrl(url);
  const formBefore = await page.evaluate(detectFormScript());

  // Copy link to clipboard, press Shift+F11 (opens "Go to link" dialog with clipboard content)
  await pasteText(link, { confirm: 'Shift+F11', postDelay: 200 });
  await waitForStable();

  // Click "Перейти" in the navigation dialog
  const dialog = await page.evaluate(detectFormScript());
  if (dialog != null && dialog !== formBefore) {
    const btns = await page.$$(`#form${dialog}_container a.press`);
    for (const b of btns) {
      const txt = (await b.textContent())?.trim();
      if (txt === 'Перейти') { await b.click(); break; }
    }
  }

  await waitForStable(formBefore);
  return await returnFormState();
}

/** Read current form state. Single evaluate call via combined script. */
export async function getFormState() {
  ensureConnected();
  const state = await page.evaluate(getFormStateScript());
  const err = await checkForErrors();
  if (err) {
    state.errors = err;
    if (err.confirmation) {
      state.confirmation = err.confirmation;
      state.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
  }
  // Detect platform-level dialogs (About, Support Info, Error Report)
  // These are NOT 1C forms — invisible to detectForms() and not closeable via Escape.
  const pd = await _detectPlatformDialogs();
  if (pd.length) state.platformDialogs = pd;
  return state;
}

/** Read structured table data with pagination. Returns columns, rows, total count. */
export async function readTable({ maxRows = 20, offset = 0, table } = {}) {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('readTable: no form found');
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`readTable: ${resolved.message || resolved.error}. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }
  return await page.evaluate(readTableScript(formNum, { maxRows, offset, gridSelector }));
}

// --- Spreadsheet helpers (shared by readSpreadsheet and clickElement) ---

/**
 * Scan spreadsheet iframes for the current form and collect all cells.
 * Returns { allCells: Map<'r_c', {r,c,t}>, frameMap: Map<'r_c', frameIndex> }
 * where frameIndex is the Playwright frames[] index (1-based, 0 = main).
 */
async function scanSpreadsheetCells(formNum) {
  const prefix = `form${formNum ?? 0}_`;
  const iframeHandles = await page.$$('iframe');

  const allCells = new Map();
  const frameMap = new Map(); // key 'r_c' → Playwright Frame object

  for (const handle of iframeHandles) {
    const ok = await handle.evaluate((f, pfx) => {
      if (f.offsetWidth < 100) return false;
      let el = f.parentElement;
      for (let d = 0; el && d < 30; d++, el = el.parentElement) {
        if (el.id && el.id.startsWith(pfx)) return true;
      }
      return false;
    }, prefix);
    if (!ok) continue;

    const frame = await handle.contentFrame();
    if (!frame) continue;

    try {
      const cells = await frame.evaluate(`(() => {
        const cells = [];
        document.querySelectorAll('div[x]').forEach(d => {
          const span = d.querySelector('span');
          const text = span?.innerText?.replace(/\\n/g, ' ')?.trim() || '';
          if (!text) return;
          const rowDiv = d.parentElement;
          const row = rowDiv?.getAttribute('y') || rowDiv?.className?.match(/R(\\d+)/)?.[1] || null;
          const col = d.getAttribute('x');
          if (row != null && col != null) cells.push({ r: parseInt(row), c: parseInt(col), t: text });
        });
        return cells;
      })()`);
      for (const cell of cells) {
        const key = `${cell.r}_${cell.c}`;
        if (!allCells.has(key) || cell.t.length > allCells.get(key).t.length) {
          allCells.set(key, cell);
          frameMap.set(key, frame);
        }
      }
    } catch { /* skip inaccessible frames */ }
  }
  return { allCells, frameMap };
}

/**
 * Build structured mapping from raw cells: headers, column map, data/totals row indices.
 * Returns { rows, sortedRows, maxCol, colNames, headerRowIdx, dataStartIdx, totalsRowIdx, rowMap }
 * or null if header detection fails.
 */
function buildSpreadsheetMapping(allCells) {
  const rowMap = new Map();
  let maxCol = 0;
  for (const cell of allCells.values()) {
    if (!rowMap.has(cell.r)) rowMap.set(cell.r, new Map());
    rowMap.get(cell.r).set(cell.c, cell.t);
    if (cell.c > maxCol) maxCol = cell.c;
  }

  const sortedRows = [...rowMap.keys()].sort((a, b) => a - b);
  const rows = sortedRows.map(r => {
    const cm = rowMap.get(r);
    const arr = [];
    for (let c = 0; c <= maxCol; c++) arr.push(cm.get(c) || '');
    return arr;
  });

  // Generic numeric check: digits with optional spaces/commas, excludes codes like "68/78"
  // Accepts bare integers (e.g. account codes "50", "84") — used for hasNumber / totals classification.
  const isNumericVal = (c) => {
    if (!c || !/\d/.test(c)) return false;
    const s = c.replace(/^[-\s\u00a0]+/, '').replace(/[\s\u00a0]/g, '');
    return /^\d[\d,]*$/.test(s);
  };
  // Data-formatted numeric value: requires a formatting signal (grouping space, decimal comma, or leading minus).
  // Used as the anchor for first data row — avoids false positives on bare account codes like "50", "51".
  const isDataNumericVal = (c) => {
    if (!isNumericVal(c)) return false;
    return /[\s\u00a0,]/.test(c) || /^-/.test(c);
  };
  const hasNumber = (row) => row.some(c => isNumericVal(c));
  const nonEmpty = (row) => row.filter(c => c !== '').length;

  // Build a rich mapping (group/super/DCS) anchored at a known detailIdx + firstDataIdx.
  // Shared by Level 1 (DCS-code anchor) and Level 2 (formatted-number anchor).
  const buildRichMapping = (detailIdx, firstDataIdx) => {
    let groupIdx = -1;
    if (detailIdx > 0 && nonEmpty(rows[detailIdx - 1]) >= 2) groupIdx = detailIdx - 1;

    const detailRow = rows[detailIdx];
    const groupRow = groupIdx >= 0 ? rows[groupIdx] : null;

    // Detect optional third header level above group row (bounds carry-forward)
    let superRow = null;
    if (groupIdx > 0 && nonEmpty(rows[groupIdx - 1]) >= 2) {
      superRow = rows[groupIdx - 1];
    }

    // Build column names (group + detail merge)
    const groupFilled = new Array(maxCol + 1).fill('');
    if (groupRow) {
      let cur = '';
      for (let c = 0; c <= maxCol; c++) {
        if (groupRow[c]) {
          cur = groupRow[c];
        } else if (superRow && superRow[c]) {
          // New top-level header starts here — stop carry-forward
          cur = '';
        }
        groupFilled[c] = cur;
      }
    }

    const detailCounts = {};
    for (let c = 0; c <= maxCol; c++) {
      const n = detailRow[c];
      if (n) detailCounts[n] = (detailCounts[n] || 0) + 1;
    }

    // Detect DCS column codes (К1, К2, ...) — always prefix with group when present
    const detailNonEmpty = detailRow.filter(c => c);
    const isDcsCodeRow = detailNonEmpty.length >= 2 && detailNonEmpty.every(c => /^К\d+$/.test(c));

    const colNames = [];
    for (let c = 0; c <= maxCol; c++) {
      const detail = detailRow[c];
      const group = groupFilled[c];
      const sup = superRow ? superRow[c] : '';
      if (detail) {
        // Prefer group prefix; fall back to superRow for DCS code columns without sub-group
        const prefix = group && group !== detail ? group : (isDcsCodeRow && sup ? sup : '');
        const needPrefix = prefix && (isDcsCodeRow || detailCounts[detail] > 1 || (groupRow && groupRow[c] === ''));
        colNames.push(needPrefix ? `${prefix} / ${detail}` : detail);
      } else if (group) {
        colNames.push(group);
      } else if (sup) {
        colNames.push(sup);
      } else {
        colNames.push(null);
      }
    }

    const colMap = new Map();
    for (let c = 0; c < colNames.length; c++) {
      if (colNames[c]) colMap.set(colNames[c], c);
    }

    // Classify data rows: separate data indices and totals index
    const dataRowIndices = [];
    let totalsRowIdx = -1;
    for (let i = firstDataIdx; i < rows.length; i++) {
      if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
      const first = rows[i][0]?.trim().toLowerCase();
      if (first === 'итого' || first === 'всего') {
        totalsRowIdx = i;
      } else {
        dataRowIndices.push(i);
      }
    }

    const superRowIdx = superRow ? groupIdx - 1 : -1;

    return {
      rows, sortedRows, maxCol, colNames, colMap,
      headerRowIdx: detailIdx, groupRowIdx: groupIdx, superRowIdx,
      dataStartIdx: firstDataIdx, dataRowIndices, totalsRowIdx,
      rowMap, hasNumber, nonEmpty,
    };
  };

  // --- Level 1: DCS-code row anchor ---
  // ФСД / СКД-отчёты всегда содержат строку "К1, К2, ..." — rock-solid structural marker.
  // Якорение через неё — детерминированное, работает даже если все данные — голые целые (отчёт в "тыс.руб").
  for (let i = 0; i < rows.length; i++) {
    const detailNonEmpty = rows[i].filter(c => c);
    if (detailNonEmpty.length >= 2 && detailNonEmpty.every(c => /^К\d+$/.test(c))) {
      // Find first non-empty row after the К-codes row as data start
      let firstDataIdx = rows.length;
      for (let j = i + 1; j < rows.length; j++) {
        if (nonEmpty(rows[j]) > 0) { firstDataIdx = j; break; }
      }
      return buildRichMapping(i, firstDataIdx);
    }
  }

  // --- Level 2: formatted-number anchor (heuristic for reports without DCS codes) ---
  let firstDataIdx = rows.length;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].filter(c => isDataNumericVal(c)).length >= 2) { firstDataIdx = i; break; }
  }
  if (firstDataIdx === rows.length) {
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].some(c => isDataNumericVal(c))) { firstDataIdx = i; break; }
    }
  }

  if (firstDataIdx < rows.length) {
    let detailIdx = -1;
    for (let i = firstDataIdx - 1; i >= 0; i--) {
      if (nonEmpty(rows[i]) >= Math.min(3, maxCol + 1)) { detailIdx = i; break; }
    }
    if (detailIdx !== -1) return buildRichMapping(detailIdx, firstDataIdx);
  }

  // --- Level 3: single-row header fallback (text-only data, query console) ---
  // First "wide" row (nonEmpty >= 2) = headers, rest = data. No multi-level composition.
  let headerIdx = -1;
  for (let i = 0; i < rows.length; i++) {
    if (nonEmpty(rows[i]) >= 2) { headerIdx = i; break; }
  }
  // Single-column tables: accept nonEmpty >= 1
  if (headerIdx === -1 && maxCol === 0) {
    for (let i = 0; i < rows.length; i++) {
      if (nonEmpty(rows[i]) >= 1) { headerIdx = i; break; }
    }
  }
  if (headerIdx === -1) return null; // truly empty — top-level fallback to { rows, total }

  const detailRow = rows[headerIdx];
  const colNames = [];
  for (let c = 0; c <= maxCol; c++) colNames.push(detailRow[c] || null);
  const colMap = new Map();
  for (let c = 0; c < colNames.length; c++) {
    if (colNames[c]) colMap.set(colNames[c], c);
  }

  const dataRowIndices = [];
  let totalsRowIdx = -1;
  for (let i = headerIdx + 1; i < rows.length; i++) {
    if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
    const first = rows[i][0]?.trim().toLowerCase();
    if (first === 'итого' || first === 'всего') {
      totalsRowIdx = i;
    } else {
      dataRowIndices.push(i);
    }
  }

  return {
    rows, sortedRows, maxCol, colNames, colMap,
    headerRowIdx: headerIdx, groupRowIdx: -1, superRowIdx: -1,
    dataStartIdx: headerIdx + 1, dataRowIndices, totalsRowIdx,
    rowMap, hasNumber, nonEmpty,
  };
}

/**
 * Scroll SpreadsheetDocument to make a cell visible using arrow keys.
 * Uses native platform scroll — keeps headers, data, and scrollbar synchronized.
 *
 * How it works:
 * 1. Check target cell visibility via Playwright boundingBox (page-level coords).
 * 2. Click a fully-visible cell via page.mouse.click through the mxlCurrBody overlay.
 *    This is the same native click that clickSpreadsheetCell uses — it gives keyboard
 *    focus to the spreadsheet and keeps headers/data/scrollbar in sync.
 *    (frame.locator().click() bypasses overlay → desyncs frozen headers;
 *     page.mouse.click() + frameEl.focus() doesn't transfer keyboard focus.)
 * 3. Press ArrowRight/ArrowLeft until the target cell is fully within the viewport.
 *
 * @param {Frame} frame - Playwright Frame containing the spreadsheet cells
 * @param {number} physRow - physical row (y attribute) in the frame
 * @param {number} physCol - physical column (x attribute) in the frame
 * @param {Locator} cellLoc - Playwright locator for the target cell (from caller)
 */
async function scrollSpreadsheetToCell(frame, physRow, physCol, cellLoc) {
  const pageVw = await page.evaluate('window.innerWidth');
  // Get iframe bounds — the actual visible region on page.
  // The iframe may extend behind the section panel on the left, so cells with
  // x >= 0 but x < iframeBox.x are behind the panel. Clicking them hits the panel.
  const frameElm = await frame.frameElement();
  const frameBox = await frameElm.boundingBox();
  const visLeft = frameBox ? frameBox.x : 0;
  const visRight = frameBox ? Math.min(frameBox.x + frameBox.width, pageVw) : pageVw;

  const getBox = async () => {
    try { return await cellLoc.boundingBox({ timeout: 500 }); }
    catch { return null; }
  };
  const isFullyVisible = (box) => box && box.x >= visLeft && (box.x + box.width) <= visRight;

  let box = await getBox();
  if (!box) return; // cell not in DOM
  if (isFullyVisible(box)) return;

  const direction = (box.x + box.width) > pageVw ? 'ArrowRight' : 'ArrowLeft';

  // Find a fully-visible cell to click for focus.
  // Prefer cells in the target row (scrollable area), fall back to any row.
  const targetRowSel = `div[y="${physRow}"] div[x]`;
  const anyRowSel = 'div[x]';
  let focusClicked = false;
  for (const sel of [targetRowSel, anyRowSel]) {
    const locs = frame.locator(sel);
    const count = await locs.count();
    const candidates = [];
    for (let ci = 0; ci < count; ci++) {
      const b = await locs.nth(ci).boundingBox();
      if (b && b.width > 5 && b.x >= visLeft && (b.x + b.width) <= visRight) {
        candidates.push({ ci, box: b });
      }
    }
    if (candidates.length === 0) continue;
    candidates.sort((a, b) => a.box.x - b.box.x);
    // ArrowRight → rightmost fully-visible (each press scrolls right immediately)
    // ArrowLeft  → leftmost fully-visible  (each press scrolls left immediately)
    const pick = direction === 'ArrowRight'
      ? candidates[candidates.length - 1]
      : candidates[0];
    // Native click through overlay — gives keyboard focus + no header desync.
    await page.mouse.click(pick.box.x + pick.box.width / 2, pick.box.y + pick.box.height / 2);
    await page.waitForTimeout(100);
    focusClicked = true;
    break;
  }
  if (!focusClicked) return; // no visible cells — can't scroll

  // Arrow keys until cell is fully visible or we detect no progress.
  const MAX_STALE = 5; // bail out if arrows aren't scrolling (lost focus?)
  let prevCx = box.x + box.width / 2;
  let staleCount = 0;
  for (let i = 0; i < 100; i++) {
    await page.keyboard.press(direction);
    await page.waitForTimeout(50);
    box = await getBox();
    if (!box) break;
    if (isFullyVisible(box)) break;
    const cx = box.x + box.width / 2;
    if (Math.abs(cx - prevCx) >= 1) {
      staleCount = 0;
    } else {
      staleCount++;
      if (staleCount >= MAX_STALE) break;
    }
    prevCx = cx;
  }
  await page.waitForTimeout(200);
}

/**
 * Click a cell in SpreadsheetDocument by logical coordinates.
 * target: { row: number|'totals'|{colName: value}, column: string }
 * Internal helper — called from clickElement when first arg is an object.
 */
async function clickSpreadsheetCell(target, { dblclick: dbl, modifier } = {}) {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());
  const { allCells, frameMap } = await scanSpreadsheetCells(formNum);
  if (allCells.size === 0) throw new Error('clickElement: no SpreadsheetDocument found on current form.');

  const mapping = buildSpreadsheetMapping(allCells);
  if (!mapping) throw new Error('clickElement: could not detect spreadsheet headers. Use readSpreadsheet() to check report structure.');

  const { rows, sortedRows, colNames, colMap, dataRowIndices, totalsRowIdx } = mapping;

  // Resolve column (exact → endsWith " / X" → includes)
  let colName = target.column;
  if (!colMap.has(colName)) {
    const available = colNames.filter(n => n);
    const suffix = ' / ' + colName;
    const match = available.find(n => n.endsWith(suffix)) || available.find(n => n.includes(colName));
    if (!match) throw new Error(`clickElement: column "${colName}" not found. Available: ${available.join(', ')}`);
    colName = match;
  }
  const physCol = colMap.get(colName);

  // Resolve row → index into rows[] array
  let rowIdx;
  const row = target.row;
  if (row === 'totals') {
    if (totalsRowIdx === -1) throw new Error('clickElement: no totals row found in spreadsheet.');
    rowIdx = totalsRowIdx;
  } else if (typeof row === 'number') {
    if (row < 0 || row >= dataRowIndices.length) throw new Error(`clickElement: row index ${row} out of range (0..${dataRowIndices.length - 1}).`);
    rowIdx = dataRowIndices[row];
  } else if (typeof row === 'object') {
    // Filter: { colName: value } — find first data row where column matches
    const filterEntries = Object.entries(row);
    const norm = s => s?.replace(/\u00a0/g, ' ').trim().toLowerCase() || '';
    const resolveCol = (name) => {
      if (colMap.has(name)) return colMap.get(name);
      const suffix = ' / ' + name;
      const available = colNames.filter(n => n);
      const m = available.find(n => n.endsWith(suffix)) || available.find(n => n.includes(name));
      return m ? colMap.get(m) : null;
    };
    rowIdx = dataRowIndices.find(i => {
      return filterEntries.every(([fCol, fVal]) => {
        const fColIdx = resolveCol(fCol);
        if (fColIdx == null) return false;
        const cellText = norm(rows[i][fColIdx]);
        const search = norm(fVal);
        return cellText === search || cellText.includes(search);
      });
    });
    if (rowIdx == null) throw new Error(`clickElement: no row matching ${JSON.stringify(row)} found in spreadsheet data.`);
  } else {
    throw new Error('clickElement: row must be a number, "totals", or { colName: value } filter object.');
  }

  // Map rows[] index → physical row number
  const physRow = sortedRows[rowIdx];
  const cellKey = `${physRow}_${physCol}`;
  const frame = frameMap.get(cellKey);
  if (!frame) {
    // Cell exists in mapping but might be empty — try clicking anyway
    throw new Error(`clickElement: cell at row=${JSON.stringify(target.row)}, column="${colName}" is empty or not rendered.`);
  }
  // Use [y]+[x] attributes — CSS class RxCy uses different numbering than y/x attrs.
  const cellDiv = frame.locator(`div[y="${physRow}"] div[x="${physCol}"]`).first();
  // Scroll cell into view using arrow keys — the only reliable way to scroll
  // 1C SpreadsheetDocument without desynchronizing headers, data, and scrollbar.
  await scrollSpreadsheetToCell(frame, physRow, physCol, cellDiv);
  const box = await cellDiv.boundingBox();
  if (!box) throw new Error(`clickElement: cell y=${physRow} x=${physCol} not visible (no bounding box).`);

  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
  if (modKey) await page.keyboard.down(modKey);
  if (dbl) {
    await page.mouse.dblclick(x, y);
  } else {
    await page.mouse.click(x, y);
  }
  if (modKey) await page.keyboard.up(modKey);

  await waitForStable();
  const state = await getFormState();
  state.clicked = { kind: 'spreadsheetCell', row: target.row, column: colName, ...(dbl ? { dblclick: true } : {}) };
  return state;
}

/**
 * Search spreadsheet iframes for a cell matching text (for text fallback in clickElement).
 * Returns { frameIndex, physRow, physCol, box } or null if not found.
 */
async function findSpreadsheetCellByText(formNum, searchText) {
  const { allCells, frameMap } = await scanSpreadsheetCells(formNum);
  if (allCells.size === 0) return null;

  const norm = s => s?.replace(/\u00a0/g, ' ').trim().toLowerCase() || '';
  const target = norm(searchText);

  // Exact match first, then includes
  let found = null;
  for (const [key, cell] of allCells) {
    if (norm(cell.t) === target) { found = { key, cell }; break; }
  }
  if (!found) {
    for (const [key, cell] of allCells) {
      if (norm(cell.t).includes(target)) { found = { key, cell }; break; }
    }
  }
  if (!found) return null;

  const frame = frameMap.get(found.key);
  if (!frame) return null;

  // Scroll cell into view using native arrow-key mechanism
  const cellDiv = frame.locator(`div[y="${found.cell.r}"] div[x="${found.cell.c}"]`).first();
  await scrollSpreadsheetToCell(frame, found.cell.r, found.cell.c, cellDiv);
  const box = await cellDiv.boundingBox();
  if (!box) return null;

  return { frame, physRow: found.cell.r, physCol: found.cell.c, text: found.cell.t, box };
}

/**
 * Read report output (SpreadsheetDocumentField) rendered in iframes.
 * 1C renders spreadsheet documents as absolutely-positioned div cells inside iframes.
 * Each cell is a div[x] inside a row div[y], text content in <span>.
 *
 * Returns structured data:
 *   { title, headers, data: [{col: val}], totals: {col: val}, total }
 * If header detection fails, falls back to { rows: string[][], total }.
 */
export async function readSpreadsheet() {
  ensureConnected();
  const formNum = await page.evaluate(detectFormScript());

  const { allCells } = await scanSpreadsheetCells(formNum);

  if (allCells.size === 0) {
    // Check for state window messages (info bar) that explain why the report is empty
    const err = await checkForErrors();
    const hint = err?.stateText?.length ? err.stateText.join('; ') : '';
    throw new Error('readSpreadsheet: no SpreadsheetDocument found.' + (hint ? ' State: ' + hint : ' Report may not be generated yet.'));
  }

  const mapping = buildSpreadsheetMapping(allCells);
  if (!mapping) {
    // Fallback: return raw rows
    const rowMap = new Map();
    let maxCol = 0;
    for (const cell of allCells.values()) {
      if (!rowMap.has(cell.r)) rowMap.set(cell.r, new Map());
      rowMap.get(cell.r).set(cell.c, cell.t);
      if (cell.c > maxCol) maxCol = cell.c;
    }
    const sortedRows = [...rowMap.keys()].sort((a, b) => a - b);
    const rows = sortedRows.map(r => {
      const cm = rowMap.get(r);
      const arr = [];
      for (let c = 0; c <= maxCol; c++) arr.push(cm.get(c) || '');
      return arr;
    });
    return { rows, total: rows.length };
  }

  const { rows, colNames, dataStartIdx, maxCol, groupRowIdx, headerRowIdx, superRowIdx, hasNumber, nonEmpty } = mapping;

  // Convert data rows to objects
  const data = [];
  let totals = null;
  const toObj = (row) => {
    const obj = {};
    for (let c = 0; c < colNames.length; c++) {
      if (colNames[c] && row[c]) obj[colNames[c]] = row[c];
    }
    return obj;
  };

  for (let i = dataStartIdx; i < rows.length; i++) {
    if (!hasNumber(rows[i]) && nonEmpty(rows[i]) === 0) continue;
    const first = rows[i][0]?.trim().toLowerCase();
    if (first === 'итого' || first === 'всего') {
      totals = toObj(rows[i]);
    } else {
      data.push(toObj(rows[i]));
    }
  }

  // Meta: title, params, filters from rows before header (superRow is part of header, not meta)
  const metaEnd = superRowIdx >= 0 ? superRowIdx : (groupRowIdx >= 0 ? groupRowIdx : headerRowIdx);
  let title = '';
  const meta = [];
  for (let i = 0; i < metaEnd; i++) {
    const parts = rows[i].filter(c => c);
    if (!parts.length) continue;
    if (!title) { title = parts.join(' '); continue; }
    meta.push(parts.join(' '));
  }

  return {
    title: title || undefined,
    meta: meta.length ? meta : undefined,
    headers: colNames.filter(n => n),
    data,
    totals: totals || undefined,
    total: data.length,
  };
}

/**
 * Scan visible grid rows for a text match (exact → startsWith → includes).
 * Returns center coords of the matched row, or null if not found.
 * When searchLower is empty, returns coords of the first row (fallback).
 */
async function scanGridRows(formNum, searchLower) {
  return page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const grid = document.querySelector('[id^="' + p + '"].grid, [id^="' + p + '"] .grid');
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const lines = [...body.querySelectorAll('.gridLine')];
    if (!lines.length) return { rowCount: 0 };
    const searchLower = ${JSON.stringify(searchLower || '')};
    let sel = null;
    if (searchLower) {
      const norm = s => (s || '').replace(/\\u00a0/g, ' ').trim().toLowerCase().replace(/ё/gi, 'е');
      const rowData = lines.map(l => ({ el: l, text: norm(l.innerText) }));
      sel = rowData.find(r => r.text === searchLower)?.el
        || rowData.find(r => r.text.startsWith(searchLower))?.el
        || rowData.find(r => r.text.includes(searchLower))?.el;
    } else {
      sel = lines[0]; // empty search → first row
    }
    if (!sel) return null;
    const imgBox = sel.querySelector('.gridBoxImg');
    const isGroup = imgBox ? !!imgBox.querySelector('.gridListH') : false;
    const r = sel.getBoundingClientRect();
    return { rowCount: lines.length, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), isGroup };
  })()`);
}

/**
 * Select a row in a selection form via click + Enter, verify it closed.
 * Uses click + Enter instead of dblclick because dblclick toggles
 * expand/collapse in tree-style selection forms.
 * Returns { field, ok: true, method: 'form' } on success,
 * or { field, ok: false, reason: 'still_open' } if the item couldn't be selected (e.g. group row).
 */
async function dblclickAndVerify(coords, selFormNum, fieldName) {
  // Click to highlight the row, then Enter to confirm selection.
  // This works for both flat grids and tree forms (dblclick would
  // toggle expand/collapse on tree group rows).
  await page.mouse.click(coords.x, coords.y);
  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');
  await waitForStable(selFormNum);

  // Verify selection form closed
  const stillOpen = await page.evaluate(`(() => {
    const p = 'form${selFormNum}_';
    return [...document.querySelectorAll('[id^="' + p + '"]')].some(el => el.offsetWidth > 0);
  })()`);
  if (stillOpen) {
    // Enter didn't select — item is likely a non-selectable group.
    // Don't Escape here — let the caller decide (may want to try another row).
    return { field: fieldName, ok: false, reason: 'still_open' };
  }

  // Check for 1C error modals after selection
  const err = await page.evaluate(checkErrorsScript());
  if (err?.modal) {
    try {
      const btn = await page.$('a.press.pressDefault');
      if (btn) { await btn.click(); await page.waitForTimeout(500); }
    } catch { /* OK */ }
  }
  return { field: fieldName, ok: true, method: 'form' };
}

/**
 * Inline advanced search on a selection form via Alt+F.
 * Does NOT click any column — FieldSelector auto-populates with main representation.
 * Switches to "по части строки" (CompareType#1) to avoid composite type issues.
 * Does not throw — returns silently on failure.
 */
async function advancedSearchInline(formNum, text) {
  try {
    // 1. Open advanced search via Alt+F
    await page.keyboard.press('Alt+f');
    await page.waitForTimeout(2000);

    const dialogForm = await page.evaluate(detectFormScript());
    if (dialogForm === formNum || dialogForm === null) return; // Alt+F didn't open dialog

    // 2. Switch to "по части строки" (CompareType#1)
    const radioClicked = await page.evaluate(`(() => {
      const p = 'form${dialogForm}_';
      const el = document.getElementById(p + 'CompareType#1#radio');
      if (!el || el.offsetWidth === 0) return false;
      if (el.classList.contains('select')) return true; // already selected
      const r = el.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (radioClicked && typeof radioClicked === 'object') {
      await page.mouse.click(radioClicked.x, radioClicked.y);
      await page.waitForTimeout(300);
    }

    // 3. Fill Pattern field via clipboard paste
    const patternId = await page.evaluate(`(() => {
      const p = 'form${dialogForm}_';
      const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /Pattern/i.test(el.id));
      return el ? el.id : null;
    })()`);
    if (!patternId) {
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      return;
    }
    await page.click(`[id="${patternId}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(300);

    // 4. Click "Найти"
    const findBtn = await page.evaluate(`(() => {
      const btns = [...document.querySelectorAll('a.press')].filter(el => el.offsetWidth > 0);
      const btn = btns.find(el => el.innerText?.trim() === 'Найти');
      if (!btn) return null;
      const r = btn.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (findBtn) {
      await page.mouse.click(findBtn.x, findBtn.y);
      await page.waitForTimeout(2000);
    }

    // 5. Close advanced search dialog
    for (let attempt = 0; attempt < 3; attempt++) {
      const dialogVisible = await page.evaluate(`(() => {
        const p = 'form${dialogForm}_';
        return [...document.querySelectorAll('[id^="' + p + '"]')].some(el => el.offsetWidth > 0);
      })()`);
      if (!dialogVisible) break;
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
    }
    await waitForStable(formNum);
  } catch { /* silently fail — caller will re-scan and handle not_found */ }
}

/**
 * Pick a value from an opened selection form.
 *
 * Strategy (escalating):
 *   1. Scan visible rows for text match (exact → startsWith → includes)
 *   2. Advanced search (Alt+F, "по части строки") → re-scan
 *   3. Fallback: simple search (search input + Enter) → re-scan
 *   4. Not found → Escape → error
 *
 * For object search {field: value}: steps 1, then filterList(val, {field}) per entry, then re-scan.
 * For empty search: pick first visible row.
 *
 * @param {number} selFormNum - selection form number
 * @param {string} fieldName - field being filled (for error messages)
 * @param {string|Object} search - string for simple search, or { field: value } for per-field search
 * @param {number} origFormNum - original form number (to verify we returned)
 * @returns {{ field, ok, method }} or {{ field, error, message }}
 */
async function pickFromSelectionForm(selFormNum, fieldName, search, origFormNum) {
  const searchText = typeof search === 'string'
    ? search : (search ? Object.values(search).join(' ') : '');
  const searchLower = normYo((searchText || '').toLowerCase());

  // Helper: try to select a row; returns result if ok, null if item wasn't selectable (group).
  let hadUnselectableMatch = false;
  async function trySelect(row) {
    const r = await dblclickAndVerify(row, selFormNum, fieldName);
    if (r.ok) return r;
    hadUnselectableMatch = true; // found match but couldn't select (possibly group row or overlay)
    return null; // form still open, try next step
  }

  // Step 1: Scan visible rows (no filtering)
  if (searchLower) {
    const row = await scanGridRows(selFormNum, searchLower);
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  // Step 2: Advanced search (Alt+F — fast, no overlay issues)
  if (typeof search === 'object' && search) {
    // Per-field advanced search via filterList(val, {field})
    for (const [fld, val] of Object.entries(search)) {
      try { await filterList(String(val), { field: fld }); } catch { /* proceed */ }
    }
  } else if (searchLower) {
    // Inline advanced search (Alt+F, "по части строки")
    await advancedSearchInline(selFormNum, searchText);
  }
  if (searchLower) {
    const row = await scanGridRows(selFormNum, searchLower);
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  // Step 3: Fallback — simple search via search input (for forms without Alt+F support)
  if (typeof search === 'string' && searchLower) {
    const searchInputId = await page.evaluate(`(() => {
      const p = 'form${selFormNum}_';
      const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
      return el ? el.id : null;
    })()`);
    if (searchInputId) {
      try {
        await page.click(`[id="${searchInputId}"]`);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(searchText);
        await page.waitForTimeout(300);
        await page.keyboard.press('Enter');
        await waitForStable(selFormNum);
      } catch { /* proceed */ }
      const row = await scanGridRows(selFormNum, searchLower);
      if (row?.x) {
        const r = await trySelect(row);
        if (r) return r;
      }
    }
  }

  // Step 4: Empty search → pick first row; otherwise not found
  if (!searchLower) {
    const row = await scanGridRows(selFormNum, '');
    if (row?.x) {
      const r = await trySelect(row);
      if (r) return r;
    }
  }

  await page.keyboard.press('Escape');
  await waitForStable();
  const searchDesc = typeof search === 'string' ? '"' + search + '"' : JSON.stringify(search);
  if (hadUnselectableMatch) {
    return { field: fieldName, error: 'not_selectable',
      message: 'Found ' + searchDesc + ' in selection form but it is not selectable (group/folder row)' };
  }
  return { field: fieldName, error: 'not_found',
    message: 'No matches in selection form for ' + searchDesc };
}

/**
 * Detect whether a form is a type selection dialog ("Выбор типа данных").
 * Type dialogs appear when selecting a value for a composite-type field.
 *
 * Detection signals (any one is sufficient):
 * - form{N}_OK element exists (selection forms use "Выбрать", not "OK")
 * - form{N}_ValueList grid exists (specific to type/value list dialogs)
 * - Window title contains "Выбор типа" (title attr on .toplineBoxTitle)
 */
async function isTypeDialog(formNum) {
  return page.evaluate(`(() => {
    const p = 'form' + ${formNum} + '_';
    const hasOK = !!document.getElementById(p + 'OK');
    const hasValueList = !!document.getElementById(p + 'ValueList');
    const hasTitle = [...document.querySelectorAll('.toplineBoxTitle')]
      .some(el => el.offsetWidth > 0 && /выбор типа/i.test(el.getAttribute('title') || ''));
    return hasOK || hasValueList || hasTitle;
  })()`);
}

/**
 * Select a type from the type selection dialog ("Выбор типа данных")
 * using Ctrl+F search. The dialog has a virtual grid (~5 visible rows),
 * so Ctrl+F is the only reliable way to find a type.
 *
 * Algorithm: Ctrl+F → paste typeName → Enter (search) → Escape (close Find) →
 * verify selected row matches → Enter (OK)
 *
 * @param {number} formNum - type dialog form number
 * @param {string} typeName - type name to search for (fuzzy, e.g. "Реализация (акт")
 * @throws {Error} if type not found
 */
async function pickFromTypeDialog(formNum, typeName) {
  // The type dialog is a modal ValueList grid.
  // Strategy: scan visible rows first (fast path), fall back to Ctrl+F for large lists.
  //
  // Key constraints discovered during testing:
  // - Grid focus: use evaluate(() => gridBody.focus()), NOT page.click({force:true})
  //   which punches through the modal overlay to the form underneath
  // - Ctrl+F only opens "Найти" if the GRID is focused (otherwise closes the type dialog)
  // - Buttons: use page.click({force:true}), NOT evaluate(() => el.click())
  //   because evaluate click doesn't trigger 1C's event chain properly
  // - Enter/Escape in "Найти" close the ENTIRE dialog chain, not just "Найти"
  // - Closing "Найти" via Cancel resets the search — verify grid while "Найти" is open

  const typeNorm = normYo(typeName.toLowerCase());

  // Helper: read visible rows and find matching ones
  async function readVisibleRows() {
    return page.evaluate(`(() => {
      const grid = document.getElementById('form${formNum}_ValueList');
      if (!grid) return { visible: [], matches: [] };
      const body = grid.querySelector('.gridBody');
      if (!body) return { visible: [], matches: [] };
      const lines = body.querySelectorAll('.gridLine');
      const norm = s => (s || '').replace(/\\u00a0/g, ' ').trim();
      const typeNorm = ${JSON.stringify(typeNorm)};
      const visible = [];
      const matches = [];
      for (const line of lines) {
        const text = norm(line.innerText);
        if (!text) continue;
        visible.push(text);
        if (text.toLowerCase().replace(/ё/gi, 'е').includes(typeNorm)) {
          const r = line.getBoundingClientRect();
          matches.push({ text, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
        }
      }
      return { visible, matches };
    })()`);
  }

  // Step 1: Scan visible rows (fast path — no Ctrl+F needed for small lists)
  const scan = await readVisibleRows();

  if (scan.matches.length === 1) {
    // Single match — click to select, then OK
    await page.mouse.click(scan.matches[0].x, scan.matches[0].y);
    await page.waitForTimeout(200);
    await page.click(`#form${formNum}_OK`, { force: true });
    await page.waitForTimeout(ACTION_WAIT);
    return;
  }

  if (scan.matches.length > 1) {
    for (let i = 0; i < 3; i++) { await page.keyboard.press('Escape'); await page.waitForTimeout(300); }
    await waitForStable();
    throw new Error(`selectValue: multiple types match "${typeName}": ${scan.matches.map(m => '"' + m.text + '"').join(', ')}. Specify a more precise type name`);
  }

  // Step 2: Not found in visible rows — use Ctrl+F (virtual grid may have more items)

  // Focus the grid via evaluate (does NOT punch through modal like page.click)
  await page.evaluate(`(() => {
    const grid = document.getElementById('form${formNum}_ValueList');
    if (!grid) return;
    const body = grid.querySelector('.gridBody');
    if (body) body.focus(); else grid.focus();
  })()`);
  await page.waitForTimeout(300);

  // Ctrl+F to open "Найти" dialog
  await page.keyboard.press('Control+f');
  await page.waitForTimeout(1000);

  // Paste search text (focus is on "Что искать" field)
  await page.keyboard.press('Control+a');
  await pasteText(typeName);
  await page.waitForTimeout(300);

  // Find the "Найти" dialog form number (it's > formNum)
  const findFormNum = await page.evaluate(`(() => {
    for (let n = ${formNum} + 1; n < ${formNum} + 20; n++) {
      const btn = document.getElementById('form' + n + '_Find');
      if (btn && btn.offsetWidth > 0) return n;
    }
    return null;
  })()`);

  if (findFormNum === null) {
    await page.keyboard.press('Escape');
    await waitForStable();
    throw new Error('selectValue: Ctrl+F did not open "Найти" dialog in type selection');
  }

  // Click "Найти" — search is client-side (no server round-trip), 500ms is enough
  await page.click(`#form${findFormNum}_Find`, { force: true });
  await page.waitForTimeout(500);

  // Re-read visible rows after search scrolled to match
  const afterSearch = await readVisibleRows();

  if (afterSearch.matches.length === 0) {
    for (let i = 0; i < 3; i++) { await page.keyboard.press('Escape'); await page.waitForTimeout(300); }
    await waitForStable();
    throw new Error(`selectValue: type "${typeName}" not found in type selection dialog` +
      `. Visible: ${(scan.visible || []).join(', ')}`);
  }

  if (afterSearch.matches.length > 1) {
    for (let i = 0; i < 3; i++) { await page.keyboard.press('Escape'); await page.waitForTimeout(300); }
    await waitForStable();
    throw new Error(`selectValue: multiple types match "${typeName}": ${afterSearch.matches.map(m => '"' + m.text + '"').join(', ')}. Specify a more precise type name`);
  }

  // Click OK on type dialog via page.click({force:true}) — bypasses "Найти" modal
  await page.click(`#form${formNum}_OK`, { force: true });
  await page.waitForTimeout(ACTION_WAIT);
}

/**
 * Fill a reference field via clipboard paste + 1C autocomplete.
 *
 * Strategy:
 *   1. Clear field if it has a value (Shift+F4 — native 1C mechanism, no JS errors)
 *   2. Clipboard paste text (Ctrl+V = trusted event, triggers real 1C autocomplete)
 *   3. Check editDropDown for autocomplete results → click match or Tab to resolve
 *   4. Verify result: resolved → ok, not found → clear + error
 *
 * Clipboard paste was chosen because:
 *   - Ctrl+V produces trusted browser events that 1C respects for autocomplete
 *   - page.fill() + synthetic keydown/keyup only triggers hints, not real search
 *   - keyboard.type() garbles Cyrillic on some fields
 *
 * @returns {{ field, ok?, method?, error?, value?, message?, available? }}
 */
async function fillReferenceField(selector, fieldName, value, formNum) {
  const text = String(value);
  const escapedSel = selector.replace(/'/g, "\\'");

  // Helper: detect new forms opened above the current one (strict — interactive
  // elements only; fillReferenceField-specific)
  const detectNewForm = () => helperDetectNewForm(formNum, { strict: true });

  // Helper: clear the field using Shift+F4 (native 1C mechanism)
  async function clearField() {
    try {
      await page.click(selector, { timeout: 3000 });
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
    } catch { /* OK */ }
  }

  // Helper: check for "not in list" cloud popup (1C shows positioned div with "нет в списке")
  async function checkNotInListCloud() {
    return page.evaluate(`(() => {
      const divs = document.querySelectorAll('div');
      for (const el of divs) {
        if (el.offsetWidth === 0 || el.offsetHeight === 0) continue;
        const style = getComputedStyle(el);
        if (style.position !== 'absolute' && style.position !== 'fixed') continue;
        const z = parseInt(style.zIndex) || 0;
        if (z < 100) continue;
        if ((el.innerText || '').includes('нет в списке')) return true;
      }
      return false;
    })()`);
  }

  // 0. Dismiss any leftover error modal from a previous operation
  await dismissPendingErrors();

  // 0a. Try DLB (DropListButton) first — works cleanly for combobox/enum fields
  //     and also for reference fields that show a dropdown.
  const inputId = selector.match(/\[id="(.+)"\]/)?.[1];
  // DLB button ID uses field name without _iN suffix (e.g. form1_Field_DLB, not form1_Field_i0_DLB)
  const dlbId = inputId.replace(/_i\d+$/, '') + '_DLB';
  const dlbSelector = `[id="${dlbId}"]`;
  try {
    const dlbVisible = await page.evaluate(`document.querySelector('${dlbSelector.replace(/'/g, "\\'")}')?.offsetWidth > 0`);
    if (dlbVisible) {
      await page.click(dlbSelector);
      await page.waitForTimeout(1000);
      const eddState = await readEdd();
      if (eddState.visible && eddState.items?.length > 0) {
        const target = normYo(text.toLowerCase());
        const candidates = eddState.items.filter(i => !i.name.startsWith('Создать'));
        let match = candidates.find(i => normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase()) === target);
        if (!match) match = candidates.find(i => normYo(i.name.toLowerCase()).includes(target));
        if (!match) match = candidates.find(i => {
          const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
          return name.includes(target) || target.includes(name);
        });
        if (match) {
          await page.mouse.click(match.x, match.y);
          await waitForStable();
          await dismissPendingErrors();
          return { field: fieldName, ok: true, method: 'dropdown',
            value: match.name.replace(/\s*\([^)]*\)\s*$/, '') };
        }
        // No match in DLB dropdown — close and fall through to paste approach
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      } else if (eddState.visible) {
        // DLB opened a hint popup (no .eddText items) — close it before proceeding
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
    }
  } catch { /* DLB approach failed — fall through to paste */ }

  // 1. Focus (handle surface/modal overlay from previous interaction)
  await safeClick(selector, { dismissErrors: true });

  // 2. If field already has a value, clear using Shift+F4 (native 1C mechanism).
  //    This is needed for reference fields — Shift+F4 properly clears the ref link.
  const currentVal = await page.evaluate(`document.querySelector('${escapedSel}')?.value || ''`);
  if (currentVal) {
    await page.keyboard.press('Shift+F4');
    await page.waitForTimeout(500);
    await page.keyboard.press('Tab');
    await page.waitForTimeout(500);
    // Refocus
    await page.click(selector);
  }

  // 3. Paste text via clipboard (trusted event → triggers real 1C autocomplete)
  await pasteText(text);
  await page.waitForTimeout(2000);

  // 4. Check editDropDown for autocomplete suggestions
  const eddState = await readEdd();

  if (eddState.visible && eddState.items?.length > 0) {
    const target = normYo(text.toLowerCase());
    // Separate real matches from "Создать:" items
    const candidates = eddState.items.filter(i => !i.name.startsWith('Создать'));

    if (candidates.length > 0) {
      // Find best match (items have format "Name (Code)" — match against name part)
      let match = candidates.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name === target;
      });
      if (!match) match = candidates.find(i => normYo(i.name.toLowerCase()).includes(target));
      if (!match) match = candidates.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name.includes(target) || target.includes(name);
      });

      if (match) {
        await page.mouse.click(match.x, match.y);
        await waitForStable();
        await dismissPendingErrors(); // business logic errors (e.g. СПАРК) may appear async
        return { field: fieldName, ok: true, method: 'dropdown',
          value: match.name.replace(/\s*\([^)]*\)\s*$/, '') };
      }
      // Candidates exist but none match — report them
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await clearField();
      return { field: fieldName, error: 'not_matched',
        available: candidates.map(i => i.name.replace(/\s*\([^)]*\)\s*$/, '')) };
    }

    // Only "Создать:" items — no existing matches
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'No existing values match "' + text + '"' };
  }

  // 4b. No edd — check for "not in list" cloud that may have appeared during paste
  if (await checkNotInListCloud()) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (not in list)' };
  }

  // 5. No edd at all — press Tab to trigger direct resolve
  await page.keyboard.press('Tab');
  await waitForStable();
  await dismissPendingErrors();

  // 5x. Check for "not in list" cloud popup after Tab
  if (await checkNotInListCloud()) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (not in list)' };
  }

  // 5a. New form opened? (creation form = value not found)
  const newForm = await detectNewForm();
  if (newForm !== null) {
    await page.keyboard.press('Escape');
    await waitForStable();
    await clearField();
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found' };
  }

  // 5b. Dropdown after Tab?
  const popup = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popup) && popup.length > 0) {
    const realItems = popup.filter(i => !i.name.startsWith('Создать'));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    await clearField();
    if (realItems.length > 0) {
      return { field: fieldName, error: 'ambiguous',
        message: 'Multiple matches for "' + text + '"',
        available: realItems.map(i => i.name.replace(/\s*\([^)]*\)\s*$/, '')) };
    }
    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found' };
  }

  // 5c. Check final value
  const finalVal = await page.evaluate(`document.querySelector('${escapedSel}')?.value || ''`);
  if (!finalVal) {
    // 6. Last resort: try F4 to open selection form and pick from there
    try {
      await page.click(selector);
      await page.waitForTimeout(300);
    } catch { /* OK — field may be unfocused */ }
    await page.keyboard.press('F4');
    await page.waitForTimeout(ACTION_WAIT);

    const selFormNum = await detectNewForm();
    if (selFormNum !== null) {
      const pickResult = await pickFromSelectionForm(selFormNum, fieldName, text, formNum);
      if (pickResult.ok) return pickResult;
      // pickFromSelectionForm already closed the form on error
    }

    return { field: fieldName, error: 'not_found',
      message: 'Value "' + text + '" not found (field is empty)' };
  }

  return { field: fieldName, ok: true, method: 'typeahead', value: finalVal };
}


/** Fill fields on the current form via Playwright page.fill(). Returns fill results + updated form. */
export async function fillFields(fields) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('fillFields: no form found');

  // Resolve field names to element IDs
  const resolved = await page.evaluate(resolveFieldsScript(formNum, fields));
  const results = [];

  for (const r of resolved) {
    if (r.error) {
      results.push(r);
      continue;
    }
    // Auto-highlight the field input before filling
    if (highlightMode && r.inputId) {
      try {
        await page.evaluate(({ id }) => {
          const target = document.getElementById(id);
          if (!target) return;
          let div = document.getElementById('__web_test_highlight');
          if (!div) { div = document.createElement('div'); div.id = '__web_test_highlight'; document.body.appendChild(div); }
          const r = target.getBoundingClientRect();
          div.style.cssText = 'position:fixed;pointer-events:none;z-index:999998;top:' + (r.y-4) + 'px;left:' + (r.x-4) + 'px;width:' + (r.width+8) + 'px;height:' + (r.height+8) + 'px;outline:3px solid #e74c3c;border-radius:4px;box-shadow:0 0 16px #e74c3c80';
        }, { id: r.inputId });
        await page.waitForTimeout(500);
        await unhighlight();
      } catch {}
    }
    try {
      // Auto-enable DCS checkbox if resolved via label
      if (r.dcsCheckbox && !r.dcsCheckbox.checked) {
        await page.click(`[id="${r.dcsCheckbox.inputId}"]`);
        await waitForStable();
      }
      const selector = `[id="${r.inputId}"]`;
      // Clear field via Shift+F4 if value is empty (not applicable to checkbox/radio)
      const rawValue = fields[r.field];
      const isEmpty = rawValue === '' || rawValue === null || rawValue === undefined;
      if (isEmpty && !r.isCheckbox && !r.isRadio) {
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Shift+F4');
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: '', method: 'clear' });
        continue;
      }
      if (r.isCheckbox) {
        // Checkbox: compare desired with current, toggle if mismatch
        const desired = String(fields[r.field]).toLowerCase();
        const wantChecked = ['true', '1', 'да', 'yes', 'on'].includes(desired);
        if (wantChecked !== r.checked) {
          await page.click(selector);
          await waitForStable();
        }
        results.push({ field: r.field, ok: true, value: String(wantChecked), method: 'toggle' });
      } else if (r.isRadio) {
        // Radio button: find option by label (fuzzy match) and click it
        const desired = normYo(String(fields[r.field]).toLowerCase());
        const opt = r.options.find(o => normYo(o.label.toLowerCase()) === desired)
          || r.options.find(o => normYo(o.label.toLowerCase()).includes(desired));
        if (opt) {
          // Option 0 = base element (no suffix), options 1+ = #N#radio
          const radioId = opt.index === 0 ? r.inputId : `${r.inputId}#${opt.index}#radio`;
          await page.click(`[id="${radioId}"]`);
          await waitForStable();
          results.push({ field: r.field, ok: true, value: opt.label, method: 'radio' });
        } else {
          results.push({ field: r.field, error: 'option_not_found', available: r.options.map(o => o.label) });
        }
      } else if (r.hasSelect) {
        // Combobox/reference with DLB: DLB-first, then paste fallback
        const refResult = await fillReferenceField(selector, r.field, fields[r.field], formNum);
        results.push(refResult);
      } else if (r.hasPick && r.isDate) {
        // Date/time field with calendar CB — use paste (calendar is not a selection form)
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(fields[r.field]);
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: String(fields[r.field]), method: 'paste' });
      } else if (r.hasPick) {
        // Reference field with CB (non-editable or editable ref): delegate to selectValue (F4 → selection form)
        const svResult = await selectValue(r.field, String(fields[r.field]));
        if (svResult?.error) {
          results.push({ field: r.field, error: svResult.error, message: svResult.message });
        } else {
          results.push({ field: r.field, ok: true, value: svResult.value || String(fields[r.field]), method: svResult.method || 'form' });
        }
      } else {
        // Plain field: clipboard paste + Tab to commit
        // page.fill() sets DOM value but doesn't trigger 1C input events;
        // clipboard paste (Ctrl+V) is a trusted event that 1C processes correctly.
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(fields[r.field]);
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: String(fields[r.field]), method: 'paste' });
      }
    } catch (e) {
      results.push({ field: r.field, error: e.message });
    }
    if (highlightMode) try { await unhighlight(); } catch {}
  }

  const formData = await page.evaluate(readFormScript(formNum));
  const failed = results.filter(r => r.error);
  if (failed.length > 0) {
    const details = failed.map(f => `  ${f.field}: ${f.message || f.error}${f.available ? ' (available: ' + f.available.join(', ') + ')' : ''}`).join('\n');
    throw new Error(`fillFields: ${failed.length} of ${results.length} field(s) failed:\n${details}`);
  }
  return { filled: results, form: formData };
}

/** Convenience alias: fill a single field. Same as fillFields({ name: value }). */
export async function fillField(name, value) {
  return fillFields({ [name]: value });
}

/** Click a button/hyperlink/tab on the current form. Use {dblclick: true} to double-click (open items from lists).
 *  First argument can also be an object { row, column } to click a SpreadsheetDocument cell. */
export async function clickElement(text, { dblclick, table, toggle, expand, modifier, timeout } = {}) {
  ensureConnected();
  // Dispatch to spreadsheet cell handler when first arg is { row, column }
  if (typeof text === 'object' && text !== null && text.column != null) {
    await dismissPendingErrors();
    return clickSpreadsheetCell(text, { dblclick, modifier });
  }
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(text, { table }); await page.waitForTimeout(500); await unhighlight(); } catch {}
  let netMonitor = null;
  try {

  // First check if there's a confirmation dialog — click matching button
  const pending = await checkForErrors();
  if (pending?.confirmation) {
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
    if (btnResult?.error) throw new Error(`clickElement: "${text}" not found among confirmation buttons. Available: ${btnResult.available?.join(', ') || 'none'}`);
    await page.mouse.click(btnResult.x, btnResult.y);
    await waitForStable();
    const state = await getFormState();
    state.clicked = { kind: 'confirmation', name: btnResult.name };
    return state;
  }

  // Check if there's an open popup — if so, try to click inside it
  const popupItems = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popupItems) && popupItems.length > 0) {
    const target = normYo(text.toLowerCase());
    let found = popupItems.find(i => normYo(i.name.toLowerCase()) === target);
    if (!found) found = popupItems.find(i => normYo(i.name.toLowerCase()).includes(target));
    if (found) {
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
        const state = await getFormState();
        state.clicked = { kind: 'submenuArrow', name: found.name };
        if (Array.isArray(nestedItems)) {
          state.submenu = nestedItems.map(i => i.name);
          state.hint = 'Call web_click again with a submenu item name to select it';
        }
        return state;
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
      const state = await getFormState();
      state.clicked = { kind: 'popupItem', name: found.name };
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
    // No match in popup — fall through to form elements
  }

  let formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error(`clickElement: no form found`);

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`clickElement: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  // Find the target element ID
  let target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));

  // Retry: if not found, a modal form may still be loading (e.g. after F4).
  // Wait up to 2s for a new form to appear and re-detect.
  if (target?.error) {
    for (let retry = 0; retry < 4; retry++) {
      await page.waitForTimeout(500);
      const newForm = await page.evaluate(detectFormScript());
      if (newForm !== null && newForm !== formNum) {
        formNum = newForm;
        target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));
        if (!target?.error) break;
      }
    }
  }
  // Fallback: search spreadsheet iframes for text match before giving up
  if (target?.error) {
    const ssCell = await findSpreadsheetCellByText(formNum, text);
    if (ssCell) {
      const cx = ssCell.box.x + ssCell.box.width / 2;
      const cy = ssCell.box.y + ssCell.box.height / 2;
      const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
      if (modKey) await page.keyboard.down(modKey);
      if (dblclick) await page.mouse.dblclick(cx, cy);
      else await page.mouse.click(cx, cy);
      if (modKey) await page.keyboard.up(modKey);
      await waitForStable();
      const state = await getFormState();
      state.clicked = { kind: 'spreadsheetCell', name: ssCell.text, ...(dblclick ? { dblclick: true } : {}) };
      return state;
    }
    throw new Error(`clickElement: "${text}" not found. Available: ${target.available?.join(', ') || 'none'}`);
  }

  // Helper: click with optional modifier key (Ctrl/Shift for multi-select)
  const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
  async function modClick(x, y) {
    if (modKey) await page.keyboard.down(modKey);
    await page.mouse.click(x, y);
    if (modKey) await page.keyboard.up(modKey);
  }
  async function modDblClick(x, y) {
    if (modKey) await page.keyboard.down(modKey);
    await page.mouse.dblclick(x, y);
    if (modKey) await page.keyboard.up(modKey);
  }

  // Grid row targets — use coordinate click (single or double)
  if (target.kind === 'gridGroup' || target.kind === 'gridParent') {
    if (expand != null || toggle) {
      // Expand/collapse group in hierarchy mode — click the triangle icon (.gridListH/.gridListV).
      // expand=true: only expand (skip if already expanded), expand=false: only collapse, toggle: always click.
      const levelIconInfo = await getGridToggleIcon(target, formNum, {
        iconSelector: '.gridListH, .gridListV',
        isExpandedExpr: "icon.classList.contains('gridListV')",
      });
      const shouldClick = shouldClickToggle(levelIconInfo, expand, toggle);
      if (shouldClick) {
        if (levelIconInfo) {
          await modClick(levelIconInfo.x, levelIconInfo.y);
        } else {
          // Fallback: dblclick (standard hierarchy navigation)
          await modDblClick(target.x, target.y);
        }
      }
      await waitForStable(formNum);
      const state = await getFormState();
      state.clicked = { kind: target.kind, name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) };
      state.hint = shouldClick ? 'Group toggled. Use readTable to see updated list.' : 'Group already in desired state.';
      return state;
    }
    // Default: dblclick to enter group / go up to parent
    await modDblClick(target.x, target.y);
    await waitForStable(formNum);
    const state = await getFormState();
    state.clicked = { kind: target.kind, name: target.name, ...(modifier ? { modifier } : {}) };
    return state;
  }
  if (target.kind === 'gridTreeNode') {
    if (expand != null || toggle) {
      // Expand/collapse tree node — click the tree icon [tree="true"].
      // expand=true: only expand (skip if already expanded), expand=false: only collapse, toggle: always click.
      const treeIconInfo = await getGridToggleIcon(target, formNum, {
        iconSelector: '.gridBoxImg [tree="true"]',
        isExpandedExpr: '(icon.style.backgroundImage || "").includes("gx=0")',
      });
      const shouldClick = shouldClickToggle(treeIconInfo, expand, toggle);
      if (shouldClick) {
        if (treeIconInfo) {
          await modClick(treeIconInfo.x, treeIconInfo.y);
        } else {
          // Fallback: dblclick on row (works for trees without clickable +/- icons)
          await modDblClick(target.x, target.y);
        }
      }
      await waitForStable(formNum);
      const state = await getFormState();
      state.clicked = { kind: 'gridTreeNode', name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) };
      state.hint = shouldClick ? 'Tree node toggled. Use readTable to see updated tree.' : 'Tree node already in desired state.';
      return state;
    }
    // Default: select row (click text, no expand/collapse)
    await modClick(target.x, target.y);
    await waitForStable(formNum);
    const state = await getFormState();
    state.clicked = { kind: 'gridTreeNode', name: target.name, ...(modifier ? { modifier } : {}) };
    state.hint = 'Row selected. Use { expand: true } to expand/collapse.';
    return state;
  }
  if (target.kind === 'gridRow') {
    if (dblclick) {
      await modDblClick(target.x, target.y);
      await waitForStable();
      const state = await getFormState();
      state.clicked = { kind: 'gridRow', name: target.name, dblclick: true, ...(modifier ? { modifier } : {}) };
      return state;
    }
    await modClick(target.x, target.y);
    await waitForStable();
    const state = await getFormState();
    state.clicked = { kind: 'gridRow', name: target.name, ...(modifier ? { modifier } : {}) };
    return state;
  }

  // Start CDP network monitor BEFORE the click for buttons —
  // so we capture all server requests triggered by the click.
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

  // If submenu button — read popup items and return them as hints
  if (target.kind === 'submenu') {
    await page.waitForTimeout(ACTION_WAIT);
    const submenuItems = await page.evaluate(readSubmenuScript());
    const state = await getFormState();
    state.clicked = { kind: 'submenu', name: target.name };
    if (Array.isArray(submenuItems)) {
      state.submenu = submenuItems.map(i => i.name);
      state.hint = 'Call web_click again with a submenu item name to select it';
    }
    return state;
  }

  await waitForStable(formNum);

  // Check if the click opened a popup/submenu (split buttons like "Создать на основании")
  const openedPopup = await page.evaluate(readSubmenuScript());
  if (Array.isArray(openedPopup) && openedPopup.length > 0) {
    const state = await getFormState();
    state.clicked = { kind: 'submenu', name: target.name };
    state.submenu = openedPopup.map(i => i.name);
    state.hint = 'Call web_click again with a submenu item name to select it';
    return state;
  }

  // For buttons that trigger server-side operations (post, write, etc.),
  // the DOM may stabilize BEFORE the server response arrives.
  // Use waitForSelector to detect error modal — this doesn't block the JS event loop.
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
        // Form didn't change — server might still be processing.
        // CDP monitor was started before click — wait for all requests to complete
        // (300ms debounce) or for a modal/balloon/confirm to appear.
        await netMonitor.waitDone(timeout);
        await waitForStable();
      }
    }
  }

  // Form may have changed — re-detect
  const state = await getFormState();
  state.clicked = { kind: target.kind, name: target.name };
  const err = await checkForErrors();
  if (err) {
    state.errors = err;
    if (err.confirmation) {
      state.confirmation = err.confirmation;
      state.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
  }
  return state;

  } finally {
    if (netMonitor) try { await netMonitor.cleanup(); } catch {}
    if (highlightMode) try { await unhighlight(); } catch {}
  }
}

/**
 * Close the current form/dialog via Escape.
 * @param {Object} [opts]
 * @param {boolean} [opts.save] - Handle "Save changes?" confirmation automatically:
 *   true  → click "Да" (save and close)
 *   false → click "Нет" (discard and close)
 *   undefined → return confirmation as hint for caller to decide
 */
export async function closeForm({ save } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  // If platform dialogs are open, close them instead of pressing Escape
  const pd = await _detectPlatformDialogs();
  if (pd.length) {
    await _closePlatformDialogs();
    await page.waitForTimeout(300);
    const state = await getFormState();
    state.closed = true;
    state.closedPlatformDialogs = pd;
    return state;
  }
  const beforeForm = await page.evaluate(detectFormScript());
  await page.keyboard.press('Escape');
  await waitForStable(beforeForm);
  const state = await getFormState();
  const err = await checkForErrors();
  if (err?.confirmation) {
    if (save === true || save === false) {
      const label = save ? 'Да' : 'Нет';
      const btnSel = `#form${err.confirmation.formNum}_container a.press.pressButton`;
      const btns = await page.$$(btnSel);
      for (const b of btns) {
        const txt = (await b.textContent()).trim();
        if (txt === label) {
          if (recorder) await page.waitForTimeout(500); // show confirmation to viewer during recording
          await b.click({ force: true });
          await waitForStable(beforeForm);
          break;
        }
      }
      const afterState = await getFormState();
      afterState.closed = afterState.form !== beforeForm;
      return afterState;
    }
    state.confirmation = err.confirmation;
    state.hint = 'Confirmation dialog shown. Click "Да" to confirm or "Нет" to cancel';
    return state;
  }
  state.closed = state.form !== beforeForm;
  return state;
}

/**
 * Select a value from a reference field (compound operation).
 * Handles three patterns:
 *   A) DLB opens an inline dropdown popup — click matching item
 *   B) DLB opens dropdown with history — click "Показать все" or F4 to open selection form
 *   C) DLB opens a separate selection form directly — search + dblclick in grid
 */
export async function selectValue(fieldName, searchText, { type } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error(`selectValue: no form found`);

  // 1. Find DLB button (fallback to CB — ERP uses Choose Button instead of DLB for some fields)
  let btn = await page.evaluate(findFieldButtonScript(formNum, fieldName, 'DLB'));
  if (btn?.error === 'button_not_found') {
    btn = await page.evaluate(findFieldButtonScript(formNum, fieldName, 'CB'));
  }
  if (btn?.error) return btn;
  if (highlightMode) try { await highlight(fieldName); await page.waitForTimeout(500); await unhighlight(); } catch {}
  try {

  // === CLEAR FIELD if searchText is empty/null ===
  if (!searchText && searchText !== 0) {
    const inputId = await findFieldInputId(formNum, btn.fieldName);
    if (inputId) {
      await page.click(`[id="${inputId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await waitForStable();
    }
    if (highlightMode) try { await unhighlight(); } catch {}
    const formData = await getFormState();
    return { ...formData, selected: { field: fieldName, search: null, method: 'clear' } };
  }

  // === COMPOSITE TYPE HANDLING ===
  // When `type` is specified, clear the field first to reset cached type,
  // then open type selection dialog, pick the type, then pick the value.
  if (type) {
    // Find and focus the field input
    const inputId = await findFieldInputId(formNum, btn.fieldName);
    if (!inputId) throw new Error(`selectValue: field "${btn.fieldName}" input not found`);

    // Clear cached type + value with Shift+F4
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
    await page.keyboard.press('Shift+F4');
    await page.waitForTimeout(500);

    // Re-focus and press F4 to open type selection dialog
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
    await page.keyboard.press('F4');
    await page.waitForTimeout(ACTION_WAIT);
    await waitForStable(formNum);

    const newFormNum = await detectNewForm();
    if (newFormNum === null) {
      throw new Error(`selectValue: F4 for composite field "${btn.fieldName}" did not open type selection dialog`);
    }

    if (await isTypeDialog(newFormNum)) {
      // Pick type from the dialog
      await pickFromTypeDialog(newFormNum, type);
      await waitForStable(newFormNum);

      // After type selection, the actual selection form should open
      const selFormNum = await detectSelectionForm();
      if (selFormNum === null) {
        throw new Error(`selectValue: after selecting type "${type}", no selection form opened for "${btn.fieldName}"`);
      }

      const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: searchText || null, type, method: 'form' };
      if (pickResult.error) state.selected.error = pickResult.error;
      if (pickResult.message) state.selected.message = pickResult.message;
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    } else {
      // Not a type dialog — field is not composite type, proceed with normal selection
      const pickResult = await pickFromSelectionForm(newFormNum, btn.fieldName, searchText || '', formNum);
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
      if (pickResult.error) state.selected.error = pickResult.error;
      if (pickResult.message) state.selected.message = pickResult.message;
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
  }
  // === END COMPOSITE TYPE HANDLING ===

  // Auto-enable DCS checkbox if resolved via label
  if (btn.dcsCheckbox) {
    const cbSel = `[id="${btn.dcsCheckbox.inputId}"]`;
    const isChecked = await page.$eval(cbSel, el =>
      el.classList.contains('checked') || el.classList.contains('checkboxOn') || el.classList.contains('select'));
    if (!isChecked) { await page.click(cbSel); await waitForStable(); }
  }

  // Helper: detect selection form (form number > formNum)
  async function detectSelectionForm() {
    return page.evaluate(`(() => {
      const forms = {};
      document.querySelectorAll('input.editInput[id], a.press[id]').forEach(el => {
        if (el.offsetWidth === 0) return;
        const m = el.id.match(/^form(\\d+)_/);
        if (m) forms[m[1]] = true;
      });
      const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
      return nums.length > 0 ? Math.max(...nums) : null;
    })()`);
  }

  // Helper: detect any new form (broad — finds type dialogs whose a.press
  // buttons have empty IDs). Looks for any visible element with id="form{N}_*".
  const detectNewForm = () => helperDetectNewForm(formNum);

  // Helper: open selection form and pick value
  async function openFormAndPick() {
    await waitForStable(formNum);
    const selFormNum = await detectSelectionForm();
    if (selFormNum !== null) {
      const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
      if (pickResult.error) state.selected.error = pickResult.error;
      if (pickResult.message) state.selected.message = pickResult.message;
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
    return null;
  }

  // Helper: click EDD item via evaluate (bypasses div.surface overlay from DLB)
  // page.mouse.click() doesn't work here — surface intercepts pointer events.
  // Dispatching mousedown directly on the element avoids this.
  async function clickEddItem(itemName) {
    return page.evaluate(`(() => {
      const edd = document.getElementById('editDropDown');
      if (!edd || edd.offsetWidth === 0) return null;
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const target = ny(${JSON.stringify(itemName.toLowerCase())});
      const items = [...edd.querySelectorAll('.eddText')].filter(el => el.offsetWidth > 0);
      function clickEl(el) {
        const r = el.getBoundingClientRect();
        const opts = { bubbles: true, cancelable: true, clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
        el.dispatchEvent(new MouseEvent('mousedown', opts));
        el.dispatchEvent(new MouseEvent('mouseup', opts));
        el.dispatchEvent(new MouseEvent('click', opts));
        return el.innerText.trim();
      }
      // Pass 1: exact match (prefer over partial)
      for (const el of items) {
        const t = ny((el.innerText?.trim() || '').toLowerCase());
        if (t === target) return clickEl(el);
        const stripped = t.replace(/\\s*\\([^)]*\\)\\s*$/, '');
        if (stripped === target) return clickEl(el);
      }
      // Pass 2: partial match
      for (const el of items) {
        const t = ny((el.innerText?.trim() || '').toLowerCase());
        if (t.includes(target) || target.includes(t.replace(/\\s*\\([^)]*\\)\\s*$/, ''))) return clickEl(el);
      }
      return null;
    })()`);
  }

  // Helper: click "Показать все" in EDD footer via evaluate
  async function clickShowAll() {
    return page.evaluate(`(() => {
      const edd = document.getElementById('editDropDown');
      if (!edd || edd.offsetWidth === 0) return false;
      let el = edd.querySelector('.eddBottom .hyperlink');
      if (!el || el.offsetWidth === 0) {
        const candidates = [...edd.querySelectorAll('span, div, a')]
          .filter(e => e.offsetWidth > 0 && e.children.length === 0);
        el = candidates.find(e => {
          const t = (e.innerText?.trim() || '').toLowerCase();
          return t === 'показать все' || t === 'show all';
        });
      }
      if (!el) return false;
      const r = el.getBoundingClientRect();
      const opts = { bubbles: true, cancelable: true, clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
      el.dispatchEvent(new MouseEvent('mousedown', opts));
      el.dispatchEvent(new MouseEvent('mouseup', opts));
      el.dispatchEvent(new MouseEvent('click', opts));
      return true;
    })()`);
  }

  // 2. Click DLB (handle funcPanel / surface overlay intercept)
  const dlbSel = `[id="${btn.buttonId}"]`;
  await safeClick(dlbSel, { timeout: 5000 });
  await page.waitForTimeout(ACTION_WAIT);

  // 3A. Check if a dropdown popup appeared (inline quick selection)
  const popupItems = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popupItems) && popupItems.length > 0) {
    const regularItems = popupItems.filter(i => i.kind !== 'showAll');
    const showAllItem = popupItems.find(i => i.kind === 'showAll');

    if (searchText) {
      const target = normYo(searchText.toLowerCase());
      // Try to find match among regular dropdown items
      let match = regularItems.find(i => normYo(i.name.toLowerCase()) === target);
      if (!match) match = regularItems.find(i => normYo(i.name.toLowerCase()).includes(target));
      if (!match) match = regularItems.find(i => {
        const name = normYo(i.name.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase());
        return name === target || name.includes(target) || target.includes(name);
      });

      if (match) {
        // Click via evaluate to bypass div.surface overlay
        await clickEddItem(match.name);
        await waitForStable();
        const state = await getFormState();
        state.selected = { field: btn.fieldName, search: searchText, method: 'dropdown' };
        const err = await checkForErrors();
        if (err) state.errors = err;
        return state;
      }

      // No match in dropdown — try "Показать все" to open selection form
      if (showAllItem) {
        await clickShowAll();
        const formResult = await openFormAndPick();
        if (formResult) return formResult;
      }

      // No "Показать все" — close dropdown, try F4
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);

      // Focus the field input and press F4 to open selection form
      const inputId = await findFieldInputId(formNum, btn.fieldName);
      if (inputId) {
        await page.click(`[id="${inputId}"]`);
        await page.waitForTimeout(300);
      }
      await page.keyboard.press('F4');
      await page.waitForTimeout(ACTION_WAIT);

      const formResult = await openFormAndPick();
      if (formResult) return formResult;

      // Still nothing — report available items from original dropdown
      throw new Error(`selectValue: "${searchText}" not found for field "${btn.fieldName}". Available: ${regularItems.map(i => i.name).join(', ') || 'none'}`);
    }

    // No search text — click first regular item
    if (regularItems.length > 0) {
      await clickEddItem(regularItems[0].name);
      await waitForStable();
      const state = await getFormState();
      state.selected = { field: btn.fieldName, search: null, picked: regularItems[0].name, method: 'dropdown' };
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
  }

  // 3B. Check if a new selection form opened directly (use broad detection to also catch type dialogs)
  const selFormNum = await detectNewForm();
  if (selFormNum !== null) {
    // Auto-detect type selection dialog when `type` was not specified
    if (await isTypeDialog(selFormNum)) {
      await page.keyboard.press('Escape');
      await waitForStable();
      throw new Error(`selectValue: field "${btn.fieldName}" opened a type selection dialog — this is a composite-type field. Specify the type: selectValue('${btn.fieldName}', '${searchText || ''}', { type: 'ИмяТипа' })`);
    }
    const pickResult = await pickFromSelectionForm(selFormNum, btn.fieldName, searchText || '', formNum);
    const state = await getFormState();
    state.selected = { field: btn.fieldName, search: searchText || null, method: 'form' };
    if (pickResult.error) state.selected.error = pickResult.error;
    if (pickResult.message) state.selected.message = pickResult.message;
    const err = await checkForErrors();
    if (err) state.errors = err;
    return state;
  }

  // 3C. Neither popup nor form — try F4 as last resort
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);

  const inputId = await findFieldInputId(formNum, btn.fieldName);
  if (inputId) {
    await page.click(`[id="${inputId}"]`);
    await page.waitForTimeout(300);
  }
  await page.keyboard.press('F4');
  await page.waitForTimeout(ACTION_WAIT);

  const formResult = await openFormAndPick();
  if (formResult) return formResult;

  throw new Error(`selectValue: DLB click for "${btn.fieldName}" did not open a popup or selection form`);

  } finally { if (highlightMode) try { await unhighlight(); } catch {} }
}

/**
 * Fill cells in the current table row via Tab navigation.
 * Grid cells are only accessible sequentially (Tab) — no random access.
 *
 * After "Добавить", 1C enters inline edit mode on the first cell.
 * All inputs in the row are created hidden (offsetWidth=0); only the active one is visible.
 * Tab moves through cells in a fixed order determined by the form configuration.
 *
 * @param {Object} fields - { fieldName: value } map (fuzzy match: "Номенклатура" → "ТоварыНоменклатура")
 * @param {Object} [options]
 * @param {string} [options.tab] - Switch to this form tab before operating
 * @param {boolean} [options.add] - Click "Добавить" to create a new row first
 * @returns {{ filled[], notFilled[]?, form }}
 */
export async function fillTableRow(fields, { tab, add, row, table } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('fillTableRow: no form found');

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`fillTableRow: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  try {
  // 1. Switch tab if requested
  if (tab) {
    await clickElement(tab);
  }

  // 2. Add new row if requested
  let addedRowIdx = -1;
  if (add) {
    // Count rows before add — new row will be appended at this index
    addedRowIdx = await page.evaluate(`(() => {
      const grid = ${gridSelector
        ? `document.querySelector(${JSON.stringify(gridSelector)})`
        : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
      const body = grid?.querySelector('.gridBody');
      return body ? body.querySelectorAll('.gridLine').length : 0;
    })()`);
    await clickElement('Добавить', { table });
    // Poll for edit mode (INPUT inside grid) instead of fixed 1000ms wait
    for (let aw = 0; aw < 6; aw++) {
      await page.waitForTimeout(150);
      const ready = await page.evaluate(`(() => {
        const f = document.activeElement;
        if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
        let n = f; while (n) { if (n.classList?.contains('grid')) return true; n = n.parentElement; }
        return false;
      })()`);
      if (ready) break;
    }
  }

  // 2b. Enter edit mode on existing row by dblclick
  if (row != null) {
    // Sort fields by colindex (leftmost first) so Tab traversal covers all fields left-to-right
    const sortedKeys = await page.evaluate(`(() => {
      const grid = ${gridSelector
        ? `document.querySelector(${JSON.stringify(gridSelector)})`
        : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
      if (!grid) return null;
      const head = grid.querySelector('.gridHead');
      if (!head) return null;
      const headLine = head.querySelector('.gridLine') || head;
      const cols = [];
      [...headLine.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const t = ((box.querySelector('.gridBoxText') || box).innerText?.trim() || '').toLowerCase();
        const ci = parseInt(box.getAttribute('colindex') || '-1');
        if (t) cols.push({ text: t, colindex: ci });
      });
      const keys = ${JSON.stringify(Object.keys(fields).map(k => k.toLowerCase()))};
      const mapped = keys.map(k => {
        const exact = cols.find(c => c.text === k);
        if (exact) return { key: k, colindex: exact.colindex };
        const inc = cols.find(c => c.text.includes(k) || k.includes(c.text));
        return { key: k, colindex: inc ? inc.colindex : 999 };
      });
      mapped.sort((a, b) => a.colindex - b.colindex);
      return mapped.map(m => m.key);
    })()`);
    if (sortedKeys) {
      // Rebuild fields in sorted order
      const sortedFields = {};
      for (const kl of sortedKeys) {
        const origKey = Object.keys(fields).find(k => k.toLowerCase() === kl);
        if (origKey) sortedFields[origKey] = fields[origKey];
      }
      // Add any keys not matched in header (preserve original order for those)
      for (const k of Object.keys(fields)) {
        if (!(k in sortedFields)) sortedFields[k] = fields[k];
      }
      fields = sortedFields;
    }

    const fieldKeys = JSON.stringify(Object.keys(fields).map(k => k.toLowerCase()));
    const cellCoords = await page.evaluate(`(() => {
      const grid = ${gridSelector
        ? `document.querySelector(${JSON.stringify(gridSelector)})`
        : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
      if (!grid) return { error: 'no_grid' };
      const head = grid.querySelector('.gridHead');
      const body = grid.querySelector('.gridBody');
      if (!head || !body) return { error: 'no_grid_body' };

      // Read column headers to find target colindex
      const headLine = head.querySelector('.gridLine') || head;
      const cols = [];
      [...headLine.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const t = box.querySelector('.gridBoxText');
        const ci = box.getAttribute('colindex');
        cols.push({ colindex: ci, text: ((t || box).innerText?.trim() || '').toLowerCase() });
      });

      const keys = ${fieldKeys};
      let targetColindex = null;
      for (const key of keys) {
        const exact = cols.find(c => c.text === key);
        if (exact) { targetColindex = exact.colindex; break; }
        const inc = cols.find(c => c.text.includes(key) || key.includes(c.text));
        if (inc) { targetColindex = inc.colindex; break; }
      }

      const rows = [...body.querySelectorAll('.gridLine')];
      if (${row} >= rows.length) return { error: 'row_out_of_range', total: rows.length };
      const line = rows[${row}];

      // Find body cell by colindex (reliable across merged headers)
      let box = null;
      if (targetColindex != null) {
        box = [...line.children].find(b => b.offsetWidth > 0 && b.getAttribute('colindex') === targetColindex);
      }
      // Fallback: second visible box (skip checkbox/N column)
      if (!box) {
        const boxes = [...line.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
        box = boxes.length > 1 ? boxes[1] : boxes[0];
      }
      if (!box) return { error: 'no_cell' };
      // Scroll into view if off-screen
      box.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      const cell = box.querySelector('.gridBoxText') || box;
      const r = cell.getBoundingClientRect();
      const currentText = (cell.innerText?.trim() || '').replace(/\\u00a0/g, ' ');
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), currentText };
    })()`);

    if (cellCoords.error) throw new Error(`fillTableRow: ${cellCoords.error}${cellCoords.total ? ' (total rows: ' + cellCoords.total + ')' : ''}`);

    // Skip if cell already contains the desired value (single-field optimization)
    const firstKey0 = Object.keys(fields)[0];
    const rawFirstVal = fields[firstKey0];
    const firstVal0 = rawFirstVal === null || rawFirstVal === undefined || rawFirstVal === ''
      ? '' : (typeof rawFirstVal === 'object' ? rawFirstVal.value : String(rawFirstVal));
    let firstFieldSkipped = false;
    if (cellCoords.currentText && firstVal0 &&
        cellCoords.currentText.toLowerCase().includes(firstVal0.toLowerCase())) {
      firstFieldSkipped = true;
      if (Object.keys(fields).length === 1) {
        return [{ field: firstKey0, ok: true, method: 'skip', value: cellCoords.currentText }];
      }
    }

    // Click first (tree grids enter edit on single click; dblclick toggles expand/collapse).
    // Then escalate: dblclick → F4 if needed.
    await page.mouse.click(cellCoords.x, cellCoords.y);

    // Clear cell via Shift+F4 if value is empty
    if (firstVal0 === '') {
      await page.waitForTimeout(500);
      // Check if click opened a selection form — close it first
      let openedForm = await page.evaluate(`(() => {
        const forms = {};
        document.querySelectorAll('[id]').forEach(el => {
          if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
          const m = el.id.match(/^form(\\d+)_/);
          if (m) forms[m[1]] = true;
        });
        const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
        return nums.length > 0 ? Math.max(...nums) : null;
      })()`);
      if (openedForm !== null) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
      } else {
        // No form opened — need to enter edit mode first (dblclick), then close any form that opens
        await page.mouse.dblclick(cellCoords.x, cellCoords.y);
        await page.waitForTimeout(500);
        openedForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (openedForm !== null) {
          await page.keyboard.press('Escape');
          await page.waitForTimeout(500);
        }
      }
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      const results = [{ field: firstKey0, ok: true, method: 'clear', value: '' }];
      // If more fields remain, process them on the same row
      const remaining = { ...fields };
      delete remaining[firstKey0];
      if (Object.keys(remaining).length > 0) {
        const more = await fillTableRow(remaining, { row, table });
        if (Array.isArray(more)) results.push(...more);
        else if (more?.filled) results.push(...more.filled);
      }
      const formData = await getFormState();
      return { filled: results, form: formData };
    }

    // Check if clicked cell is a checkbox (toggle-on-click, no edit mode)
    const checkboxInfo = await page.evaluate(`(() => {
      const el = document.elementFromPoint(${cellCoords.x}, ${cellCoords.y});
      const cell = el?.closest('.gridBox');
      if (!cell) return null;
      const chk = cell.querySelector('.checkbox');
      if (!chk) return null;
      const r = chk.getBoundingClientRect();
      return { checked: chk.classList.contains('select'), x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) };
    })()`);
    if (checkboxInfo !== null) {
      // Checkbox cell found — click directly on the checkbox icon (not cell center)
      const desired = ['true', 'да', '1', 'yes'].includes(String(firstVal0).toLowerCase().trim());
      if (checkboxInfo.checked !== desired) {
        await page.mouse.click(checkboxInfo.x, checkboxInfo.y);
        await page.waitForTimeout(300);
      }
      const results = [{ field: firstKey0, ok: true, method: 'toggle', value: desired }];
      await waitForStable(formNum);
      // If more fields remain, process them on the same row
      const remaining = { ...fields };
      delete remaining[firstKey0];
      if (Object.keys(remaining).length > 0) {
        const more = await fillTableRow(remaining, { row, table });
        results.push(...more);
      }
      return results;
    }

    let inEdit = false;
    let directEditForm = null;
    for (let dw = 0; dw < 4; dw++) {
      await page.waitForTimeout(150);
      inEdit = await page.evaluate(`(() => {
        const f = document.activeElement;
        return f && f.tagName === 'INPUT';
      })()`);
      if (inEdit) break;
      directEditForm = await page.evaluate(`(() => {
        const forms = {};
        document.querySelectorAll('[id]').forEach(el => {
          if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
          const m = el.id.match(/^form(\\d+)_/);
          if (m) forms[m[1]] = true;
        });
        const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
        return nums.length > 0 ? Math.max(...nums) : null;
      })()`);
      if (directEditForm !== null) break;
    }
    // Click didn't enter edit — try dblclick (works for flat grids)
    if (!inEdit && directEditForm === null) {
      await page.mouse.dblclick(cellCoords.x, cellCoords.y);
      for (let dw = 0; dw < 4; dw++) {
        await page.waitForTimeout(150);
        inEdit = await page.evaluate(`(() => {
          const f = document.activeElement;
          return f && f.tagName === 'INPUT';
        })()`);
        if (inEdit) break;
        directEditForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (directEditForm !== null) break;
      }
    }
    // Still nothing — try F4 (opens selection for direct-edit cells)
    if (!inEdit && directEditForm === null) {
      await page.keyboard.press('F4');
      for (let fw = 0; fw < 8; fw++) {
        await page.waitForTimeout(200);
        inEdit = await page.evaluate(`(() => {
          const f = document.activeElement;
          return f && f.tagName === 'INPUT';
        })()`);
        if (inEdit) break;
        directEditForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (directEditForm !== null) break;
      }
    }

    // When click entered INPUT mode but no selection form yet — try F4 only for tree grids
    // (tree grid ref fields need F4 to open selection form; flat grids work via Tab-loop)
    if (inEdit && directEditForm === null) {
      const isTreeGrid = await page.evaluate(`(() => {
        const grid = ${gridSelector
          ? `document.querySelector(${JSON.stringify(gridSelector)})`
          : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
        return grid ? !!grid.querySelector('.gridBoxTree') : false;
      })()`);
      if (isTreeGrid) {
        await page.keyboard.press('F4');
        for (let fw = 0; fw < 8; fw++) {
          await page.waitForTimeout(200);
          directEditForm = await page.evaluate(`(() => {
            const forms = {};
            document.querySelectorAll('[id]').forEach(el => {
              if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
              const m = el.id.match(/^form(\\d+)_/);
              if (m) forms[m[1]] = true;
            });
            const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
            return nums.length > 0 ? Math.max(...nums) : null;
          })()`);
          if (directEditForm !== null) break;
        }
        // If F4 didn't open a selection form, fall through to Tab loop
      }
    }

    // Direct-edit mode: selection form opened on dblclick/F4 (e.g. tree grid with immediate editing).
    // Handle each field by picking from selection form, then dblclick next cell.
    if (directEditForm !== null) {
      const pending = new Map();
      for (const [key, val] of Object.entries(fields)) {
        if (val && typeof val === 'object' && 'value' in val) {
          pending.set(key, { value: String(val.value), type: val.type || null, filled: false });
        } else {
          pending.set(key, { value: String(val), type: null, filled: false });
        }
      }
      const results = [];

      // Helper: handle type dialog + pick from selection form
      async function directEditPick(openedForm, key, info) {
        let selForm = openedForm;
        // Check if opened form is a type selection dialog (composite type field)
        if (await isTypeDialog(selForm)) {
          if (info.type) {
            await pickFromTypeDialog(selForm, info.type);
            await waitForStable(selForm);
            // After type selection, detect the actual selection form
            selForm = await page.evaluate(`(() => {
              const forms = {};
              document.querySelectorAll('[id]').forEach(el => {
                if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
                const m = el.id.match(/^form(\\d+)_/);
                if (m) forms[m[1]] = true;
              });
              const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
              return nums.length > 0 ? Math.max(...nums) : null;
            })()`);
            if (selForm === null) {
              return { field: key, error: 'no_selection_after_type', message: `Type selected but no selection form opened for "${key}"` };
            }
          } else {
            // No type specified — close type dialog and report error
            await page.keyboard.press('Escape');
            await page.waitForTimeout(300);
            return { field: key, error: 'composite_type', message: `Composite type field "${key}" requires {value, type}` };
          }
        }
        const pr = await pickFromSelectionForm(selForm, key, info.value, formNum);
        return pr.ok ? { field: key, ok: true, method: 'form' } : { field: key, error: pr.error, message: pr.message };
      }

      // First field: selection form is already open from the dblclick above
      const firstKey = Object.keys(fields)[0];
      const firstInfo = pending.get(firstKey);
      if (firstFieldSkipped) {
        firstInfo.filled = true;
        results.push({ field: firstKey, ok: true, method: 'skip', value: cellCoords.currentText });
        // Close the selection form that opened from the click
        await page.keyboard.press('Escape');
        await waitForStable(formNum);
      } else {
        const pickResult = await directEditPick(directEditForm, firstKey, firstInfo);
        firstInfo.filled = true;
        results.push(pickResult);
      }

      // Remaining fields: dblclick on each column cell individually
      for (const [key, info] of pending) {
        if (info.filled) continue;
        // Find column for this key and dblclick on it
        const nextCoords = await page.evaluate(`(() => {
          const grid = ${gridSelector
            ? `document.querySelector(${JSON.stringify(gridSelector)})`
            : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
          if (!grid) return null;
          const head = grid.querySelector('.gridHead');
          const body = grid.querySelector('.gridBody');
          if (!head || !body) return null;
          const headLine = head.querySelector('.gridLine') || head;
          const cols = [];
          [...headLine.children].forEach(box => {
            if (box.offsetWidth === 0) return;
            const t = box.querySelector('.gridBoxText');
            const ci = box.getAttribute('colindex');
            cols.push({ colindex: ci, text: ((t || box).innerText?.trim() || '').toLowerCase() });
          });
          const kl = ${JSON.stringify(key.toLowerCase())};
          const klNoSpace = kl.replace(/[\\s\\-]+/g, '');
          let targetColindex = null;
          const exact = cols.find(c => c.text === kl);
          if (exact) targetColindex = exact.colindex;
          else {
            const inc = cols.find(c => c.text.includes(kl) || kl.includes(c.text)
              || c.text.includes(klNoSpace) || klNoSpace.includes(c.text));
            if (inc) targetColindex = inc.colindex;
          }
          if (targetColindex == null) return null;
          const rows = [...body.querySelectorAll('.gridLine')];
          if (${row} >= rows.length) return null;
          const line = rows[${row}];
          const box = [...line.children].find(b => b.offsetWidth > 0 && b.getAttribute('colindex') === targetColindex);
          if (!box) return null;
          box.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          const cell = box.querySelector('.gridBoxText') || box;
          const r = cell.getBoundingClientRect();
          const currentText = (cell.innerText?.trim() || '').replace(/\\u00a0/g, ' ');
          return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), currentText };
        })()`);
        if (!nextCoords) {
          info.filled = true;
          results.push({ field: key, error: 'column_not_found', message: `Column for "${key}" not found` });
          continue;
        }
        // Skip if cell already contains the desired value
        if (nextCoords.currentText && info.value &&
            nextCoords.currentText.toLowerCase().includes(info.value.toLowerCase())) {
          info.filled = true;
          results.push({ field: key, ok: true, method: 'skip', value: nextCoords.currentText });
          continue;
        }
        await page.mouse.dblclick(nextCoords.x, nextCoords.y);
        await page.waitForTimeout(300);
        // Check if dblclick entered INPUT mode (plain text/numeric field) — before F4 which may open calculator
        const inInputAfterDblclick = await page.evaluate(`(() => {
          const f = document.activeElement;
          if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
          let n = f; while (n) { if (n.classList?.contains('grid')) return true; n = n.parentElement; }
          return false;
        })()`);
        // Also check if a selection form already appeared
        let selForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (selForm === null && inInputAfterDblclick) {
          // Plain text/numeric field — fill via clipboard paste
          await pasteText(info.value, { confirm: ['Control+a', 'Control+v'] });
          await page.waitForTimeout(400);
          // Dismiss EDD autocomplete if it appeared
          const hasEdd = await page.evaluate(`(() => {
            const edd = document.getElementById('editDropDown');
            return edd && edd.offsetWidth > 0;
          })()`);
          if (hasEdd) {
            await page.keyboard.press('Escape');
            await page.waitForTimeout(200);
          }
          info.filled = true;
          results.push({ field: key, ok: true, method: 'paste' });
          continue;
        }
        // Poll for selection form (with F4 fallback if dblclick didn't open it)
        if (selForm === null) {
          for (let attempt = 0; attempt < 2 && selForm === null; attempt++) {
            if (attempt === 1) await page.keyboard.press('F4'); // F4 fallback
            for (let sw = 0; sw < 6; sw++) {
              await page.waitForTimeout(200);
              selForm = await page.evaluate(`(() => {
                const forms = {};
                document.querySelectorAll('[id]').forEach(el => {
                  if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
                  const m = el.id.match(/^form(\\d+)_/);
                  if (m) forms[m[1]] = true;
                });
                const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
                return nums.length > 0 ? Math.max(...nums) : null;
              })()`);
              if (selForm !== null) break;
            }
          }
        }
        if (selForm === null) {
          info.filled = true;
          results.push({ field: key, error: 'no_selection_form', message: `Dblclick on "${key}" did not open selection form` });
          continue;
        }
        const pr = await directEditPick(selForm, key, info);
        info.filled = true;
        results.push(pr);
      }
      // Commit the edit: click on a different row (Escape cancels in tree grids).
      // Find the first visible row that is NOT the edited row and click it.
      const commitCoords = await page.evaluate(`(() => {
        const grid = ${gridSelector
          ? `document.querySelector(${JSON.stringify(gridSelector)})`
          : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
        if (!grid) return null;
        const body = grid.querySelector('.gridBody');
        if (!body) return null;
        const rows = [...body.querySelectorAll('.gridLine')];
        const otherIdx = ${row} === 0 ? 1 : 0;
        const other = rows[otherIdx];
        if (!other) return null;
        const visBoxes = [...other.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
        const box = visBoxes.length > 1 ? visBoxes[1] : visBoxes[0];
        if (!box) return null;
        const r = box.getBoundingClientRect();
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
      })()`);
      if (commitCoords) {
        await page.mouse.click(commitCoords.x, commitCoords.y);
      } else {
        await page.keyboard.press('Escape');
      }
      await waitForStable(formNum);
      return results;
    }

    if (!inEdit) throw new Error(`fillTableRow: click on row ${row} did not enter edit mode`);
  } else {
    // No row specified — verify we're in grid edit mode (active INPUT inside a .grid or .gridContent)
    const editCheck = await page.evaluate(`(() => {
      const f = document.activeElement;
      if (!f || f.tagName !== 'INPUT') return { inEdit: false, tag: f?.tagName };
      let node = f;
      while (node) {
        if (node.classList?.contains('grid') || node.classList?.contains('gridContent')) return { inEdit: true };
        node = node.parentElement;
      }
      return { inEdit: false, hint: 'input not inside grid' };
    })()`);

    if (!editCheck.inEdit) {
      throw new Error('fillTableRow: not in grid edit mode. Use add:true or click a cell first.');
    }
  }

  // 4. Prepare pending fields for fuzzy matching
  const pending = new Map();
  for (const [key, val] of Object.entries(fields)) {
    if (val === null || val === undefined || val === '') {
      pending.set(key, { value: '', type: null, filled: false });
    } else if (val && typeof val === 'object' && 'value' in val) {
      const innerVal = val.value;
      pending.set(key, {
        value: innerVal === null || innerVal === undefined || innerVal === '' ? '' : String(innerVal),
        type: val.type || null, filled: false
      });
    } else {
      pending.set(key, { value: String(val), type: null, filled: false });
    }
  }

  const results = [];
  const MAX_ITER = 40;
  let prevCellId = null;
  let nonInputCount = 0;
  let firstCellId = null;

  for (let iter = 0; iter < MAX_ITER; iter++) {
    // Read focused element (INPUT or TEXTAREA inside grid = editable cell)
    const cell = await page.evaluate(`(() => {
      const f = document.activeElement;
      if (!f) return { tag: 'none' };
      if (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA') {
        const inGrid = (() => { let n = f; while (n) { if (n.classList?.contains('grid') || n.classList?.contains('gridContent')) return true; n = n.parentElement; } return false; })();
        if (inGrid) {
          let headerText = '';
          let grid = f; while (grid && !grid.classList?.contains('grid')) grid = grid.parentElement;
          if (grid) {
            const fr = f.getBoundingClientRect();
            const head = grid.querySelector('.gridHead');
            const hl = head?.querySelector('.gridLine') || head;
            if (hl) for (const h of hl.children) {
              if (h.offsetWidth === 0) continue;
              const hr = h.getBoundingClientRect();
              if (fr.x >= hr.x && fr.x < hr.x + hr.width) {
                const t = h.querySelector('.gridBoxText');
                headerText = (t || h).innerText?.trim() || '';
                break;
              }
            }
          }
          return {
            tag: 'INPUT', id: f.id,
            fullName: f.id.replace(/^form\\d+_/, '').replace(/_i\\d+$/, ''),
            headerText
          };
        }
      }
      return { tag: f.tagName || 'none' };
    })()`);

    if (cell.tag !== 'INPUT' || !cell.fullName) {
      // Not in an editable grid cell — Tab past (ERP has DIV focus between cells)
      nonInputCount++;
      // If only checkbox fields remain unfilled, stop Tab'ing to avoid creating extra rows
      const onlyCheckboxLeft = [...pending.values()].every(p => p.filled ||
        ['true', 'false', 'да', 'нет', '1', '0', 'yes', 'no'].includes(p.value.toLowerCase().trim()));
      if (nonInputCount > 3 || onlyCheckboxLeft) break;
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
      continue;
    }
    nonInputCount = 0;

    // Track first cell to detect wrap-around (Tab looped back to row start)
    if (firstCellId === null) firstCellId = cell.id;
    else if (cell.id === firstCellId) break; // wrapped around — all cells visited

    // Stuck detection: same cell twice in a row → force Tab
    if (cell.id === prevCellId) {
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      prevCellId = null;
      continue;
    }
    prevCellId = cell.id;

    // Fuzzy match cell name to user field: exact → suffix → includes → no-space includes
    const cellLower = cell.fullName.toLowerCase();
    let matchedKey = null;
    for (const [key, info] of pending) {
      if (info.filled) continue;
      const kl = key.toLowerCase();
      if (cellLower === kl || cellLower.endsWith(kl) || cellLower.includes(kl)) {
        matchedKey = key;
        break;
      }
      // CamelCase cell names have no spaces/dashes — try matching without spaces and dashes
      const klNoSpace = kl.replace(/[\s\-]+/g, '');
      if (klNoSpace && (cellLower.endsWith(klNoSpace) || cellLower.includes(klNoSpace))) {
        matchedKey = key;
        break;
      }
    }

    // Fallback: match by column header text (handles metadata typos in cell id)
    if (!matchedKey && cell.headerText) {
      const htLower = cell.headerText.toLowerCase();
      for (const [key, info] of pending) {
        if (info.filled) continue;
        const kl = key.toLowerCase();
        if (htLower === kl || htLower.endsWith(kl) || htLower.includes(kl)) {
          matchedKey = key;
          break;
        }
      }
    }

    if (!matchedKey) {
      // Skip this cell
      await page.keyboard.press('Tab');
      await page.waitForTimeout(300);
      continue;
    }

    const info = pending.get(matchedKey);
    const text = info.value;

    // Clear cell if value is empty (Shift+F4 = native 1C clear)
    if (text === '') {
      await page.keyboard.press('Shift+F4');
      await page.waitForTimeout(300);
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'clear', value: '' });
      if ([...pending.values()].every(p => p.filled)) break;
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // If user specified a type, always clear and use type selection flow
    if (info.type) {
      await page.keyboard.press('Shift+F4');  // Clear cell to reset any inherited type
      await page.waitForTimeout(300);
      await page.keyboard.press('F4');
      // Poll for type dialog form to appear
      let typeForm = null;
      for (let tw = 0; tw < 6; tw++) {
        await page.waitForTimeout(200);
        typeForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (typeForm !== null) break;
      }
      if (typeForm !== null && await isTypeDialog(typeForm)) {
        await pickFromTypeDialog(typeForm, info.type);
        await waitForStable(typeForm);
        // After type selection, check if a selection form opened (ref types)
        const selForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('[id]').forEach(el => {
            if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);
        if (selForm === null) {
          // Primitive type — poll for calculator/calendar popup or settle on INPUT
          let hasPopup = null;
          for (let pw = 0; pw < 5; pw++) {
            await page.waitForTimeout(200);
            hasPopup = await page.evaluate(`(() => {
              const calc = document.querySelector('.calculate');
              if (calc && calc.offsetWidth > 0) return 'calculator';
              const cal = document.querySelector('.frameCalendar');
              if (cal && cal.offsetWidth > 0) return 'calendar';
              return null;
            })()`);
            if (hasPopup) break;
          }
          if (hasPopup) {
            await page.keyboard.press('Escape');
            // Poll for popup to disappear
            for (let dw = 0; dw < 4; dw++) {
              await page.waitForTimeout(150);
              const gone = await page.evaluate(`(() => {
                const calc = document.querySelector('.calculate');
                if (calc && calc.offsetWidth > 0) return false;
                const cal = document.querySelector('.frameCalendar');
                if (cal && cal.offsetWidth > 0) return false;
                return true;
              })()`);
              if (gone) break;
            }
          }
          // Ensure we are in an editable INPUT for this cell
          const inInput = await page.evaluate(`(() => {
            const f = document.activeElement;
            return f && (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA');
          })()`);
          if (!inInput) {
            const cellRect = await page.evaluate(`(() => {
              const el = document.getElementById(${JSON.stringify(cell.id)});
              if (!el) return null;
              const r = el.getBoundingClientRect();
              return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
            })()`);
            if (cellRect) {
              await page.mouse.dblclick(cellRect.x, cellRect.y);
              // Poll for INPUT focus
              for (let fw = 0; fw < 4; fw++) {
                await page.waitForTimeout(150);
                const ok = await page.evaluate(`(() => {
                  const f = document.activeElement;
                  return f && (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA');
                })()`);
                if (ok) break;
              }
            }
          }
          await pasteText(text, { confirm: ['Control+a', 'Control+v'] });
          await page.waitForTimeout(400);
          await page.keyboard.press('Tab');
          await page.waitForTimeout(300);
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'type-direct', type: info.type });
          continue;
        }
        const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
        info.filled = true;
        results.push(pickResult.ok
          ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form', type: info.type }
          : { field: matchedKey, cell: cell.fullName,
              error: pickResult.error, message: pickResult.message });
        continue;
      }
      // F4 opened something but not a type dialog — close and report
      if (typeForm !== null) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName,
        error: 'type_dialog_failed',
        message: `Cell "${matchedKey}": F4 did not open type dialog for type "${info.type}"` });
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // === Fill this cell: clipboard paste (trusted event) ===
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(1500);

    // Check if paste was rejected (composite-type cell blocks text input until type is selected)
    const inputAfterPaste = await page.evaluate(`document.activeElement?.value || ''`);
    if (!inputAfterPaste && text) {
      // No type specified — can't fill this composite-type cell
      info.filled = true;
      results.push({ field: matchedKey, cell: cell.fullName,
        error: 'type_required',
        message: `Cell "${matchedKey}" rejected text input (composite-type). Use { value: '...', type: 'Тип' } syntax` });
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // Check for EDD autocomplete (indicates reference field)
    const eddItems = await page.evaluate(`(() => {
      const edd = document.getElementById('editDropDown');
      if (!edd || edd.offsetWidth === 0) return null;
      return [...edd.querySelectorAll('.eddText')]
        .filter(el => el.offsetWidth > 0)
        .map(el => el.innerText?.trim() || '');
    })()`);

    if (eddItems && eddItems.length > 0) {
      // Reference field with autocomplete — click best match
      // Filter out reference field "create" actions (Создать элемент, Создать группу, Создать: ...)
      // but keep standalone enum values like "Создать" (no space/colon after)
      const realItems = eddItems.filter(i => !/^Создать[\s:]/.test(i));

      if (realItems.length > 0) {
        const tgt = normYo(text.toLowerCase());
        let pick = realItems.find(i =>
          normYo(i.replace(/\s*\([^)]*\)\s*$/, '').toLowerCase()) === tgt);
        if (!pick) pick = realItems.find(i => normYo(i.toLowerCase()).includes(tgt));
        if (!pick) pick = realItems[0];

        // Click EDD item via dispatchEvent (bypasses div.surface overlay)
        const pickLower = pick.toLowerCase();
        await page.evaluate(`(() => {
          const edd = document.getElementById('editDropDown');
          if (!edd) return;
          for (const el of edd.querySelectorAll('.eddText')) {
            if (el.offsetWidth === 0) continue;
            if (el.innerText.trim().toLowerCase().includes(${JSON.stringify(pickLower)})) {
              const r = el.getBoundingClientRect();
              const opts = { bubbles:true, cancelable:true,
                clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
              el.dispatchEvent(new MouseEvent('mousedown', opts));
              el.dispatchEvent(new MouseEvent('mouseup', opts));
              el.dispatchEvent(new MouseEvent('click', opts));
              return;
            }
          }
        })()`);
        await waitForStable();
        info.filled = true;
        results.push({ field: matchedKey, cell: cell.fullName, ok: true,
          method: 'dropdown', value: pick.replace(/\s*\([^)]*\)\s*$/, '') });
      } else {
        // Only "Создать:" items — value not found in autocomplete
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
        info.filled = true;
        results.push({ field: matchedKey, cell: cell.fullName,
          error: 'not_found', message: `No match for "${text}"` });
      }

      // Done? If so, don't Tab (avoids creating a new row after last cell)
      if ([...pending.values()].every(p => p.filled)) break;
      // Tab to move to next cell
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // No EDD — press Tab to commit the value
    await page.keyboard.press('Tab');
    await page.waitForTimeout(1000);

    // Check for "нет в списке" cloud popup (reference field, value not found)
    const notInList = await page.evaluate(`(() => {
      for (const el of document.querySelectorAll('div')) {
        if (el.offsetWidth === 0 || el.offsetHeight === 0) continue;
        const s = getComputedStyle(el);
        if (s.position !== 'absolute' && s.position !== 'fixed') continue;
        if ((parseInt(s.zIndex) || 0) < 100) continue;
        if ((el.innerText || '').includes('нет в списке')) return true;
      }
      return false;
    })()`);

    if (notInList) {
      // Cloud has "Показать все" link — try to open selection form via it
      const clickedShowAll = await page.evaluate(`(() => {
        for (const el of document.querySelectorAll('div')) {
          if (el.offsetWidth === 0 || el.offsetHeight === 0) continue;
          const s = getComputedStyle(el);
          if (s.position !== 'absolute' && s.position !== 'fixed') continue;
          if ((parseInt(s.zIndex) || 0) < 100) continue;
          if (!(el.innerText || '').includes('нет в списке')) continue;
          // Found the cloud — look for "Показать все" hyperlink inside
          const links = [...el.querySelectorAll('a, span, div')]
            .filter(e => e.offsetWidth > 0 && e.children.length === 0);
          const showAll = links.find(e => {
            const t = (e.innerText?.trim() || '').toLowerCase();
            return t === 'показать все' || t === 'show all';
          });
          if (showAll) {
            const r = showAll.getBoundingClientRect();
            const opts = { bubbles:true, cancelable:true,
              clientX: r.x + r.width/2, clientY: r.y + r.height/2 };
            showAll.dispatchEvent(new MouseEvent('mousedown', opts));
            showAll.dispatchEvent(new MouseEvent('mouseup', opts));
            showAll.dispatchEvent(new MouseEvent('click', opts));
            return true;
          }
          return false;
        }
        return false;
      })()`);

      if (clickedShowAll) {
        await waitForStable(formNum);
        // Check if selection form opened
        const selForm = await page.evaluate(`(() => {
          const forms = {};
          document.querySelectorAll('input.editInput[id], a.press[id]').forEach(el => {
            if (el.offsetWidth === 0) return;
            const m = el.id.match(/^form(\\d+)_/);
            if (m) forms[m[1]] = true;
          });
          const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
          return nums.length > 0 ? Math.max(...nums) : null;
        })()`);

        if (selForm !== null) {
          const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
          info.filled = true;
          if (pickResult.ok) {
            results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'form' });
            continue;
          }
          // Not found in selection form — fall through to clear + skip
          results.push({ field: matchedKey, cell: cell.fullName,
            error: pickResult.error, message: pickResult.message });
        } else {
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName,
            error: 'not_found', message: `Value "${text}" not in list` });
        }
      } else {
        info.filled = true;
        results.push({ field: matchedKey, cell: cell.fullName,
          error: 'not_found', message: `Value "${text}" not in list` });
      }

      // 1C won't let us Tab away from an invalid ref value.
      // Must clear the field first, then Tab to move on.
      // Escape dismisses the cloud; Ctrl+A + Delete clears the text.
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await page.keyboard.press('Control+A');
      await page.keyboard.press('Delete');
      await page.waitForTimeout(300);
      await page.keyboard.press('Tab');
      await page.waitForTimeout(500);
      continue;
    }

    // Check for a new form (broad detection — also catches type dialogs whose buttons lack IDs)
    const newForm = await helperDetectNewForm(formNum);

    if (newForm !== null) {
      if (await isTypeDialog(newForm)) {
        // Composite-type cell — need type to proceed
        if (info.type) {
          await pickFromTypeDialog(newForm, info.type);
          await waitForStable(newForm);
          // After type selection, the actual selection form should open
          const selForm = await page.evaluate(`(() => {
            const forms = {};
            document.querySelectorAll('[id]').forEach(el => {
              if (el.offsetWidth === 0 && el.offsetHeight === 0) return;
              const m = el.id.match(/^form(\\d+)_/);
              if (m) forms[m[1]] = true;
            });
            const nums = Object.keys(forms).map(Number).filter(n => n > ${formNum});
            return nums.length > 0 ? Math.max(...nums) : null;
          })()`);
          if (selForm === null) {
            // Primitive type — poll for calculator/calendar popup or settle on INPUT
            let hasPopup = null;
            for (let pw = 0; pw < 5; pw++) {
              await page.waitForTimeout(200);
              hasPopup = await page.evaluate(`(() => {
                const calc = document.querySelector('.calculate');
                if (calc && calc.offsetWidth > 0) return 'calculator';
                const cal = document.querySelector('.frameCalendar');
                if (cal && cal.offsetWidth > 0) return 'calendar';
                return null;
              })()`);
              if (hasPopup) break;
            }
            if (hasPopup) {
              await page.keyboard.press('Escape');
              for (let dw = 0; dw < 4; dw++) {
                await page.waitForTimeout(150);
                const gone = await page.evaluate(`(() => {
                  const calc = document.querySelector('.calculate');
                  if (calc && calc.offsetWidth > 0) return false;
                  const cal = document.querySelector('.frameCalendar');
                  if (cal && cal.offsetWidth > 0) return false;
                  return true;
                })()`);
                if (gone) break;
              }
            }
            const inInput = await page.evaluate(`(() => {
              const f = document.activeElement;
              return f && (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA');
            })()`);
            if (!inInput) {
              const cellRect = await page.evaluate(`(() => {
                const el = document.getElementById(${JSON.stringify(cell.id)});
                if (!el) return null;
                const r = el.getBoundingClientRect();
                return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
              })()`);
              if (cellRect) {
                await page.mouse.dblclick(cellRect.x, cellRect.y);
                for (let fw = 0; fw < 4; fw++) {
                  await page.waitForTimeout(150);
                  const ok = await page.evaluate(`(() => {
                    const f = document.activeElement;
                    return f && (f.tagName === 'INPUT' || f.tagName === 'TEXTAREA');
                  })()`);
                  if (ok) break;
                }
              }
            }
            await pasteText(text, { confirm: ['Control+a', 'Control+v'] });
            await page.waitForTimeout(400);
            await page.keyboard.press('Tab');
            await page.waitForTimeout(300);
            info.filled = true;
            results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'type-direct', type: info.type });
            continue;
          }
          const pickResult = await pickFromSelectionForm(selForm, matchedKey, text, formNum);
          info.filled = true;
          results.push(pickResult.ok
            ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form', type: info.type }
            : { field: matchedKey, cell: cell.fullName,
                error: pickResult.error, message: pickResult.message });
          continue;
        } else {
          // No type specified — close dialog, clear cell, report error
          await page.keyboard.press('Escape');
          await page.waitForTimeout(300);
          await page.keyboard.press('Control+A');
          await page.keyboard.press('Delete');
          await page.waitForTimeout(300);
          await page.keyboard.press('Tab');
          await page.waitForTimeout(500);
          info.filled = true;
          results.push({ field: matchedKey, cell: cell.fullName,
            error: 'type_required',
            message: `Cell "${matchedKey}" opened a type selection dialog. Use { value: '...', type: 'Тип' } syntax` });
          continue;
        }
      }
      // Not a type dialog — normal selection form
      const pickResult = await pickFromSelectionForm(newForm, matchedKey, text, formNum);
      info.filled = true;
      results.push(pickResult.ok
        ? { field: matchedKey, cell: cell.fullName, ok: true, method: 'form' }
        : { field: matchedKey, cell: cell.fullName,
            error: pickResult.error, message: pickResult.message });
      continue;
    }

    // Plain field — value committed via Tab
    info.filled = true;
    results.push({ field: matchedKey, cell: cell.fullName, ok: true, method: 'direct' });

    // All done?
    if ([...pending.values()].every(p => p.filled)) break;
    // Tab already pressed — we're on next cell
  }

  // Commit the new row: click on the grid header to exit edit mode.
  // Clicking a different data row would re-enter edit mode on that row.
  // Without this commit click, the row stays in "uncommitted add" state
  // and a subsequent Escape (e.g. from closeForm) would cancel the entire row.
  const commitTarget = await page.evaluate(`(() => {
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
    if (!grid) return null;
    const head = grid.querySelector('.gridHead');
    if (head) {
      const r = head.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    }
    return null;
  })()`);
  if (commitTarget) {
    await page.mouse.click(commitTarget.x, commitTarget.y);
    await page.waitForTimeout(500);
  } else {
    // Fallback: Tab out of the last cell to commit the row
    await page.keyboard.press('Tab');
    await page.waitForTimeout(500);
  }

  // Dismiss any leftover error modals
  const err = await checkForErrors();
  if (err?.modal) {
    try {
      const btn = await page.$('a.press.pressDefault');
      if (btn) { await btn.click(); await page.waitForTimeout(500); }
    } catch { /* OK */ }
  }

  const notFilled = [...pending].filter(([_, info]) => !info.filled).map(([key]) => key);

  // Retry unfilled checkbox fields via direct click (Tab skips checkbox cells)
  if (notFilled.length > 0) {
    const checkboxFields = {};
    for (const key of notFilled) {
      const val = String(pending.get(key).value).toLowerCase().trim();
      if (['true', 'false', 'да', 'нет', '1', '0', 'yes', 'no'].includes(val)) {
        checkboxFields[key] = pending.get(key).value;
      }
    }
    if (Object.keys(checkboxFields).length > 0) {
      // Use row index: addedRowIdx (from add mode) or fallback to selected row
      const currentRow = addedRowIdx >= 0 ? addedRowIdx : (row != null ? row : await page.evaluate(`(() => {
        const grid = ${gridSelector
          ? `document.querySelector(${JSON.stringify(gridSelector)})`
          : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
        if (!grid) return -1;
        const body = grid.querySelector('.gridBody');
        if (!body) return -1;
        const lines = [...body.querySelectorAll('.gridLine')];
        const sel = lines.findIndex(l => l.classList.contains('selected'));
        return sel >= 0 ? sel : lines.length - 1;
      })()`)
      );
      if (currentRow >= 0) {
        const more = await fillTableRow(checkboxFields, { row: currentRow, table });
        if (Array.isArray(more)) {
          results.push(...more);
        } else if (more?.filled) {
          results.push(...more.filled);
        }
        for (const key of Object.keys(checkboxFields)) {
          const idx = notFilled.indexOf(key);
          if (idx >= 0) notFilled.splice(idx, 1);
        }
      }
    }
  }

  const formData = await getFormState();
  const result = { filled: results };
  if (notFilled.length > 0) result.notFilled = notFilled;
  result.form = formData;
  return result;

  } catch (e) {
    if (e.message.startsWith('fillTableRow:')) throw e;
    throw new Error(`fillTableRow: ${e.message}`);
  }
}

/**
 * Delete a row from the current table part.
 * Single click to select the row, then Delete key to remove it.
 *
 * @param {number} row - 0-based row index to delete
 * @param {Object} [options]
 * @param {string} [options.tab] - Switch to this form tab before operating
 * @returns {{ deleted, rowsBefore, rowsAfter, form }}
 */
export async function deleteTableRow(row, { tab, table } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('deleteTableRow: no form found');

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`deleteTableRow: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  // 1. Switch tab if requested
  if (tab) {
    await clickElement(tab);
    await page.waitForTimeout(500);
  }

  // 2. Find the target row and click to select it
  const cellCoords = await page.evaluate(`(() => {
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
    if (!grid) return { error: 'no_grid' };
    const body = grid.querySelector('.gridBody');
    if (!body) return { error: 'no_grid_body' };
    const rows = [...body.querySelectorAll('.gridLine')];
    if (${row} >= rows.length) return { error: 'row_out_of_range', total: rows.length };
    const line = rows[${row}];
    // Use visible gridBox containers (not gridBoxText) to avoid clicking checkboxes
    const boxes = [...line.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
    // Skip first column (row number / checkbox) — pick second visible box
    const box = boxes.length > 1 ? boxes[1] : boxes[0];
    if (!box) return { error: 'no_cell' };
    const cell = box.querySelector('.gridBoxText') || box;
    const r = cell.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), total: rows.length };
  })()`);

  if (cellCoords.error) throw new Error(`deleteTableRow: ${cellCoords.error}${cellCoords.total ? ' (total rows: ' + cellCoords.total + ')' : ''}`);

  const rowsBefore = cellCoords.total;

  // Single click to select the row
  await page.mouse.click(cellCoords.x, cellCoords.y);
  await page.waitForTimeout(300);

  // 3. Press Delete to remove the row
  await page.keyboard.press('Delete');
  await waitForStable();

  // 4. Count rows after deletion
  const rowsAfter = await page.evaluate(`(() => {
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`};
    if (!grid) return 0;
    const body = grid.querySelector('.gridBody');
    return body ? body.querySelectorAll('.gridLine').length : 0;
  })()`);

  const formData = await getFormState();
  return { deleted: row, rowsBefore, rowsAfter, form: formData };
}

/**
 * Filter the current list by field value, or search via search bar.
 *
 * Without field: simple search via the search bar (filters by all columns, no badge).
 * With field: advanced search — clicks target column cell to auto-populate FieldSelector,
 * opens dialog (Alt+F), fills Pattern, clicks Найти. Creates a real filter badge.
 * Handles text, reference (with Tab autocomplete), and date fields automatically.
 * Multiple filters can be chained by calling filterList multiple times.
 *
 * @param {string} text - Search text or date (e.g. "Мишка", "КП00", "10.03.2016")
 * @param {object} [opts]
 * @param {string} [opts.field] - Column name for advanced search (e.g. "Наименование", "Получатель", "Дата")
 * @param {boolean} [opts.exact] - Exact match (text fields only; dates/numbers/refs always exact)
 */
export async function filterList(text, { field, exact } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('filterList: no form found');

  if (!field) {
    // --- Simple search: fill search input + Enter ---
    const searchId = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
      return el ? el.id : null;
    })()`);

    if (searchId) {
      await page.click(`[id="${searchId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Control+A');
      await pasteText(text);
      await page.waitForTimeout(300);
      await page.keyboard.press('Enter');
      await waitForStable(formNum);

      const state = await getFormState();
      state.filtered = { type: 'search', text };
      return state;
    }

    // No search input — Ctrl+F opens advanced search on such forms.
    // Click first grid cell then fall through to advanced search path below.
    const firstCell = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
        .find(g => g.offsetWidth > 0);
      if (!grid) return null;
      const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
      if (!rows.length) return null;
      const cells = [...rows[0].querySelectorAll('.gridBox')];
      if (!cells.length) return null;
      const r = cells[0].getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (!firstCell) throw new Error('filterList: no search input and no grid found on this form');
    await page.mouse.click(firstCell.x, firstCell.y);
    await page.waitForTimeout(300);
    field = ''; // fall through to advanced search, skip DLB (empty field = keep auto-selected)
  }

  // --- Advanced search: click target column cell → Alt+F → fill Pattern → Найти ---
  // Clicking a cell in the target column makes it active, so when Alt+F opens the
  // advanced search dialog, FieldSelector is auto-populated with the correct field name.
  // This avoids changing FieldSelector programmatically (which can cause errors).
  const isDateValue = /^\d{2}\.\d{2}\.\d{4}$/.test(text.trim());

  // 1. Click a cell in the target column to activate it (auto-populates FieldSelector).
  //    If the column isn't visible in the grid, click any cell and use DLB fallback later.
  let needDlb = false;
  const gridEl = await page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0);
    if (!grid) return { error: 'no_grid' };
    const targetField = ${JSON.stringify(field)};
    const headers = [...grid.querySelectorAll('.gridHead .gridBox')];
    let colIndex = -1;
    let startsWithIdx = -1;
    let includesIdx = -1;
    for (let i = 0; i < headers.length; i++) {
      const t = headers[i].innerText?.trim().replace(/\\u00a0/g, ' ');
      if (!t) continue;
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const tl = ny(t.toLowerCase()), fl = ny(targetField.toLowerCase());
      if (tl === fl) { colIndex = i; break; }
      if (startsWithIdx < 0 && tl.startsWith(fl)) { startsWithIdx = i; }
      else if (includesIdx < 0 && tl.includes(fl)) { includesIdx = i; }
    }
    if (colIndex < 0) colIndex = startsWithIdx >= 0 ? startsWithIdx : includesIdx;
    const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
    if (!rows.length) return { error: 'no_rows' };
    if (colIndex < 0) {
      // Column not in grid — click first cell of first row, will use DLB to change field
      const cells = [...rows[0].querySelectorAll('.gridBox')];
      if (!cells.length) return { error: 'no_cells' };
      const r = cells[0].getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), needDlb: true };
    }
    const cells = [...rows[0].querySelectorAll('.gridBox')];
    if (colIndex >= cells.length) return { error: 'cell_not_found' };
    const r = cells[colIndex].getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  if (gridEl.error) throw new Error(`filterList: ${gridEl.error}`);
  needDlb = !!gridEl.needDlb;
  await page.mouse.click(gridEl.x, gridEl.y);
  await page.waitForTimeout(500);

  // 2. Open advanced search dialog via Alt+F (with fallback to Еще menu)
  await page.keyboard.press('Alt+f');
  await page.waitForTimeout(2000);

  let dialogForm = await page.evaluate(detectFormScript());
  if (dialogForm === formNum) {
    // Alt+F didn't open dialog — fallback to Еще → Расширенный поиск
    await clickElement('Еще');
    await page.waitForTimeout(500);
    const menu = await page.evaluate(readSubmenuScript());
    const searchItem = Array.isArray(menu) && menu.find(i =>
      i.name.replace(/\u00a0/g, ' ').toLowerCase().includes('расширенный поиск'));
    if (!searchItem) {
      await page.keyboard.press('Escape');
      throw new Error('filterList: advanced search dialog could not be opened');
    }
    await page.mouse.click(searchItem.x, searchItem.y);
    await page.waitForTimeout(2000);
    dialogForm = await page.evaluate(detectFormScript());
    if (dialogForm === formNum) {
      throw new Error('filterList: advanced search dialog did not open');
    }
  }

  // 2b. If column wasn't in the grid, change FieldSelector via DLB dropdown
  //     Skip DLB when field is empty (fallback from no-search-input path — keep auto-selected field)
  if (needDlb && field) {
    const fsInfo = await page.evaluate(`(() => {
      const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
      const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
      const dlb = document.getElementById(p + 'FieldSelector_DLB');
      return {
        current: fsInput?.value?.trim() || '',
        dlbX: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().x + dlb.getBoundingClientRect().width / 2) : 0,
        dlbY: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().y + dlb.getBoundingClientRect().height / 2) : 0
      };
    })()`);

    if (normYo(fsInfo.current.toLowerCase()) !== normYo(field.toLowerCase())) {
      await page.mouse.click(fsInfo.dlbX, fsInfo.dlbY);
      await page.waitForTimeout(1500);

      const ddResult = await page.evaluate(`(() => {
        const edd = document.getElementById('editDropDown');
        if (!edd || edd.offsetWidth === 0) return { error: 'no_dropdown' };
        const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
        const target = ny(${JSON.stringify(field.toLowerCase())});
        const items = [...edd.querySelectorAll('div')].filter(el =>
          el.offsetWidth > 0 && el.innerText?.trim() && !el.innerText.includes('\\n'));
        const match = items.find(el => ny(el.innerText.trim().toLowerCase()) === target)
          || items.find(el => ny(el.innerText.trim().toLowerCase()).includes(target));
        if (!match) return { error: 'field_not_found', available: items.map(el => el.innerText.trim()) };
        const r = match.getBoundingClientRect();
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), name: match.innerText.trim() };
      })()`);

      if (ddResult.error) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        throw new Error(`filterList: field "${field}" not found in FieldSelector. Available: ${ddResult.available?.join(', ') || 'none'}`);
      }
      await page.mouse.click(ddResult.x, ddResult.y);
      await page.waitForTimeout(3000);
    }
  }

  // 3. Read dialog state and fill Pattern
  //    Detect field type by Pattern's sibling buttons:
  //    - iCalendB → date field (Home+Shift+End+Ctrl+V to replace date value)
  //    - iDLB on Pattern → reference field (paste + Tab for autocomplete)
  //    - neither → plain text field (just paste)
  const dialogInfo = await page.evaluate(`(() => {
    const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
    const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
    const ptInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Pattern/i.test(el.id));
    const ptLabel = ptInput?.closest('label');
    const btns = ptLabel ? [...ptLabel.querySelectorAll('span.btn')].map(b => b.className) : [];
    const isDate = btns.some(c => c.includes('iCalendB'));
    const isRef = !isDate && btns.some(c => c.includes('iDLB'));
    return {
      fieldSelector: fsInput?.value?.trim() || '',
      patternValue: ptInput?.value?.trim() || '',
      patternId: ptInput?.id || '',
      isDate,
      isRef
    };
  })()`);

  if (dialogInfo.isDate) {
    // Date field: fill via Home → Shift+End (select all) → Ctrl+V (paste)
    if (isDateValue && dialogInfo.patternValue !== text.trim()) {
      await page.click(`[id="${dialogInfo.patternId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Home');
      await page.waitForTimeout(100);
      await page.keyboard.press('Shift+End');
      await page.waitForTimeout(100);
      await pasteText(text);
      await page.waitForTimeout(500);
    }
  } else {
    // Text or reference field: fill Pattern via clipboard paste
    await page.click(`[id="${dialogInfo.patternId}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(300);

    if (dialogInfo.isRef) {
      // Reference field: Tab triggers autocomplete to resolve text → reference value
      await page.keyboard.press('Tab');
      await page.waitForTimeout(2000);
    }
  }

  // 3b. Switch CompareType if exact match requested (text fields only).
  //    Date/number: always exact, CompareType disabled. Reference: default exact (selects ref).
  if (exact && !dialogInfo.isDate && !dialogInfo.isRef) {
    const exactRadio = await page.evaluate(`(() => {
      const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
      // Check if CompareType group is disabled (dates, numbers)
      const group = document.getElementById(p + 'CompareType');
      if (group && group.classList.contains('disabled')) return { already: true };
      const el = document.getElementById(p + 'CompareType#2#radio');
      if (!el || el.offsetWidth === 0) return null;
      if (el.classList.contains('select')) return { already: true };
      const r = el.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (exactRadio && !exactRadio.already) {
      await page.mouse.click(exactRadio.x, exactRadio.y);
      await page.waitForTimeout(300);
    }
  }

  // 4. Click "Найти" via mouse.click (dialog is modal — page.click may be blocked)
  const findBtnCoords = await page.evaluate(`(() => {
    const btns = [...document.querySelectorAll('a.press')].filter(el => el.offsetWidth > 0);
    const btn = btns.find(el => el.innerText?.trim() === 'Найти');
    if (!btn) return null;
    const r = btn.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  if (findBtnCoords) {
    await page.mouse.click(findBtnCoords.x, findBtnCoords.y);
  } else {
    await clickElement('Найти');
  }
  await page.waitForTimeout(2000);

  // 5. Close advanced search dialog if it stayed open (some forms keep it open after Найти).
  //    Check the specific dialog form — not generic modalSurface — to avoid closing parent modals
  //    (e.g. a selection form that opened this advanced search).
  for (let attempt = 0; attempt < 3; attempt++) {
    const dialogVisible = await page.evaluate(`(() => {
      const p = 'form${dialogForm}_';
      return [...document.querySelectorAll('[id^="' + p + '"]')].some(el => el.offsetWidth > 0);
    })()`);
    if (!dialogVisible) break;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
  }
  await waitForStable(formNum);

  const state = await getFormState();
  state.filtered = { type: 'advanced', field, text, exact: !!exact };
  return state;
}

/**
 * Remove active filters/search from the current list.
 *
 * Without field: clears ALL filters (Ctrl+Q for advanced search + clear search field).
 * With field: clicks the × button on the specific filter badge (selective removal).
 *
 * @param {object} [opts]
 * @param {string} [opts.field] - Remove only the filter for this field (clicks badge ×)
 */
export async function unfilterList({ field } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('unfilterList: no form found');

  if (field) {
    // --- Selective: click × on specific filter badge ---
    const closeBtn = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const norm = s => s?.trim().replace(/\\u00a0/g, ' ').replace(/:$/, '').replace(/\\n/g, ' ') || '';
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const target = ny(${JSON.stringify(field.toLowerCase())});
      const items = [...document.querySelectorAll('[id^="' + p + '"].trainItem')].filter(el => el.offsetWidth > 0);
      for (const item of items) {
        const titleEl = item.querySelector('.trainName');
        const title = ny(norm(titleEl?.innerText).toLowerCase());
        if (title === target || title.includes(target)) {
          const close = item.querySelector('.trainClose');
          if (close) {
            const r = close.getBoundingClientRect();
            return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), field: norm(titleEl?.innerText) };
          }
        }
      }
      const available = items.map(item => norm(item.querySelector('.trainName')?.innerText));
      return { error: 'not_found', available };
    })()`);

    if (closeBtn?.error) throw new Error(`unfilterList: filter badge "${field}" not found. Available: ${closeBtn.available?.join(', ') || 'none'}`);
    await page.mouse.click(closeBtn.x, closeBtn.y);
    await waitForStable(formNum);

    const state = await getFormState();
    state.unfiltered = { field: closeBtn.field };
    return state;
  }

  // --- Clear ALL filters ---

  // 1. Remove all advanced filter badges (.trainItem × buttons)
  for (let attempt = 0; attempt < 20; attempt++) {
    const badge = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const item = [...document.querySelectorAll('[id^="' + p + '"].trainItem')]
        .find(el => el.offsetWidth > 0);
      if (!item) return null;
      const close = item.querySelector('.trainClose');
      if (!close) return null;
      const r = close.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (!badge) break;
    await page.mouse.click(badge.x, badge.y);
    await waitForStable(formNum);
  }

  // 2. Cancel active search via Ctrl+Q
  await page.keyboard.press('Control+q');
  await waitForStable(formNum);

  // 3. Clear simple search field if it has a value
  const searchInfo = await page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
    return el ? { id: el.id, value: el.value || '' } : null;
  })()`);

  if (searchInfo?.value) {
    await page.click(`[id="${searchInfo.id}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Delete');
    await page.keyboard.press('Enter');
    await waitForStable(formNum);
  }

  const state = await getFormState();
  state.unfiltered = true;
  return state;
}

// ============================================================
// Recording, captions, narration, highlight — extracted to recording/*
// ============================================================
export {
  screenshot, wait, isRecording, startRecording, stopRecording,
} from './recording/capture.mjs';
export {
  showCaption, hideCaption, getCaptions,
  showTitleSlide, hideTitleSlide,
  showImage, hideImage,
} from './recording/captions.mjs';
export {
  highlight, unhighlight, setHighlight, isHighlightMode,
} from './recording/highlight.mjs';
export { addNarration } from './recording/narration.mjs';

/* ensureConnected moved to core/state.mjs */
