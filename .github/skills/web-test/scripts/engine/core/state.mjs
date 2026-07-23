// web-test core/state v1.18 — module-level state for the web-test engine.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Holds the single browser/page/recorder slot plus the multi-context registry,
// constants, and small state-only utilities (ensureConnected, getPage,
// resolveProjectPath, normYo). Mutable values are exported as `let` bindings
// for live read access from consumer modules; writes go through setters so
// imported bindings stay read-only at the import site.

import { dirname, resolve as pathResolve } from 'path';
import { fileURLToPath } from 'url';

// Project root: 6 levels up from .claude/skills/web-test/scripts/engine/core/state.mjs
const __fn_state = fileURLToPath(import.meta.url);
export const projectRoot = pathResolve(dirname(__fn_state), '..', '..', '..', '..', '..', '..');

/** Resolve a user-provided path relative to the project root (not cwd). */
export const resolveProjectPath = (p) => pathResolve(projectRoot, p);

// ──────────────────────────────────────────────────────────────────────────
// Mutable single-session state. Importers read via the live binding; writes
// must go through the corresponding setter (ESM imports are read-only).
// ──────────────────────────────────────────────────────────────────────────

export let browser = null;
export let page = null;
export let sessionPrefix = null; // e.g. "http://localhost:8081/bpdemo/ru_RU"
export let seanceId = null;
export let recorder = null; // { cdp, ffmpeg, startTime, outputPath, ffmpegError, captions }
export let lastCaptions = []; // captions from the last completed recording (for addNarration)
export let lastRecordingDuration = null; // wall-clock duration of the last recording (seconds)
export let highlightMode = false;
export let persistentUserDataDir = null; // temp dir for launchPersistentContext, cleaned on disconnect

// Clipboard preservation: save full clipboard contents (all MIME types) right
// before each writeText+Ctrl+V pair, restore right after. Toggled via
// setPreserveClipboard() from run.mjs.
export let preserveClipboard = true;
export let clipboardWarnLogged = false;

export const setBrowser = (v) => { browser = v; };
export const setPage = (v) => { page = v; };
export const setSessionPrefix = (v) => { sessionPrefix = v; };
export const setSeanceId = (v) => { seanceId = v; };
export const setRecorder = (v) => { recorder = v; };
export const setLastCaptions = (v) => { lastCaptions = v; };
export const setLastRecordingDuration = (v) => { lastRecordingDuration = v; };
export const setHighlightMode = (v) => { highlightMode = !!v; };
export const setPersistentUserDataDir = (v) => { persistentUserDataDir = v; };
export const setPreserveClipboard = (v) => { preserveClipboard = !!v; };
export const setClipboardWarnLogged = (v) => { clipboardWarnLogged = !!v; };

// ──────────────────────────────────────────────────────────────────────────
// Multi-context registry: name → { context, page, sessionPrefix, seanceId,
// recorder, lastCaptions, lastRecordingDuration, highlightMode }.
// Populated by createContext(); module-level vars above mirror the active
// slot. connect() does NOT use this Map — it preserves legacy single-session
// behavior for exec/run/start.
// ──────────────────────────────────────────────────────────────────────────

export const contexts = new Map();
export let activeContextName = null;
// Isolation mode for the current cmdTest session — set by the first
// createContext call. 'tab': all contexts share one persistent context
// (one window, multiple tabs, extension loads reliably). 'window': each
// context gets its own BrowserContext (separate window per context, full
// cookie isolation, extension may not load).
export let activeMode = null;

export const setActiveContextName = (v) => { activeContextName = v; };
export const setActiveMode = (v) => { activeMode = v; };

// ──────────────────────────────────────────────────────────────────────────
// Constants.
// ──────────────────────────────────────────────────────────────────────────

export const LOAD_TIMEOUT = 60000;
export const INIT_TIMEOUT = 60000;
export const ACTION_WAIT = 2000;   // fallback minimum wait
export const MAX_WAIT = 10000;     // max wait for stability
export const POLL_INTERVAL = 200;  // polling interval
export const STABLE_CYCLES = 3;    // consecutive stable cycles needed
// Ceiling for the case where 1C is VISIBLY still working (its "Поиск…" state window is up).
// Higher than MAX_WAIT on purpose: a search on a production-sized list legitimately runs for
// tens of seconds, and returning mid-search hands the caller the previous rows — a wrong
// result that looks like a right one. Bounded so a wedged operation still ends the wait.
export const BUSY_MAX_WAIT = 60000;

// 1C browser extension ID (stable across versions, defined by key in manifest.json)
export const EXT_ID = 'pbhelknnhilelbnhfpcjlcabhmfangik';

// ──────────────────────────────────────────────────────────────────────────
// Utilities that only depend on state.
// ──────────────────────────────────────────────────────────────────────────

/** Normalize ё→е and  →space for fuzzy matching. */
export const normYo = (s) => s.replace(/ё/gi, 'е').replace(/ /g, ' ');

/** Check if browser is connected and page is usable. */
export function isConnected() {
  if (!browser || !page || page.isClosed()) return false;
  // launchPersistentContext returns BrowserContext (no isConnected), launch returns Browser
  if (typeof browser.isConnected === 'function') return browser.isConnected();
  // For persistent context, check via context's browser()
  return browser.browser()?.isConnected() ?? false;
}

export function ensureConnected() {
  if (!isConnected()) {
    throw new Error('Browser not connected. Call web_connect first.');
  }
}

/** Get the raw Playwright page object (for advanced scripting in skill mode). */
export function getPage() {
  ensureConnected();
  return page;
}
