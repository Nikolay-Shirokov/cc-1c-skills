// web-test web/pages v1.1 — other web pages in a session: an adjacent system next to 1C, a video without 1C.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// One namespace `web` (open, highlight, unhighlight, mask, saveLogin) plus connectWeb for `start --web`.
// Nothing here touches the 1C steps of the engine: a web page is opened, waited for and left alone (no 1C client
// wait, no Escape on modals, no 1C login). Switching between pages is the existing setActiveContext; actions on
// a page are Playwright through getPage().

import { chromium } from 'playwright';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'fs';
import { dirname } from 'path';
import { page, setBrowser, setPage, isConnected, ensureConnected, resolveProjectPath } from '../core/state.mjs';
import { registerPageContext, setActiveContext, hasContext, listWebContexts } from '../core/session.mjs';
import { unhighlight } from '../recording/highlight.mjs';

const LOAD_MS = 60000, READY_MS = 30000;

// What web analytics sends (not its loaders — a site may show things through a tag manager). Such a request can
// stay open for good (a click map), and then a page never goes network-idle; a recording also must not count
// as a visit. Cut at once: for the site it is as with an ad blocker. 1C pages are not touched.
const ANALYTICS = [
  [/^mc\.yandex\.[a-z.]+$/, (p) => !p.startsWith('/metrika/')],          // Yandex Metrica beacons (watch, clmap, webvisor)
  [/(^|\.)google-analytics\.com$|^analytics\.google\.com$/, (p) => /\/collect\b/.test(p)],
  [/^top-fwz1\.mail\.ru$/, () => true],                                   // Top.Mail.Ru counter
  [/^(in|vc|content)\.hotjar\.(com|io)$/, () => true],
  [/(^|\.)clarity\.ms$/, (p) => /\/collect\b/.test(p)],
  [/^www\.facebook\.com$/, (p) => p === '/tr' || p.startsWith('/tr/')],
];
const isAnalytics = (url) => ANALYTICS.some(([host, path]) => host.test(url.hostname) && path(url.pathname));
const cutAnalytics = (target) => target.route(isAnalytics, (route) => route.abort('blockedbyclient').catch(() => {}));

function loginState(login) {
  if (login === undefined) return null;
  const abs = resolveProjectPath(login);
  if (!existsSync(abs)) throw new Error(`web: login file not found: ${abs} — log in by hand in the window and web.saveLogin('${login}')`);
  try { return { abs, state: JSON.parse(readFileSync(abs, 'utf8')) }; } catch (e) { throw new Error(`web: login file ${abs} is not a saved login: ${e.message}`); }
}

async function openWeb(pg, url, ready) {
  await pg.goto(url, { waitUntil: 'load', timeout: LOAD_MS });
  if (ready) await pg.locator(ready).first().waitFor({ timeout: READY_MS });
  return { url: pg.url(), title: await pg.title().catch(() => '') };
}

/**
 * A session on a web page (`start <url> --web`): a visible window, no 1C. `login` — a file saved by web.saveLogin;
 * without it the person logs in by hand in the window. `ready` — a CSS selector to wait for.
 */
export async function connectWeb(url, { login, ready } = {}) {
  if (isConnected()) throw new Error('web: a session is already open');
  const saved = loginState(login);
  const b = await chromium.launch({ headless: false, args: ['--start-maximized'] });
  try {
    const ctx = await b.newContext({ viewport: null, ...(saved ? { storageState: saved.abs } : {}) });
    await cutAnalytics(ctx);
    const pg = await ctx.newPage();
    setBrowser(b);
    setPage(pg);
    return { web: true, ...(await openWeb(pg, url, ready)) };
  } catch (e) {
    setPage(null);
    setBrowser(null);
    await b.close().catch(() => {});
    throw e;
  }
}

/**
 * Open a web page as a context `name` — a tab in the session's window (the video keeps its size); the first call
 * after a 1C session registers the 1C page as `main`. Again with the same name — go to `url` there.
 */
async function open(name, url, { login, ready } = {}) {
  ensureConnected();
  if (typeof name !== 'string' || !name.trim()) throw new Error('web.open(name, url): a context name is required');
  if (typeof url !== 'string' || !url.trim()) throw new Error('web.open(name, url): a url is required');
  if (hasContext(name)) {
    if (!listWebContexts().includes(name)) throw new Error(`web.open: "${name}" is a 1C context — give the web page a name of its own`);
    await setActiveContext(name);
    return openWeb(page, url, ready);
  }
  const saved = loginState(login);
  const ctx = page.context();
  if (saved?.state.cookies?.length) await ctx.addCookies(saved.state.cookies);
  const pg = await ctx.newPage();
  await cutAnalytics(pg);   // this tab only: the 1C page shares the context
  // localStorage of the saved login: set before the site's own scripts read it (a tab shares the context),
  // once per tab — later loads keep what the site has stored since (a refreshed token)
  if (saved?.state.origins?.length) {
    await pg.addInitScript((origins) => {
      const o = origins.find((x) => x.origin === location.origin);
      try { if (!o || sessionStorage.getItem('__webTestLogin')) return; sessionStorage.setItem('__webTestLogin', '1'); } catch { return; }
      for (const { name: k, value } of o.localStorage || []) try { localStorage.setItem(k, value); } catch {}
    }, saved.state.origins);
  }
  registerPageContext(name, pg, { context: ctx, closeBy: 'page', web: true });
  await setActiveContext(name);
  return openWeb(pg, url, ready);
}

