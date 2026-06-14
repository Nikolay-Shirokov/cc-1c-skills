// web-test core/session v1.17 — Browser session lifecycle: connect/disconnect/attach/detach, multi-context registry.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { chromium } from 'playwright';
import { statSync, mkdirSync, readdirSync, rmSync } from 'fs';
import { join as pathJoin } from 'path';
import { tmpdir } from 'os';
import {
  browser, page, sessionPrefix, seanceId, recorder, highlightMode,
  contexts, activeContextName, activeMode, persistentUserDataDir,
  setBrowser, setPage, setSessionPrefix, setSeanceId, setHighlightMode,
  setActiveContextName, setActiveMode, setPersistentUserDataDir,
  isConnected, LOAD_TIMEOUT, INIT_TIMEOUT, EXT_ID,
} from './state.mjs';
import { closeModals } from './errors.mjs';
import { stopRecording } from '../recording/capture.mjs';
import { getPageState } from '../nav/navigation.mjs';

/**
 * Find the 1C browser extension in Chrome/Edge user profiles.
 * Returns the path to the latest version, or null if not found.
 * Can be overridden via extensionPath in .v8-project.json.
 */
function findExtension(overridePath) {
  if (overridePath) {
    try { if (statSync(overridePath).isDirectory()) return overridePath; } catch {}
    return null;
  }
  const localAppData = process.env.LOCALAPPDATA;
  if (!localAppData) return null;
  const browsers = [
    pathJoin(localAppData, 'Google', 'Chrome', 'User Data'),
    pathJoin(localAppData, 'Microsoft', 'Edge', 'User Data'),
  ];
  for (const userData of browsers) {
    try { if (!statSync(userData).isDirectory()) continue; } catch { continue; }
    let profiles;
    try { profiles = readdirSync(userData).filter(d => d === 'Default' || d.startsWith('Profile ')); } catch { continue; }
    for (const profile of profiles) {
      const extDir = pathJoin(userData, profile, 'Extensions', EXT_ID);
      try { if (!statSync(extDir).isDirectory()) continue; } catch { continue; }
      let versions;
      try { versions = readdirSync(extDir).filter(d => /^\d/.test(d)).sort(); } catch { continue; }
      if (versions.length > 0) {
        const best = pathJoin(extDir, versions[versions.length - 1]);
        try { if (statSync(pathJoin(best, 'manifest.json')).isFile()) return best; } catch {}
      }
    }
  }
  return null;
}

/* isConnected moved to core/state.mjs */

/**
 * Open browser and navigate to 1C web client URL.
 * Waits for initialization (themesCell_theme_0 selector) and attempts to close startup modals.
 */
