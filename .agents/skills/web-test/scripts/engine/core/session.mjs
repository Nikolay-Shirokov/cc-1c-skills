// web-test core/session v1.27 — Browser session lifecycle: connect/disconnect/attach/detach, multi-context registry.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { chromium } from 'playwright';
import { softDeadline } from './deadline.mjs';
import { statSync, mkdirSync, readdirSync, openSync, closeSync } from 'fs';
import { join as pathJoin, dirname } from 'path';
import { removePathSync } from './fsutil.mjs';
import { tmpdir, userInfo } from 'os';
import { spawnSync } from 'child_process';
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

/**
 * On Windows a Chromium that cannot start reports only "spawn UNKNOWN". The usual cause is the
 * side-by-side manifest next to chrome.exe (<version>.manifest): missing from the install, or not
 * readable by the current user (agent sandboxes). Append what we can establish to the first line
 * of the error — some callers print only that line. Silent when nothing is established.
 * Only after a failure: Windows caches the activation context of a chrome.exe that already ran,
 * so an unreadable manifest does not by itself mean a launch will fail.
 */
function explainLaunchFailure(e) {
  try {
    if (process.platform !== 'win32' || !/spawn UNKNOWN/.test(e?.message || '')) return e;
    const dir = dirname(chromium.executablePath());
    const manifests = readdirSync(dir).filter(f => f.toLowerCase().endsWith('.manifest'));
    let hint = null;
    if (manifests.length === 0) {
      hint = `Chromium side-by-side manifest (<version>.manifest) is missing next to chrome.exe in ${dir} — ` +
        'the browser install is incomplete. Reinstall: npx playwright install --force chromium';
    } else {
      for (const m of manifests) {
        try { closeSync(openSync(pathJoin(dir, m), 'r')); }
        catch (err) {
          if (err.code !== 'EPERM' && err.code !== 'EACCES') continue;
          hint = `${pathJoin(dir, m)} exists but is not readable by user ${userInfo().username} (${err.code}) — ` +
            'likely a sandbox/permissions restriction, not a broken install. Check the launch outside the sandbox';
          break;
        }
      }
    }
    if (hint) {
      const nl = e.message.indexOf('\n');
      e.message = nl < 0 ? `${e.message} — ${hint}` : `${e.message.slice(0, nl)} — ${hint}${e.message.slice(nl)}`;
    }
  } catch {}
  return e;
}