/** A frame around an element of the active page (a Playwright Locator); web.unhighlight() / unhighlight() removes it. */
async function highlight(target, { color = '#e74c3c', padding = 4 } = {}) {
  ensureConnected();
  if (!target || typeof target.elementHandle !== 'function') {
    throw new Error('web.highlight(locator): pass a Playwright Locator, e.g. getPage().getByText(\'Заказ\'); for 1C forms — highlight(text)');
  }
  const el = await target.first().elementHandle({ timeout: 10000 });
  await unhighlight();   // one frame at a time: the previous one and its drawing loop go
  await el.evaluate((node, { color, padding }) => {
    let div = document.getElementById('__web_test_highlight');
    if (!div) { div = document.createElement('div'); div.id = '__web_test_highlight'; document.body.appendChild(div); }
    const sync = () => {
      const r = node.getBoundingClientRect();
      div.style.cssText = ['position:fixed', 'pointer-events:none', 'z-index:999998',
        `top:${r.y - padding}px`, `left:${r.x - padding}px`, `width:${r.width + padding * 2}px`, `height:${r.height + padding * 2}px`,
        `outline:3px solid ${color}`, 'border-radius:4px', `box-shadow:0 0 16px ${color}80`].join(';');
    };
    sync();
    const tick = () => { if (!div.isConnected) return; sync(); requestAnimationFrame(tick); };   // this frame only
    requestAnimationFrame(tick);
  }, { color, padding });
}

/**
 * Hide parts of the active page while recording: CSS selectors (the element and all inside it) and { text } (the
 * element holding that text). It holds after the page changes and reloads. Works on 1C pages too.
 */
async function mask(targets) {
  ensureConnected();
  const list = [].concat(targets || []);
  const selectors = list.filter((x) => typeof x === 'string');
  const texts = list.filter((x) => x && typeof x === 'object' && typeof x.text === 'string').map((x) => x.text);
  if (selectors.length + texts.length !== list.length || !list.length) {
    throw new Error("web.mask(targets): CSS selectors and { text: '…' }, e.g. web.mask(['.user-menu', { text: 'Иванов' }])");
  }
  // Also runs at the very start of each load (no <html> yet). One state per document: the targets of every
  // call are merged, one observer, at most one pass per frame — a 1C page changes its DOM all the time.
  const apply = ({ selectors, texts }) => {
    const m = (window.__webTestMask ||= { selectors: new Set(), texts: new Set(), queued: false });
    selectors.forEach((x) => m.selectors.add(x));
    texts.forEach((x) => m.texts.add(x));
    const run = () => {
      m.queued = false;
      const root = document.head || document.documentElement;
      if (!root) return;
      // the element and all inside it — a descendant's own `visibility: visible` would show through
      const css = [...m.selectors].map((x) => `:is(${x}), :is(${x}) *{visibility:hidden !important}`).join('\n');
      let st = document.getElementById('__web_test_mask');
      if (css && !st) { st = document.createElement('style'); st.id = '__web_test_mask'; }
      if (st) { if (st.textContent !== css) st.textContent = css; if (st.parentNode !== root) root.appendChild(st); }
      if (!m.texts.size || !document.body) return;
      // text nodes, so text next to an icon or in a mixed element is found too; its element is hidden
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        const el = n.parentElement;
        if (!el || el.style.visibility === 'hidden') continue;
        for (const t of m.texts) if (n.nodeValue.includes(t)) { el.style.setProperty('visibility', 'hidden', 'important'); break; }
      }
    };
    const queue = () => { if (!m.queued) { m.queued = true; requestAnimationFrame(run); } };
    if (!m.observer) {
      m.observer = new MutationObserver(queue);
      m.observer.observe(document, { childList: true, subtree: true, characterData: true });
      document.addEventListener('DOMContentLoaded', run);
    }
    run();
  };
  await page.addInitScript(apply, { selectors, texts });
  await page.evaluate(apply, { selectors, texts });
}

/**
 * Save the active page's login — the cookies and localStorage of its site only (a tab shares the context with
 * 1C: its seance must not travel into the file and back over a live one). The file is the user's session.
 */
async function saveLogin(path) {
  ensureConnected();
  if (typeof path !== 'string' || !path.trim()) throw new Error("web.saveLogin(path): a file path, e.g. 'debug/crm-login.json'");
  const here = new URL(page.url());
  // the cookies this page sends (by domain and path): a 1C publication on the same host keeps its own path
  const cookies = await page.context().cookies(page.url());
  const { origins } = await page.context().storageState();
  const state = { cookies, origins: origins.filter((o) => o.origin === here.origin) };
  const abs = resolveProjectPath(path);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, JSON.stringify(state, null, 2));
  return { file: abs, site: here.origin, cookies: state.cookies.length };
}

export const web = { open, highlight, unhighlight, mask, saveLogin };
