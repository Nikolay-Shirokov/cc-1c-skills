// web-test core/session v1.20 — Browser session lifecycle: connect/disconnect/attach/detach, multi-context registry.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { chromium } from 'playwright';
import { softDeadline } from './deadline.mjs';
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
 * Wait for the 1C client to come up — or for the startup shell to say why it won't.
 *
 * Why this exists: when 1C has no free licence it renders a blocking startup dialog INSTEAD of
 * the application. The old code just waited out INIT_TIMEOUT and returned success, leaving a
 * session-less slot behind; the first engine call then produced a plainly wrong diagnosis
 * ("Section panel is in icon-only mode…"). Measured: 66s wasted, then a lie.
 *
 * Two blockers are recognised, both by id:
 *   #messageBoxText  — the startup message box (no free licence, and any other startup error)
 *   #authWindow      — the login dialog: the publication wants credentials, which the engine
 *                      cannot supply. Landing here used to be treated as legitimate ("login
 *                      page"), but that was fiction: closeModals() presses Escape 5x right after
 *                      this wait, which dismisses the dialog and leaves a blank page reported as
 *                      a healthy start. Nobody could ever log in by hand either.
 *
 * Contract: throw ONLY on positive evidence — a visible dialog. A missing client marker is NOT
 * evidence (an unknown or merely slow start must keep its old behaviour), hence the fallback.
 *
 * Anchors are ids, never text: the platform's wording is locale-dependent and only gets quoted
 * into the message. Verified on this stand — on a healthy start neither #messageBoxText nor
 * #authWindow exists at all, in the loaded client or at any point while the shell boots (polled
 * every 100ms, including bpdemo's 19.5s auto-login boot). The offsetWidth/text conjuncts guard a
 * future build that pre-renders them hidden. offsetWidth (not offsetParent — that is null for
 * position:fixed, and #ps0win is an overlay) matches the convention in errors.mjs.
 */
async function waitForClientOrStartupBlock(pg, url, timeout = INIT_TIMEOUT) {
  let outcome;
  try {
    outcome = await pg.waitForFunction(() => {
      if (document.querySelector('#themesCell_theme_0')) return 'client';
      const box = document.querySelector('#messageBoxText');
      if (box && box.offsetWidth > 0 && box.textContent.trim()) return 'blocked';
      const auth = document.querySelector('#authWindow');
      if (auth && auth.offsetWidth > 0) return 'auth';
      return false;
    }, null, { timeout }).then(h => h.jsonValue());
  } catch {
    // Neither appeared: unchanged legacy behaviour — a login page or a slow start is not an error.
    await pg.waitForTimeout(5000);
    return;
  }
  if (outcome === 'client') return;

  // Re-confirm before accusing: costs 600ms on a path that is already lost, and buys immunity to
  // a dialog that merely flickered while the shell drew itself.
  await pg.waitForTimeout(600);
  const evidence = await pg.evaluate(() => {
    // innerText, not textContent: the latter concatenates without any rendered whitespace
    // ("лицензии!Выберите…", "Веб-клиентсеанс: 5") — unreadable in an error message.
    const visibleText = (el) => (el && el.offsetWidth > 0) ? (el.innerText || '').trim() : '';
    if (document.querySelector('#themesCell_theme_0')) return null; // the client won after all
    const text = visibleText(document.querySelector('#messageBoxText'));
    if (text) return { kind: 'blocked', text, seances: visibleText(document.querySelector('#seancesToFinish')) };
    const auth = document.querySelector('#authWindow');
    if (auth && auth.offsetWidth > 0) return { kind: 'auth', text: visibleText(auth) };
    return null;
  }).catch(() => null);
  if (!evidence) return; // flicker — carry on exactly as before

  const oneLine = (s) => s.replace(/\s+/g, ' ').trim().slice(0, 300);

  if (evidence.kind === 'auth') {
    // The publication asks a human for credentials. The engine cannot answer, and until now it
    // did something worse than fail: it waited 66s and then closeModals()'s Escape dismissed the
    // dialog, leaving a blank page reported as a healthy start. Note a seance IS already created
    // here (unlike the licence case) and holds a licence — callers release it before rethrowing.
    throw new Error(
      `1C requires interactive login before the web client loads: "${oneLine(evidence.text)}"` +
      '\n  The engine cannot supply credentials — publish the infobase with a user' +
      ' (web-publish -UserName … → Usr=/Pwd= in the vrd) or put one in the connection string.' +
      `\n  URL: ${url}`
    );
  }

  throw new Error(
    `1C startup blocked before the web client loaded: "${oneLine(evidence.text)}"` +
    (evidence.seances ? `\n  Sessions the platform offers to terminate: ${oneLine(evidence.seances)}` : '') +
    '\n  The engine does not press this dialog\'s buttons: its countdown auto-start may terminate' +
    ' someone else\'s session on this machine.' +
    `\n  If this is a licence shortage — release 1C sessions and retry. URL: ${url}`
  );
}

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

  // Wait for 1C to initialize — or fail fast if the startup shell blocks the client.
  // MUST run before closeModals(): that presses Escape 5x, which dismisses the auth dialog and
  // destroys the evidence (measured — one Escape blanks the page).
  try {
    await waitForClientOrStartupBlock(page, url);
  } catch (e) {
    // On the auth dialog a 1C seance already exists and holds a licence, and killing the process
    // does NOT release it. cmdStart has no catch and run.mjs does not wrap the command, so the
    // error escapes and the process dies — release the seance here, while we still can.
    await softDeadline(disconnect(), 20000, 'disconnect(startup-block)');
    throw e;
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
  const wasMultiContext = contexts.size > 0;

  // Multi-context path: stop recording + logout each slot before closing browser
  if (wasMultiContext) {
    saveActiveSlot();
    // Recorder is global — one stop covers all contexts
    if (recorder) {
      await softDeadline(stopRecording(), 40000, 'stopRecording');
    }
    for (const [, slot] of contexts.entries()) {
      // Deadline-bounded: an unresponsive slot must not hold up the shutdown of the others.
      // nodeLogout is the fallback that needs no renderer — it is what keeps the license
      // from leaking when the page is the thing that died.
      const own = await softDeadline(logoutSlot(slot), 3000, 'logoutSlot');
      if (!own.ok) await nodeLogout(slot, 3000);
    }
    contexts.clear();
    setActiveContextName(null);
    setActiveMode(null);
  }

  // Single-session path (connect): auto-stop recording if active
  if (recorder) {
    await softDeadline(stopRecording(), 40000, 'stopRecording');
  }

  if (browser) {
    // Graceful logout — release the 1C license (single-session connect path).
    // Skipped after the multi-context path: `page` still mirrors the last active slot, which
    // was just logged out above — re-sending it would pay a hung page's cost a second time.
    if (!wasMultiContext) {
      await softDeadline(logoutSlot({ page, sessionPrefix, seanceId }, 1000), 4000, 'logoutSlot');
    }
    await softDeadline(browser.close(), 10000, 'browser.close');
    // Floor: if Chromium ignored close(), take the process out — never leave an orphan.
    try { browser.browser?.()?.process?.()?.kill('SIGKILL'); } catch {}
    try { browser.process?.()?.kill('SIGKILL'); } catch {}
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

  // Network counters feed the hang/slow diagnosis (see probeContext). These events are
  // emitted by the BROWSER process, so they keep flowing even when the page's JS thread is
  // wedged and page.evaluate() can no longer answer. Supporting colour only, not a verdict:
  // a wedged renderer cannot issue requests, so "quiet" looks the same as "idle waiting".
  // Counters only — never buffer URLs, this runs for the whole suite.
  slot.net = { lastEventAt: Date.now(), inFlight: 0, requests: 0, responses: 0 };
  const settled = () => { slot.net.inFlight = Math.max(0, slot.net.inFlight - 1); slot.net.lastEventAt = Date.now(); };
  pg.on('requestfinished', settled);
  pg.on('requestfailed', settled);
  pg.on('response', () => { slot.net.responses++; slot.net.lastEventAt = Date.now(); });

  pg.on('request', req => {
    slot.net.requests++;
    slot.net.inFlight++;
    slot.net.lastEventAt = Date.now();
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
/**
 * Navigate the active slot to `url` and settle: client up, or a startup block raised.
 *
 * On a block the slot MUST NOT survive. It is registered before this runs, and the runner's
 * ensureContext is `if (browser.hasContext(name)) return;` — so a broken slot left in the registry
 * would silently serve every later test the refusal dialog, i.e. exactly the blindness being fixed.
 * abortContext also handles the tab-mode last-page teardown, so the next createContext relaunches.
 */
async function openAndSettle(name, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
  try {
    await waitForClientOrStartupBlock(page, url);
  } catch (e) {
    await softDeadline(abortContext(name), 10000, 'abortContext(startup-block)');
    throw e;
  }
  await closeModals();
  return await getPageState();
}

export async function createContext(name, url, { extensionPath, isolation = 'tab' } = {}) {
  if (contexts.has(name)) {
    await setActiveContext(name);
    return await openAndSettle(name, url);
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

  return await openAndSettle(name, url);
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

/**
 * Release a 1C seance straight from Node — no renderer, no CDP, no browser involved.
 *
 * Measured on the webtest stand: the seance is identified by `seanceId` in the URL and the
 * client holds NO cookies at all (context.cookies() → []), so this request is equivalent to
 * the one logoutSlot makes from inside the page. Verified end-to-end: after this call the
 * web client reports "сеанс был завершен" on its next action.
 *
 * This is the only logout that still works when the renderer is wedged — which is exactly
 * when a license would otherwise leak until the server-side seance timeout.
 *
 * @returns {Promise<boolean>} true only on a 2xx answer (a 401/404 must not pass for success).
 */
async function nodeLogout(slot, ms = 3000) {
  if (!slot?.sessionPrefix || !slot?.seanceId) return false;
  try {
    const res = await fetch(`${slot.sessionPrefix}/e1cib/logout?seanceId=${slot.seanceId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{"root":{}}',
      signal: AbortSignal.timeout(ms),
    });
    return res.status >= 200 && res.status < 300;
  } catch {
    return false;
  }
}

/**
 * Is this context's browser alive, and is its renderer still answering?
 *
 * The two probes separate the failure modes that look identical from the outside:
 *   browserAlive && !rendererAlive → the page's JS thread is wedged: a hang. Nothing that
 *     goes through the renderer (evaluate, screenshot, clicks) can ever come back.
 *   both alive → nothing is broken; the test simply outran its timeout.
 *
 * cookies() is served by the browser process (measured: 1ms against a wedged renderer),
 * page.evaluate() is not — that asymmetry is the whole trick.
 *
 * @returns {Promise<{browserAlive: boolean, rendererAlive: boolean, browserMs: number, rendererMs: number, pageClosed: boolean}>}
 */
export async function probeContext(name, { ms = 2000 } = {}) {
  const slot = contexts.get(name);
  if (!slot?.page) return { browserAlive: false, rendererAlive: false, browserMs: 0, rendererMs: 0, pageClosed: true };
  if (slot.page.isClosed()) return { browserAlive: false, rendererAlive: false, browserMs: 0, rendererMs: 0, pageClosed: true };

  const [b, r] = await Promise.all([
    softDeadline(slot.page.context().cookies(), ms, 'browser probe'),
    softDeadline(slot.page.evaluate(() => 1), ms, 'renderer probe'),
  ]);
  return {
    browserAlive: b.ok,
    rendererAlive: r.ok,
    browserMs: b.ms,
    rendererMs: r.ms,
    pageClosed: false,
  };
}

/** Read-only view of a slot's network activity. Never hands out the slot itself. */
export function getContextDiagnostics(name) {
  const slot = contexts.get(name);
  if (!slot) return null;
  const net = slot.net || { lastEventAt: 0, inFlight: 0, requests: 0, responses: 0 };
  return {
    name,
    isolation: activeMode,
    net: { ...net },
    msSinceLastNetEvent: net.lastEventAt ? Date.now() - net.lastEventAt : null,
    pageClosed: slot.page ? slot.page.isClosed() : true,
  };
}

/**
 * Force-release an unresponsive context — including the ACTIVE one, which closeContext
 * refuses to touch. Every step is wall-clock bounded, so this path is never at the mercy
 * of the thing that hung: it is bounded by timers, never by browser cooperation.
 *
 * Ordering matters: logout FIRST (a dead page can't release its own license), close second.
 *
 * @param {string} name
 * @param {object} [opts]
 * @param {number} [opts.logoutMs=3000] budget per logout attempt
 * @param {number} [opts.closeMs=5000]  budget for page.close()/context.close()
 * @param {string} [opts.parkOn]        context to activate afterwards (default: any survivor)
 * @returns {Promise<{name, logout: 'node'|'page'|'sibling'|'failed'|'skipped', closed: 'page'|'context'|'browser-killed'|'failed', escalated: boolean, notes: string[]}>}
 */
export async function abortContext(name, { logoutMs = 3000, closeMs = 5000, parkOn } = {}) {
  const out = { name, logout: 'skipped', closed: 'failed', escalated: false, notes: [] };
  const slot = contexts.get(name);
  if (!slot) { out.notes.push('not registered'); return out; }

  // The recorder follows the active page; if we are about to close that page, stop it first
  // or the CDP screencast is dead for the rest of the run.
  if (recorder && activeContextName === name) {
    const r = await softDeadline(stopRecording(), 10000, 'stopRecording');
    if (!r.ok) out.notes.push(`stopRecording: ${r.err.message.split('\n')[0]}`);
  }

  // ── Logout cascade: first success wins. node first — it needs neither renderer nor CDP.
  if (slot.seanceId && slot.sessionPrefix) {
    if (await nodeLogout(slot, logoutMs)) {
      out.logout = 'node';
    } else {
      const own = await softDeadline(logoutSlot(slot, 0), logoutMs, 'logoutSlot');
      if (own.ok) {
        out.logout = 'page';
      } else {
        // Same origin ⇒ same seance namespace; a live sibling can post the logout for us.
        const sibling = [...contexts.entries()].find(([n, s]) =>
          n !== name && s.page && !s.page.isClosed() && s.sessionPrefix === slot.sessionPrefix);
        if (sibling) {
          const url = `${slot.sessionPrefix}/e1cib/logout?seanceId=${slot.seanceId}`;
          const sib = await softDeadline(
            sibling[1].page.evaluate(async (u) => {
              const r = await fetch(u, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"root":{}}' });
              return r.status;
            }, url), logoutMs, 'sibling logout');
          if (sib.ok && sib.value >= 200 && sib.value < 300) out.logout = 'sibling';
          else out.logout = 'failed';
        } else {
          out.logout = 'failed';
        }
      }
    }
    if (out.logout === 'failed') out.notes.push('license may leak until the 1C seance times out');
  }

  // In tab mode `browser` is a persistent BrowserContext (see createContext): closing its LAST
  // page leaves Chromium with no windows and it exits, so the next createContext() would fail
  // with "Failed to open a new tab". When this is the only slot, tear the browser down on
  // purpose and reset state — the next createContext() then relaunches cleanly.
  const lastPageInTabMode = activeMode === 'tab' && contexts.size === 1;

  // ── Close. runBeforeUnload:false is what survives a wedged renderer: the browser process
  // tears the target down instead of asking the page's JS to agree.
  if (activeMode === 'tab') {
    // tab mode: slot.context IS the shared browser — closing it would kill every context.
    const c = await softDeadline(slot.page.close({ runBeforeUnload: false }), closeMs, 'page.close');
    if (c.ok) out.closed = 'page';
  } else {
    const c = await softDeadline(slot.context.close(), closeMs, 'context.close');
    if (c.ok) out.closed = 'context';
  }

  // ── Escalate: if even the close hung, the browser itself is suspect. Kill it and reset
  // state, otherwise the next createContext() would call newPage() on a dead object and
  // every remaining test would fail.
  if (out.closed === 'failed') {
    out.escalated = true;
    out.notes.push('close breached its deadline — killing the browser');
    const b = browser;
    await softDeadline(Promise.resolve(b?.close?.()), 5000, 'browser.close');
    try { b?.browser?.()?.process?.()?.kill('SIGKILL'); } catch {}
    try { b?.process?.()?.kill('SIGKILL'); } catch {}
    out.closed = 'browser-killed';
    contexts.clear();
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    setActiveContextName(null);
    setActiveMode(null);
    if (persistentUserDataDir) {
      try { rmSync(persistentUserDataDir, { recursive: true, force: true }); } catch {}
      setPersistentUserDataDir(null);
    }
    return out;
  }

  contexts.delete(name);

  if (lastPageInTabMode) {
    out.notes.push('last tab closed — browser torn down, next createContext relaunches it');
    await softDeadline(Promise.resolve(browser?.close?.()), 5000, 'browser.close');
    try { browser?.browser?.()?.process?.()?.kill('SIGKILL'); } catch {}
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    setActiveContextName(null);
    setActiveMode(null);
    if (persistentUserDataDir) {
      try { rmSync(persistentUserDataDir, { recursive: true, force: true }); } catch {}
      setPersistentUserDataDir(null);
    }
    return out;
  }

  // ── Park the active pointer on a survivor (or nothing). Deliberately NOT via
  // setActiveContext()/saveActiveSlot() — those would write the dying page back into a slot.
  if (activeContextName === name) {
    const survivor = (parkOn && contexts.has(parkOn)) ? parkOn : [...contexts.keys()][0];
    if (survivor) {
      activateSlot(survivor);
      if (recorder) { try { await recorder._attachPage(page); } catch { /* recording is best-effort */ } }
    } else {
      // No slots left: isConnected() goes false and engine calls fail fast until the next
      // ensureContext() recreates one. That is the intended contract, not a leak.
      setPage(null);
      setSessionPrefix(null);
      setSeanceId(null);
      setActiveContextName(null);
    }
  }
  return out;
}