async function launchWithDiagnosis(fn) {
  try { return await fn(); }
  catch (e) { throw explainLaunchFailure(e); }
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

  if (evidence.kind === 'auth') {
    // The publication asks a human for credentials. The engine cannot answer, and until now it
    // did something worse than fail: it waited 66s and then closeModals()'s Escape dismissed the
    // dialog, leaving a blank page reported as a healthy start. Note a seance IS already created
    // here (unlike the licence case) and holds a licence — callers release it before rethrowing.
    throw new Error(
      `1C requires interactive login before the web client loads: "${oneLine(evidence.text)}"` +
      '\n  Publish the infobase with a user (web-publish -UserName … → Usr=/Pwd= in the vrd), or log in' +
      ' as a user: --user=/--password= for start/run, user/password in a webtest.config.mjs context,' +
      ' or the same options of connect()/createContext().' +
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
 * Credentials of the single-session (connect) path, kept so that a repeated connect() on a live
 * browser logs in again instead of landing as the publication's user. In memory only and never
 * returned by the engine API — scripts cannot read them (same for slot.creds).
 */
let connectCreds = null;

const oneLine = (s) => s.replace(/\s+/g, ' ').trim().slice(0, 300);

/**
 * Turn a refused POST <publication>/e1cib/start into a message. No seance exists at this point,
 * so there is nothing to release. The body is JSON ({"exception":{reason, descr}}); for 412 it is
 * an HTML page carrying the same JSON in <div id="exc"> (Apache) or XML <exception reason="…">
 * with <descr> (standalone server ibsrv). Names the user, never the password.
 *
 * Measured on 8.3.20–8.5.1 (file infobase, standard authentication): 402 — wrong name or
 * password; 412 — no right to run the web client; 403 and 400 with reason 9 — no free licence.
 */
function describeStartRefusal(status, body, url, user) {
  const text = body || '';
  let descr = '';
  const m = text.match(/"descr"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  const x = text.match(/<descr\b[^>]*>([^<]*)<\/descr>/);
  if (m) {
    try { descr = JSON.parse(`"${m[1]}"`); } catch { descr = m[1]; }
  } else if (x) {
    descr = x[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
  }
  // Second line is the platform's "Ошибка при выполнении запроса POST к ресурсу …" — noise.
  if (descr) descr = oneLine(descr.split('\n')[0]);
  const reason = (text.match(/"reason"\s*:\s*"?(\d+)/) || text.match(/\breason="(\d+)"/) || [])[1];
  const quoted = descr ? `: "${descr}"` : '';
  const tail = `\n  URL: ${url}`;
  if (status === 402) {
    return `1C rejected the credentials of user "${user}"${quoted}` +
      '\n  Check the user name and password.' + tail;
  }
  if (status === 412) {
    return `User "${user}" may not run the web client${quoted}` +
      '\n  The name and password are accepted, but no role of this user grants the web client.' +
      ' Log in as another user or extend the user\'s roles.' + tail;
  }
  if (status === 403 || (status === 400 && reason === '9')) {
    return `1C refused to start a seance for user "${user}": no free licence (HTTP ${status})${quoted}` +
      '\n  Release 1C sessions and retry.' + tail;
  }
  return `1C refused to log in user "${user}": HTTP ${status}${quoted}` + tail;
}

/**
 * Open the 1C web client in `pg`. Without credentials — a plain navigation, the publication
 * decides who logs in. With `creds.user` — a form POST to <url>/e1cib/start (Usr, Pwd,
 * AuthFailHandling=error), which logs in as that user even when the vrd names another one; the
 * platform answers 301 into the client, or an error status that is turned into a message here.
 * The form is built through DOM properties — the values never pass through HTML markup.
 * Launch parameters in the URL query (C=, L=, …) go into the form's action: the platform carries
 * them through the 301 into the client (measured on 8.3.20/24, 8.5.1); as form fields they are lost.
 */
async function navigateTo(pg, url, creds) {
  if (!creds?.user) {
    await pg.goto(url, { waitUntil: 'domcontentloaded', timeout: LOAD_TIMEOUT });
    return;
  }
  const u = new URL(url);
  const action = `${u.origin}${u.pathname.replace(/\/+$/, '')}/e1cib/start${u.search}`;
  await pg.goto('about:blank');
  const started = pg.waitForResponse(
    r => /\/e1cib\/start(?:[?#]|$)/.test(r.url()) && r.request().method() === 'POST',
    { timeout: LOAD_TIMEOUT });
  // submit() navigates away — the evaluate may lose its context; the response wait decides.
  let submitError = null;
  await pg.evaluate(({ action, fields }) => {
    const form = document.createElement('form');
    form.method = 'post';
    form.action = action;
    for (const [name, value] of fields) {
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = name;
      input.value = value;
      form.appendChild(input);
    }
    document.body.appendChild(form);
    form.submit();
  }, { action, fields: [['Usr', creds.user], ['Pwd', creds.password ?? ''], ['AuthFailHandling', 'error']] })
    .catch(e => { submitError = e; });
  let resp;
  try {
    resp = await started;
  } catch {
    throw new Error(`The login of user "${creds.user}" got no answer from ${action}` +
      (submitError ? ` — the login form was not submitted: ${oneLine(submitError.message)}` : '') +
      `
  URL: ${url}`);
  }
  if (resp.status() >= 400) {
    let body = '';
    try { body = await resp.text(); } catch {}
    throw new Error(describeStartRefusal(resp.status(), body, url, creds.user));
  }
  await pg.waitForLoadState('domcontentloaded', { timeout: LOAD_TIMEOUT }).catch(() => {});
}

/**
 * Open browser and navigate to 1C web client URL.
 * Waits for initialization (themesCell_theme_0 selector) and attempts to close startup modals.
 *
 * @param {string} url  publication URL
 * @param {object} [opts]
 * @param {string} [opts.extensionPath]  1C browser extension directory
 * @param {string} [opts.user]      log in as this infobase user instead of the publication's one
 * @param {string} [opts.password]  that user's password (omit for an empty one)
 */
export async function connect(url, { extensionPath, user, password } = {}) {
  // Kept only once the login succeeded: a failure before it must not leak into the next connect().
  const creds = user ? { user, password } : connectCreds;
  if (!isConnected()) {
    const extPath = findExtension(extensionPath);
    if (extPath) {
      // Launch with 1C browser extension via persistent context
      setPersistentUserDataDir(pathJoin(tmpdir(), 'pw-1c-ext-' + Date.now()));
      mkdirSync(persistentUserDataDir, { recursive: true });
      const context = await launchWithDiagnosis(() => chromium.launchPersistentContext(persistentUserDataDir, {
        headless: false,
        args: [
          '--start-maximized',
          '--disable-extensions-except=' + extPath,
          '--load-extension=' + extPath,
        ],
        viewport: null,
        permissions: ['clipboard-read', 'clipboard-write'],
      }));
      setBrowser(context); // persistent context IS the browser
      setPage(context.pages()[0] || await context.newPage());
    } else {
      // Fallback: launch without extension
      setBrowser(await launchWithDiagnosis(() => chromium.launch({ headless: false, args: ['--start-maximized'] })));
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
  }

  // Wait for 1C to initialize — or fail fast if the startup shell blocks the client.
  // MUST run before closeModals(): that presses Escape 5x, which dismisses the auth dialog and
  // destroys the evidence (measured — one Escape blanks the page).
  try {
    // A refused login throws from here too; the browser must not outlive it.
    await navigateTo(page, url, creds);
    await waitForClientOrStartupBlock(page, url);
  } catch (e) {
    // On the auth dialog a 1C seance already exists and holds a licence, and killing the process
    // does NOT release it. cmdStart has no catch and run.mjs does not wrap the command, so the
    // error escapes and the process dies — release the seance here, while we still can.
    await softDeadline(disconnect(), 20000, 'disconnect(startup-block)');
    throw e;
  }
  connectCreds = creds;

  // Try to close startup modals (Путеводитель etc.)
  await closeModals();

  return await getPageState();
}

/**
 * Best-effort POST /e1cib/logout on a slot to release the 1C session license.
 * Never throws: false when the page is closed, session info is missing, or the POST failed.
 * @param {object} slot   { page, sessionPrefix, seanceId } from contexts Map
 * @param {number} [waitMs=500]  pause after logout fetch (gives 1C time to process)
 */
async function logoutSlot(slot, waitMs = 500) {
  if (!slot?.page || slot.page.isClosed() || !slot.seanceId || !slot.sessionPrefix) return false;
  try {
    const logoutUrl = `${slot.sessionPrefix}/e1cib/logout?seanceId=${slot.seanceId}`;
    const status = await slot.page.evaluate(async (url) => {
      const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"root":{}}' });
      return r.status;
    }, logoutUrl);
    await slot.page.waitForTimeout(waitMs);
    return status >= 200 && status < 300;
  } catch {
    // A crashed renderer or a page torn down mid-call lands here — the caller falls back to
    // nodeLogout, which needs neither.
    return false;
  }
}

/**
 * Gracefully terminate the 1C session and close the browser.
 * Sends POST /e1cib/logout to release the license before closing.
 */
export async function disconnect() {
  const wasMultiContext = contexts.size > 0;
  connectCreds = null;

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
      if (!(own.ok && own.value)) await nodeLogout(slot, 3000);
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
      const slot = { page, sessionPrefix, seanceId };
      const own = await softDeadline(logoutSlot(slot, 1000), 4000, 'logoutSlot');
      if (!(own.ok && own.value)) await nodeLogout(slot, 3000);
    }
    await shutdownBrowser(browser);
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    // Clean up persistent user data dir
    if (persistentUserDataDir) {
      try { removePathSync(persistentUserDataDir); } catch {}
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
 *
 * Options: extensionPath, isolation ('tab' | 'window'), user/password — log the slot in as that
 * infobase user (see navigateTo). Re-creating an existing slot reuses its login unless a new
 * user is passed. Different users coexist in either isolation mode: the 1C seance is per page.
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
  try {
    // A refused login (slot.creds) is a startup block as well: same teardown.
    await navigateTo(page, url, contexts.get(name)?.creds);
    await waitForClientOrStartupBlock(page, url);
  } catch (e) {
    await softDeadline(abortContext(name), 10000, 'abortContext(startup-block)');
    throw e;
  }
  await closeModals();
  return await getPageState();
}

export async function createContext(name, url, { extensionPath, isolation = 'tab', user, password } = {}) {
  if (contexts.has(name)) {
    await setActiveContext(name);
    if (user) contexts.get(name).creds = { user, password };
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
      setBrowser(await launchWithDiagnosis(() => chromium.launchPersistentContext(persistentUserDataDir, {
        headless: false,
        args: launchArgs,
        viewport: null,
        permissions: ['clipboard-read', 'clipboard-write'],
      })));
    } else {
      // Window mode: separate BrowserContext per slot, full cookie isolation
      setBrowser(await launchWithDiagnosis(() => chromium.launch({ headless: false, args: launchArgs })));
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
    // Login of this slot (null — the publication's user); in memory only, reused on re-open.
    creds: user ? { user, password } : null,
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
 * Shut a browser (Browser or persistent BrowserContext) down without leaving processes behind.
 *
 * A renderer stuck in a JS loop survives everything graceful (measured on Windows): closing its
 * page succeeds yet leaves the process alive, browser.close() then hangs, the browser process
 * exits on its own and the renderer is orphaned, spinning a core forever. By then the tree is
 * gone and taskkill /T has no root to walk. So the wedge is detected up front and the tree
 * killed while the browser process is still alive. Playwright's Browser exposes no process()
 * for chromium.launch(); the pid comes from CDP — served by the browser process, it answers
 * even while a renderer is wedged.
 *
 * The same orphan appears when the wedged page was closed just before (abortContext closing the
 * last tab): the browser drops the renderer from its own list at once but needs a moment to
 * terminate it — shut the browser down in that moment and the renderer outlives it, invisible
 * to CDP. Only the OS still knows it as a child of the browser, so abortContext snapshots the
 * children before that close and reaps the survivors after (browserChildren/reapOrphans) — not
 * done here, where every page answered its probe: the snapshot costs a PowerShell run.
 * @returns {Promise<boolean>} true when the browser closed gracefully
 */
async function shutdownBrowser(b, closeMs = 10000) {
  if (!b) return true;
  const pid = await softDeadline(browserPid(b), 2000, 'browserPid');
  const root = pid.ok ? pid.value : null;
  const pages = typeof b.pages === 'function' ? b.pages() : (b.contexts?.() || []).flatMap(c => c.pages());
  for (const p of pages) {
    if (p.isClosed()) continue;
    // Only a breached deadline means a wedge; a rejection ("Execution context was destroyed"
    // mid-navigation) is a live renderer and gets the graceful close.
    const alive = await softDeadline(p.evaluate(() => 1), 1000, 'renderer probe');
    if (alive.timedOut && root) {
      killProcessTree(root);
      return false;
    }
  }
  const closed = await softDeadline(Promise.resolve(b.close()), closeMs, 'browser.close');
  if (!closed.ok && root) killProcessTree(root);
  return closed.ok;
}

async function browserPid(b) {
  const root = b.browser?.() || b;
  if (typeof root.newBrowserCDPSession !== 'function') return null;
  const cdp = await root.newBrowserCDPSession();
  try {
    const { processInfo } = await cdp.send('SystemInfo.getProcessInfo');
    return processInfo.find(p => p.type === 'browser')?.id ?? null;
  } finally {
    await cdp.detach().catch(() => {});
  }
}

function killProcessTree(pid) {
  if (!pid) return;
  if (process.platform === 'win32') {
    // taskkill /T walks the tree while the root is alive; TerminateProcess alone would orphan
    // the renderers.
    spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { timeout: 5000, stdio: 'ignore', windowsHide: true });
  } else {
    try { process.kill(pid, 'SIGKILL'); } catch {}
  }
}

/** chrome.exe processes as [{ pid, parent }] — Windows only (elsewhere children die with the browser). */
function chromeProcesses() {
  if (process.platform !== 'win32') return [];
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId)\" }"],
    { encoding: 'utf8', timeout: 10000, windowsHide: true });
  return (r.stdout || '').split(/\r?\n/).map(l => l.trim().split(/\s+/).map(Number))
    .filter(([pid, parent]) => pid && parent).map(([pid, parent]) => ({ pid, parent }));
}

/** Child processes of a live browser, for reapOrphans() after it is gone. */
async function browserChildren(b) {
  if (!b || process.platform !== 'win32') return [];
  const pid = await softDeadline(browserPid(b), 2000, 'browserPid');
  return pid.ok && pid.value ? descendantPids(pid.value) : [];
}

/** All descendants of `root` as [{ pid, parent }]. */
function descendantPids(root) {
  const all = chromeProcesses();
  const tree = new Set([root]);
  const out = [];
  for (let grew = true; grew;) {
    grew = false;
    for (const p of all) {
      if (!tree.has(p.pid) && tree.has(p.parent)) { tree.add(p.pid); out.push(p); grew = true; }
    }
  }
  return out;
}

/** Kill those of `children` still running under the same parent — a reused pid has another one. */
function reapOrphans(children) {
  if (!children.length) return;
  const now = new Map(chromeProcesses().map(p => [p.pid, p.parent]));
  const left = children.filter(c => now.get(c.pid) === c.parent).map(c => c.pid);
  if (!left.length) return;
  spawnSync('taskkill', ['/F', ...left.flatMap(p => ['/PID', String(p)])], { timeout: 5000, stdio: 'ignore', windowsHide: true });
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
      if (own.ok && own.value) {
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
  // Closing that last tab takes Chromium down at once — too fast to terminate a wedged renderer,
  // which then outlives it (see shutdownBrowser). The browser is gone before shutdownBrowser
  // could look, so its children are snapshotted here.
  const preClose = lastPageInTabMode ? await browserChildren(browser) : [];

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
    await shutdownBrowser(browser, 5000);
    reapOrphans(preClose);
    out.closed = 'browser-killed';
    contexts.clear();
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    setActiveContextName(null);
    setActiveMode(null);
    if (persistentUserDataDir) {
      try { removePathSync(persistentUserDataDir); } catch {}
      setPersistentUserDataDir(null);
    }
    return out;
  }

  contexts.delete(name);

  if (lastPageInTabMode) {
    out.notes.push('last tab closed — browser torn down, next createContext relaunches it');
    await shutdownBrowser(browser, 5000);
    reapOrphans(preClose);
    setBrowser(null);
    setPage(null);
    setSessionPrefix(null);
    setSeanceId(null);
    setActiveContextName(null);
    setActiveMode(null);
    if (persistentUserDataDir) {
      try { removePathSync(persistentUserDataDir); } catch {}
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