export async function connect(url, { extensionPath } = {}) {
  if (isConnected()) {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
  } else {
    const extPath = findExtension(extensionPath);
    if (extPath) {
      // Launch with 1C browser extension via persistent context
      setPersistentUserDataDir(pathJoin(tmpdir(), 'pw-1c-ext-' + Date.now()));
      mkdirSync(persistentUserDataDir, { recursive: true });
      const context = await chromium.launchPersistentContext(persistentUserDataDir, {
        headless: false,
        args: [
          '--start-maximized',
          '--disable-extensions-except=' + extPath,
          '--load-extension=' + extPath,
        ],
        viewport: null,
        permissions: ['clipboard-read', 'clipboard-write'],
      });
      setBrowser(context); // persistent context IS the browser
      setPage(context.pages()[0] || await context.newPage());
    } else {
      // Fallback: launch without extension
      setBrowser(await chromium.launch({ headless: false, args: ['--start-maximized'] }));
      const context = await browser.newContext({
        viewport: null,
        permissions: ['clipboard-read', 'clipboard-write'],
      });
      setPage(await context.newPage());
    }

    // Auto-accept native browser dialogs (confirm/alert from 1C scripts like vis.js)
    page.on('dialog', dialog => dialog.accept().catch(() => {}));

    // Capture seanceId from network requests for graceful logout
    setSessionPrefix(null);
    setSeanceId(null);
    page.on('request', req => {
      if (seanceId) return;
      const m = req.url().match(/^(https?:\/\/[^/]+\/[^/]+\/[^/]+)\/e1cib\/.+[?&]seanceId=([^&]+)/);
      if (m) { setSessionPrefix(m[1]); setSeanceId(m[2]); }
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
  }

  // Wait for 1C to initialize — detect by section panel appearance
  try {
    await page.waitForSelector('#themesCell_theme_0', { timeout: INIT_TIMEOUT });
  } catch {
    // Fallback: wait fixed time if selector doesn't appear (e.g. login page)
    await page.waitForTimeout(5000);
  }

  // Try to close startup modals (Путеводитель etc.)
  await closeModals();

  return await getPageState();
}

/**
 * Best-effort POST /e1cib/logout on a slot to release the 1C session license.
 * Silent — if page is closed or session info missing, just returns.
 * @param {object} slot   { page, sessionPrefix, seanceId } from contexts Map
 * @param {number} [waitMs=500]  pause after logout fetch (gives 1C time to process)
 */
async function logoutSlot(slot, waitMs = 500) {
  if (!slot?.page || slot.page.isClosed() || !slot.seanceId || !slot.sessionPrefix) return;
  try {
    const logoutUrl = `${slot.sessionPrefix}/e1cib/logout?seanceId=${slot.seanceId}`;
    await slot.page.evaluate(async (url) => {
      await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"root":{}}' });
    }, logoutUrl);
    await slot.page.waitForTimeout(waitMs);
  } catch {}
}

/**
 * Gracefully terminate the 1C session and close the browser.
 * Sends POST /e1cib/logout to release the license before closing.
 */
export async function disconnect() {
  // Multi-context path: stop recording + logout each slot before closing browser
  if (contexts.size > 0) {
    saveActiveSlot();
    // Recorder is global — one stop covers all contexts
    if (recorder) {
      try { await stopRecording(); } catch {}
    }
    for (const [, slot] of contexts.entries()) {
      await logoutSlot(slot);
    }
    contexts.clear();
    setActiveContextName(null);
    setActiveMode(null);
  }

  // Single-session path (connect): auto-stop recording if active
  if (recorder) {
    try { await stopRecording(); } catch {}
  }

  if (browser) {
    // Graceful logout — release the 1C license (single-session connect path)
    await logoutSlot({ page, sessionPrefix, seanceId }, 1000);
    await browser.close().catch(() => {});
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    // Clean up persistent user data dir
    if (persistentUserDataDir) {
      try { rmSync(persistentUserDataDir, { recursive: true, force: true }); } catch {}
      setPersistentUserDataDir(null);
    }
  }
}

/**
 * Attach to a running browser server via CDP WebSocket.
 * Sets module state so all functions (getFormState, clickElement, etc.) work.
 */
export async function attach(wsEndpoint, session = {}) {
  if (isConnected()) return;
  setBrowser(await chromium.connect(wsEndpoint));
  const ctx = browser.contexts()[0];
  setPage(ctx?.pages()[0]);
  if (!page) throw new Error('No page found in browser');
  setSessionPrefix(session.sessionPrefix || null);
  setSeanceId(session.seanceId || null);
}

/**
 * Detach from browser without closing it.
 * Returns session state for persistence.
 */
export function detach() {
  const session = { sessionPrefix, seanceId };
  setBrowser(null);
  setPage(null);
  setSessionPrefix(null);
  setSeanceId(null);
  return session;
}

/** Get current session state (for saving between reconnections). */
export function getSession() {
  return { sessionPrefix, seanceId };
}

// ============================================================
// Multi-context support (used by run.mjs cmdTest only)
// ============================================================

/**
 * Save current module-level state into the active slot before switching.
 * No-op if no active slot.
 */
function saveActiveSlot() {
  if (!activeContextName) return;
  const slot = contexts.get(activeContextName);
  if (!slot) return;
  slot.page = page;
  slot.sessionPrefix = sessionPrefix;
  slot.seanceId = seanceId;
  slot.highlightMode = highlightMode;
  // Note: `recorder`, `lastCaptions`, `lastRecordingDuration` are intentionally NOT
  // mirrored per-slot. A multi-context recording produces one continuous output file —
  // the recorder follows the active page via recorder._attachPage(), not per-slot state.
}

/** Load a slot's state into module-level vars and mark it active. */
function activateSlot(name) {
  const slot = contexts.get(name);
  if (!slot) throw new Error(`Context "${name}" not found. Create it via createContext() first.`);
  setPage(slot.page);
  setSessionPrefix(slot.sessionPrefix);
  setSeanceId(slot.seanceId);
  setHighlightMode(slot.highlightMode || false);
  setActiveContextName(name);
}

/** Attach 1C session listeners to a page, writing into the given slot. */
function attachSessionListeners(pg, slot, name) {
  pg.on('dialog', dialog => dialog.accept().catch(() => {}));
  pg.on('request', req => {
    if (slot.seanceId) return;
    const m = req.url().match(/^(https?:\/\/[^/]+\/[^/]+\/[^/]+)\/e1cib\/.+[?&]seanceId=([^&]+)/);
    if (m) {
      slot.sessionPrefix = m[1];
      slot.seanceId = m[2];
      if (activeContextName === name) {
        setSessionPrefix(m[1]);
        setSeanceId(m[2]);
      }
    }
  });
}

/**
 * Create (or navigate) a named browser context.
 * First call launches Chromium via chromium.launch() (NOT launchPersistentContext) so that
 * subsequent calls can create additional isolated BrowserContexts in the same process.
 * Trade-off: 1C browser extension is loaded via --load-extension (process-level) rather than
 * persistent profile.
 *
 * Use this from run.mjs cmdTest only — exec/run/start use connect() and stay on the
 * legacy persistent-context path.
 */
export async function createContext(name, url, { extensionPath, isolation = 'tab' } = {}) {
  if (contexts.has(name)) {
    await setActiveContext(name);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
    try { await page.waitForSelector('#themesCell_theme_0', { timeout: INIT_TIMEOUT }); }
    catch { await page.waitForTimeout(5000); }
    await closeModals();
    return await getPageState();
  }

  if (!['tab', 'window'].includes(isolation)) {
    throw new Error(`createContext: invalid isolation "${isolation}", expected 'tab' or 'window'`);
  }
  if (activeMode && activeMode !== isolation) {
    throw new Error(`createContext: cannot mix isolation modes — first context used "${activeMode}", "${name}" requested "${isolation}". Use the same mode for all contexts in one run.`);
  }

  // First context: launch browser. Subsequent: reuse existing.
  let isFirstContext = !browser;
  if (isFirstContext) {
    const extPath = findExtension(extensionPath);
    const launchArgs = ['--start-maximized'];
    if (extPath) {
      launchArgs.push('--disable-extensions-except=' + extPath, '--load-extension=' + extPath);
    }
    if (isolation === 'tab') {
      // Persistent context: extension loads reliably, one window with tabs per context
      setPersistentUserDataDir(pathJoin(tmpdir(), 'pw-1c-test-' + Date.now()));
      mkdirSync(persistentUserDataDir, { recursive: true });
      setBrowser(await chromium.launchPersistentContext(persistentUserDataDir, {
        headless: false,
        args: launchArgs,
        viewport: null,
        permissions: ['clipboard-read', 'clipboard-write'],
      }));
    } else {
      // Window mode: separate BrowserContext per slot, full cookie isolation
      setBrowser(await chromium.launch({ headless: false, args: launchArgs }));
    }
    setActiveMode(isolation);
  }

  // Save current active before switching
  saveActiveSlot();

  // Create slot — page differs by mode
  let newCtx, newPage;
  if (activeMode === 'tab') {
    // Reuse the persistent context for all slots; each slot gets its own page (tab)
    newCtx = browser;
    if (isFirstContext) {
      newPage = browser.pages()[0] || await browser.newPage();
    } else {
      newPage = await browser.newPage();
    }
  } else {
    // Window mode: each slot owns its BrowserContext + page
    newCtx = await browser.newContext({
      viewport: null,
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    newPage = await newCtx.newPage();
  }

  const slot = {
    context: newCtx,
    page: newPage,
    sessionPrefix: null,
    seanceId: null,
    highlightMode: false,
  };
  contexts.set(name, slot);

  attachSessionListeners(newPage, slot, name);
  activateSlot(name);

  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
  try { await page.waitForSelector('#themesCell_theme_0', { timeout: INIT_TIMEOUT }); }
  catch { await page.waitForTimeout(5000); }
  await closeModals();

  return await getPageState();
}

/** Switch the active context. Subsequent browser API calls operate on this context's page. */
export async function setActiveContext(name) {
  if (activeContextName === name) return;
  if (!contexts.has(name)) throw new Error(`Context "${name}" not found. Available: [${[...contexts.keys()].join(', ')}]`);
  // If a recording is active, flush the outgoing page's last frame so the gap is filled
  // up to the moment of the switch (avoids a "jump" in video time).
  if (recorder && recorder._flushFrames) recorder._flushFrames();
  saveActiveSlot();
  activateSlot(name);
  // If the recording is still alive (it lives across slots — we keep the same ffmpeg/output),
  // re-attach its screencast to the newly active page.
  if (recorder && recorder._attachPage) {
    await recorder._attachPage(page);
  }
}

export function listContexts() {
  return [...contexts.keys()];
}

export function getActiveContext() {
  return activeContextName;
}

export function hasContext(name) {
  return contexts.has(name);
}

/**
 * Close a named context: logout, close its page (tab mode) or BrowserContext
 * (window mode), remove from registry. Cannot close the currently active
 * context — caller must setActiveContext to another first. This keeps the
 * recorder/page invariants simple: recorder is always attached to the
 * active slot, which closeContext never touches.
 *
 * @throws if name is not registered or equals the active context.
 */
export async function closeContext(name) {
  if (!contexts.has(name)) {
    throw new Error(`Context "${name}" not found. Available: [${[...contexts.keys()].join(', ')}]`);
  }
  if (name === activeContextName) {
    throw new Error(`closeContext: cannot close the active context "${name}". setActiveContext to another context first.`);
  }
  const slot = contexts.get(name);
  await logoutSlot(slot);
  if (activeMode === 'tab') {
    try { await slot.page.close(); } catch {}
  } else {
    try { await slot.context.close(); } catch {}
  }
  contexts.delete(name);
}
