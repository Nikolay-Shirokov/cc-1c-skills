#!/usr/bin/env node
// web-test run v1.10 — CLI runner for 1C web client automation
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * CLI runner for 1C web client automation.
 *
 * Architecture: `start` launches browser + HTTP server in one process.
 * `exec`, `shot`, `stop` send requests to the running server.
 *
 * Usage:
 *   node src/run.mjs start <url>            — launch browser, connect to 1C, serve requests
 *   node src/run.mjs run <url> <file|->     — autonomous: connect, execute script, disconnect
 *   node src/run.mjs exec <file|->          — run script against existing session
 *   node src/run.mjs shot [file]            — take screenshot
 *   node src/run.mjs stop                   — logout + close browser
 *   node src/run.mjs status                 — check session
 *   node src/run.mjs test [url] <dir|file>  — run regression tests
 */
import http from 'http';
import * as browser from './browser.mjs';
import { readFileSync, writeFileSync, unlinkSync, existsSync, readdirSync, mkdirSync } from 'fs';
import { resolve, dirname, basename, relative } from 'path';
import { fileURLToPath } from 'url';
import { randomUUID } from 'crypto';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSION_FILE = resolve(__dirname, '..', '.browser-session.json');

const [,, cmd, ...rawArgs] = process.argv;
const flags = { noRecord: rawArgs.includes('--no-record') };
const args = rawArgs.filter(a => !a.startsWith('--'));

switch (cmd) {
  case 'start':  await cmdStart(args[0]); break;
  case 'run':    await cmdRun(args[0], args[1]); break;
  case 'exec':   await cmdExec(args[0], flags); break;
  case 'shot':   await cmdShot(args[0]); break;
  case 'stop':   await cmdStop(); break;
  case 'status': cmdStatus(); break;
  case 'test':   await cmdTest(rawArgs); break;
  default:       usage();
}


// ============================================================
// start: launch browser + HTTP server
// ============================================================

async function cmdStart(url) {
  if (!url) die('Usage: node src/run.mjs start <url>');

  // Connect to 1C
  const state = await browser.connect(url);

  // Start HTTP server for exec/shot/stop
  const httpServer = http.createServer(handleRequest);
  httpServer.listen(0, '127.0.0.1', () => {
    const port = httpServer.address().port;
    const session = {
      port,
      url,
      pid: process.pid,
      startedAt: new Date().toISOString()
    };
    writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2));
    out({ ok: true, message: 'Browser ready', port, ...state });
  });

  process.on('SIGINT', async () => {
    await browser.disconnect();
    cleanup();
    process.exit(0);
  });
}

async function handleRequest(req, res) {
  try {
    if (req.method === 'POST' && req.url === '/exec') {
      const code = await readBody(req);
      const noRecord = req.headers['x-no-record'] === '1';
      const result = await executeScript(code, { noRecord });
      json(res, result);

    } else if (req.method === 'GET' && req.url === '/shot') {
      const png = await browser.screenshot();
      res.writeHead(200, { 'Content-Type': 'image/png' });
      res.end(png);

    } else if (req.method === 'POST' && req.url === '/stop') {
      json(res, { ok: true, message: 'Stopping' });
      await browser.disconnect();
      cleanup();
      process.exit(0);

    } else if (req.method === 'GET' && req.url === '/status') {
      json(res, { ok: true, connected: browser.isConnected() });

    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  } catch (e) {
    json(res, { ok: false, error: e.message }, 500);
  }
}

// ============================================================
// buildContext: assemble browser API with error wrapping
// ============================================================

/**
 * Build a per-context wrapper: same shape as buildContext output, but every call
 * is prefixed with `setActiveContext(name)` so the test can interleave actions
 * across contexts (`ctx.a.click(...); ctx.b.click(...)`).
 */
function buildScopedContext(name) {
  const inner = buildContext({ noRecord: false });
  const scoped = {};
  for (const [k, v] of Object.entries(inner)) {
    if (typeof v === 'function') {
      scoped[k] = async (...args) => {
        await browser.setActiveContext(name);
        return v(...args);
      };
    } else {
      scoped[k] = v;
    }
  }
  return scoped;
}

function buildContext({ noRecord = false } = {}) {
  const ctx = {};
  for (const [k, v] of Object.entries(browser)) {
    if (k !== 'default') ctx[k] = v;
  }
  ctx.writeFileSync = writeFileSync;
  ctx.readFileSync = readFileSync;

  // --no-record: stub recording/narration functions to return safe defaults
  if (noRecord) {
    const noop = async () => {};
    ctx.startRecording = noop;
    ctx.stopRecording = async () => ({ file: null, duration: 0, size: 0 });
    ctx.addNarration = async () => ({ file: null, duration: 0, size: 0, captions: 0 });
    for (const fn of ['showCaption', 'hideCaption']) {
      ctx[fn] = noop;
    }
    ctx.isRecording = () => false;
    ctx.getCaptions = () => [];
  }

  // Wrap action functions to auto-detect 1C errors (modal, balloon)
  // and stop execution immediately with diagnostic info
  const ACTION_FNS = [
    'clickElement', 'fillFields', 'fillField', 'selectValue', 'fillTableRow',
    'deleteTableRow', 'openCommand', 'navigateSection', 'navigateLink', 'openFile',
    'closeForm', 'filterList', 'unfilterList'
  ];
  for (const name of ACTION_FNS) {
    if (typeof ctx[name] !== 'function') continue;
    const orig = ctx[name];
    ctx[name] = async (...args) => {
      const result = await orig(...args);
      const errors = result?.errors;
      if (errors?.modal || errors?.balloon) {
        // Screenshot while the error modal is still visible (before fetchErrorStack closes it)
        let errorShot;
        try {
          const png = await ctx.screenshot();
          errorShot = resolve(__dirname, '..', 'error-shot.png');
          writeFileSync(errorShot, png);
        } catch {}
        // Try to fetch call stack for modal errors before throwing
        let stack = null;
        if (errors?.modal && typeof ctx.fetchErrorStack === 'function') {
          try {
            stack = await ctx.fetchErrorStack(errors.modal.formNum, errors.modal.hasReport);
          } catch { /* don't fail if stack fetch fails */ }
        }
        const msg = errors.modal?.message || errors.balloon?.message || 'Unknown 1C error';
        const err = new Error(msg);
        err.onecError = { step: name, args, errors, formState: result, stack, screenshot: errorShot };
        throw err;
      }
      return result;
    };
  }

  return ctx;
}


async function executeScript(code, { noRecord } = {}) {
  const output = [];
  const origLog = console.log;
  const origErr = console.error;
  console.log = (...a) => output.push(a.map(String).join(' '));
  console.error = (...a) => output.push('[ERR] ' + a.map(String).join(' '));

  const t0 = Date.now();
  try {
    const ctx = buildContext({ noRecord });

    // Normalize Windows backslash paths to prevent JS parse errors
    // (e.g. C:\Users\... → \u triggers "Invalid Unicode escape sequence")
    code = code.replace(/[A-Za-z]:\\[^\s'"`;\n)}\]]+/g, m => m.replace(/\\/g, '/'));

    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    const fn = new AsyncFunction(...Object.keys(ctx), code);
    await fn(...Object.values(ctx));

    console.log = origLog;
    console.error = origErr;
    return { ok: true, output: output.join('\n'), elapsed: elapsed(t0) };
  } catch (e) {
    console.log = origLog;
    console.error = origErr;

    // Auto-stop recording if active (prevents "Already recording" on next exec)
    if (browser.isRecording()) {
      try { await browser.stopRecording(); } catch {}
    }

    // Error screenshot (skip if already taken before fetchErrorStack closed the modal)
    let shotFile = e.onecError?.screenshot;
    if (!shotFile) {
      try {
        const png = await browser.screenshot();
        shotFile = resolve(__dirname, '..', 'error-shot.png');
        writeFileSync(shotFile, png);
      } catch {}
    }

    const result = { ok: false, error: e.message, output: output.join('\n'), screenshot: shotFile, elapsed: elapsed(t0) };

    // Enrich with 1C error context if available
    if (e.onecError) {
      result.step = e.onecError.step;
      result.stepArgs = e.onecError.args;
      result.onecErrors = e.onecError.errors;
      result.formState = e.onecError.formState;
      if (e.onecError.stack) result.stack = e.onecError.stack;
    }

    return result;
  }
}


// ============================================================
// run: autonomous connect → execute → disconnect (no server)
// ============================================================

async function cmdRun(url, fileOrDash) {
  if (!url || !fileOrDash) die('Usage: node src/run.mjs run <url> <file|->');

  const code = fileOrDash === '-'
    ? await readStdin()
    : readFileSync(resolve(fileOrDash), 'utf-8');

  await browser.connect(url);
  const result = await executeScript(code);
  await browser.disconnect();

  out(result);
  if (!result.ok) process.exit(1);
}


// ============================================================
// exec: send script to running server
// ============================================================

async function cmdExec(fileOrDash, flags = {}) {
  if (!fileOrDash) die('Usage: node src/run.mjs exec <file|-> [--no-record]');

  let code = fileOrDash === '-'
    ? await readStdin()
    : readFileSync(resolve(fileOrDash), 'utf-8');

  const sess = loadSession();
  const headers = {};
  if (flags.noRecord) headers['x-no-record'] = '1';
  const result = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: sess.port, path: '/exec',
      method: 'POST', timeout: 30 * 60 * 1000, headers,
    }, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { reject(new Error(data)); } });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(new Error('Exec timeout (10 min)')); });
    req.write(code);
    req.end();
  });
  out(result);
  if (!result.ok) process.exit(1);
}


// ============================================================
// shot: take screenshot via server
// ============================================================

async function cmdShot(file) {
  const sess = loadSession();
  const resp = await fetch(`http://127.0.0.1:${sess.port}/shot`);
  if (!resp.ok) {
    const err = await resp.text();
    die(`Screenshot failed: ${err}`);
  }
  const buf = Buffer.from(await resp.arrayBuffer());
  const outFile = file || 'shot.png';
  writeFileSync(outFile, buf);
  out({ ok: true, file: outFile });
}


// ============================================================
// stop: send stop to server
// ============================================================

async function cmdStop() {
  const sess = loadSession();
  try {
    const resp = await fetch(`http://127.0.0.1:${sess.port}/stop`, { method: 'POST' });
    const result = await resp.json();
    out(result);
  } catch {
    // Server may have already exited before responding
    out({ ok: true, message: 'Stopped' });
  }
  cleanup();
}


// ============================================================
// status: check session
// ============================================================

function cmdStatus() {
  if (!existsSync(SESSION_FILE)) {
    out({ ok: false, message: 'No active session' });
    process.exit(1);
  }
  const sess = JSON.parse(readFileSync(SESSION_FILE, 'utf-8'));
  out({ ok: true, ...sess });
}


// ============================================================
// test: run regression tests
// ============================================================

async function cmdTest(rawArgs) {
  // Parse flags
  const opts = { bail: false, retry: 0, timeout: 30000, report: null, format: 'json', screenshot: null, reportDir: null, record: false };
  let tags = null, grep = null;
  const positional = [];
  for (const a of rawArgs) {
    if (a.startsWith('--tags='))       tags = a.slice(7).split(',');
    else if (a.startsWith('--grep='))  grep = new RegExp(a.slice(7), 'i');
    else if (a === '--bail')           opts.bail = true;
    else if (a.startsWith('--retry=')) opts.retry = parseInt(a.slice(8)) || 0;
    else if (a.startsWith('--timeout=')) opts.timeout = parseInt(a.slice(10)) || 30000;
    else if (a.startsWith('--report=')) opts.report = a.slice(9);
    else if (a.startsWith('--format=')) opts.format = a.slice(9);
    else if (a.startsWith('--screenshot=')) opts.screenshot = a.slice(13);
    else if (a.startsWith('--report-dir=')) opts.reportDir = a.slice(13);
    else if (a === '--record')         opts.record = true;
    else if (!a.startsWith('--'))      positional.push(a);
  }

  // Determine URL and test path
  let url, testPath;
  if (positional.length === 2) {
    url = positional[0];
    testPath = resolve(positional[1]);
  } else if (positional.length === 1) {
    testPath = resolve(positional[0]);
  } else {
    die('Usage: node run.mjs test [url] <dir|file> [--tags=...] [--bail] [--retry=N] [--timeout=ms] [--report=path]');
  }

  // Load config if exists
  const isFile = testPath.endsWith('.test.mjs');
  const testDir = isFile ? dirname(testPath) : testPath;
  const configPath = resolve(testDir, 'webtest.config.mjs');
  let config = {};
  if (existsSync(configPath)) {
    const mod = await import('file:///' + configPath.replace(/\\/g, '/'));
    config = mod.default || {};
  }
  // Build context registry: name → url. Supports config.contexts or single config.url / CLI url.
  // CLI url overrides default context's url.
  const contextSpecs = {}; // name → { url, isolation }
  let defaultContextName = 'default';
  const defaultIsolation = config.isolation || 'tab';
  if (config.contexts && typeof config.contexts === 'object' && Object.keys(config.contexts).length) {
    for (const [n, spec] of Object.entries(config.contexts)) {
      contextSpecs[n] = { url: spec.url, isolation: spec.isolation };
    }
    defaultContextName = config.defaultContext || Object.keys(config.contexts)[0];
    if (url) contextSpecs[defaultContextName] = { url }; // CLI override of default
  } else {
    const fallbackUrl = url || config.url;
    if (!fallbackUrl) die('No URL provided and no webtest.config.mjs found');
    contextSpecs.default = { url: fallbackUrl };
  }
  if (!contextSpecs[defaultContextName]) {
    die(`defaultContext "${defaultContextName}" not found in contexts: [${Object.keys(contextSpecs).join(', ')}]`);
  }
  if (!url) url = contextSpecs[defaultContextName].url;

  // Apply config defaults (CLI flags override)
  if (!tags && config.tags) tags = config.tags;
  opts.timeout = rawArgs.some(a => a.startsWith('--timeout=')) ? opts.timeout : (config.timeout || opts.timeout);
  opts.retry = rawArgs.some(a => a.startsWith('--retry=')) ? opts.retry : (config.retries || opts.retry);
  opts.record = opts.record || !!config.record;
  opts.screenshot = opts.screenshot || config.screenshot || 'on-failure';
  if (!['on-failure', 'every-step', 'off'].includes(opts.screenshot)) {
    die(`Invalid --screenshot=${opts.screenshot} (expected on-failure|every-step|off)`);
  }
  if (!['json', 'allure', 'junit'].includes(opts.format)) {
    die(`Invalid --format=${opts.format} (expected json|allure|junit)`);
  }
  if (opts.format === 'junit' && !opts.report) {
    die('--format=junit requires --report=path.xml');
  }
  // Resolve report directory: --report-dir, else dirname(--report), else testDir
  const reportDir = opts.reportDir
    ? resolve(opts.reportDir)
    : (opts.report ? dirname(resolve(opts.report)) : testDir);
  if (opts.screenshot !== 'off') {
    try { mkdirSync(reportDir, { recursive: true }); } catch {}
  }

  // Discover test files
  const testFiles = discoverTests(testPath);
  if (!testFiles.length) die(`No *.test.mjs files found in ${testPath}`);

  // Import and filter tests
  const tests = [];
  let hasOnly = false;
  for (const file of testFiles) {
    const mod = await import('file:///' + file.replace(/\\/g, '/'));
    const base = {
      file: relative(testDir, file).replace(/\\/g, '/'),
      name: mod.name || basename(file, '.test.mjs'),
      tags: mod.tags || [],
      timeout: mod.timeout || opts.timeout,
      skip: mod.skip || false,
      only: mod.only || false,
      setup: mod.setup,
      teardown: mod.teardown,
      fn: mod.default,
      param: undefined,
      context: mod.context || null,
      contexts: Array.isArray(mod.contexts) ? mod.contexts : null,
    };
    if (base.only) hasOnly = true;
    if (Array.isArray(mod.params) && mod.params.length) {
      for (let i = 0; i < mod.params.length; i++) {
        const p = mod.params[i];
        const name = base.name.includes('{') ? interpolate(base.name, p) : `${base.name}[${i}]`;
        tests.push({ ...base, name, param: p });
      }
    } else {
      tests.push(base);
    }
  }

  // Filter
  const filtered = tests.filter(t => {
    if (hasOnly && !t.only) return false;
    if (tags && !tags.some(tag => t.tags.includes(tag))) return false;
    if (grep && !grep.test(t.name)) return false;
    return true;
  });

  // Load hooks
  const hooksPath = resolve(testDir, '_hooks.mjs');
  let hooks = {};
  if (existsSync(hooksPath)) {
    hooks = await import('file:///' + hooksPath.replace(/\\/g, '/'));
  }

  // Console header
  const W = process.stderr;
  W.write(`\nweb-test -- ${url}\n`);
  W.write(`Running ${filtered.length} tests from ${relative(process.cwd(), testDir).replace(/\\/g, '/') || '.'}/\n\n`);

  const startedAt = new Date().toISOString();
  const results = [];
  let passCount = 0, failCount = 0, skipCount = 0;

  // Prepare: infrastructure hooks (no browser)
  if (hooks.prepare) await hooks.prepare();

  // Lazy context creation: ensures the named browser context exists, creating it on first request.
  async function ensureContext(name) {
    if (browser.hasContext(name)) return;
    const spec = contextSpecs[name];
    if (!spec) throw new Error(`Unknown context "${name}". Defined: [${Object.keys(contextSpecs).join(', ')}]`);
    await browser.createContext(name, spec.url, { isolation: spec.isolation || defaultIsolation });
  }

  try {
    // Connect: create the default context up front (so beforeAll has a working browser)
    await ensureContext(defaultContextName);

    // Build context — flat API for single-context tests; reused across tests via setActiveContext.
    // noRecord: false → tests get full API (showCaption, startRecording, etc.). The runner manages
    // its own recording via --record; if a test author calls startRecording while the runner already
    // records, browser.startRecording throws "Already recording" (loud failure beats silent no-op).
    const ctx = buildContext({ noRecord: false });
    ctx.assert = createAssertions();
    ctx.log = (...a) => { /* per-test, overridden below */ };

    // beforeAll
    if (hooks.beforeAll) await hooks.beforeAll(ctx);

    // Execute tests
    let testIdx = 0;
    for (const t of filtered) {
      testIdx++;
      if (t.skip) {
        const reason = typeof t.skip === 'string' ? t.skip : '';
        W.write(`  \u25CB ${t.name}${reason ? ` (skip: ${reason})` : ' (skip)'}\n`);
        results.push({ name: t.name, file: t.file, tags: t.tags, status: 'skipped', duration: 0, attempts: 0, steps: [], output: '', error: null, screenshot: null });
        skipCount++;
        continue;
      }

      // Resolve test's contexts: multi (t.contexts) or single (t.context || default).
      // Lazy-create them and set active to the primary one.
      const testContextNames = t.contexts && t.contexts.length
        ? t.contexts
        : [t.context || defaultContextName];
      try {
        for (const cn of testContextNames) await ensureContext(cn);
        await browser.setActiveContext(testContextNames[0]);
      } catch (e) {
        W.write(`  ✗ ${t.name} (context setup failed: ${e.message})\n`);
        results.push({ name: t.name, file: t.file, tags: t.tags, status: 'failed', duration: 0, attempts: 0, steps: [], output: '', error: { message: e.message }, screenshot: null });
        failCount++;
        if (opts.bail) break;
        continue;
      }

      let lastError = null;
      let testResult = null;
      const maxAttempts = 1 + opts.retry;

      for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const output = [];
        let steps = [];
        let currentSteps = steps;
        let stepIdx = 0;
        const t0 = Date.now();

        let videoFile = null;
        if (opts.record) {
          videoFile = resolve(reportDir, `${testIdx}-${slugify(t.name)}.mp4`);
          try { await browser.startRecording(videoFile, { force: true }); } catch { videoFile = null; }
        }

        // Wire up per-test log and step
        ctx.log = (...a) => output.push(a.map(String).join(' '));
        ctx.step = async (name, fn) => {
          const s = { name, start: Date.now(), status: 'passed', steps: [] };
          currentSteps.push(s);
          const prev = currentSteps;
          currentSteps = s.steps;
          stepIdx++;
          const myIdx = stepIdx;
          try {
            await fn();
          } catch (e) {
            s.status = 'failed';
            s.error = e.message;
            throw e;
          } finally {
            s.stop = Date.now();
            currentSteps = prev;
            if (opts.screenshot === 'every-step' && s.status === 'passed') {
              try {
                const slug = slugify(name);
                const file = resolve(reportDir, `${testIdx}-${myIdx}-${slug}.png`);
                const png = await browser.screenshot();
                writeFileSync(file, png);
                s.screenshot = file;
              } catch {}
            }
          }
        };

        // For multi-context tests, expose ctx.<name> per-context wrappers
        const scopedKeys = [];
        if (t.contexts && t.contexts.length) {
          for (const cn of t.contexts) {
            ctx[cn] = buildScopedContext(cn);
            scopedKeys.push(cn);
          }
        }

        try {
          // beforeEach
          if (hooks.beforeEach) await hooks.beforeEach(ctx);
          // per-test setup
          if (t.setup) await t.setup(ctx);

          // Run test with timeout
          await Promise.race([
            t.fn(ctx, t.param),
            new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout (${t.timeout}ms)`)), t.timeout)),
          ]);

          // per-test teardown
          if (t.teardown) try { await t.teardown(ctx); } catch {}
          // afterEach
          if (hooks.afterEach) try { await hooks.afterEach(ctx); } catch {}
          // Built-in state reset across all contexts the test used
          for (const cn of testContextNames) {
            try { await browser.setActiveContext(cn); await resetState(ctx); } catch {}
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            try { await browser.stopRecording(); } catch {}
          }
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, status: 'passed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: null, screenshot: null, video: videoFile };
          lastError = null;
          break;

        } catch (e) {
          // Screenshot on failure FIRST — before teardown/afterEach/resetState reset the UI.
          // Otherwise the shot captures an empty desktop instead of the failure context.
          let shotFile = e.onecError?.screenshot;
          if (!shotFile && opts.screenshot !== 'off') {
            try {
              const png = await browser.screenshot();
              shotFile = resolve(reportDir, `error-${testIdx}-${slugify(t.file.replace(/\.test\.mjs$/, ''))}.png`);
              writeFileSync(shotFile, png);
            } catch {}
          }

          // per-test teardown (always)
          if (t.teardown) try { await t.teardown(ctx); } catch {}
          // afterEach (always)
          if (hooks.afterEach) try { await hooks.afterEach(ctx); } catch {}
          // Built-in state reset across all contexts the test used
          for (const cn of testContextNames) {
            try { await browser.setActiveContext(cn); await resetState(ctx); } catch {}
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            try { await browser.stopRecording(); } catch {}
          }
          lastError = { message: e.message, step: e.onecError?.step, screenshot: shotFile };
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, status: 'failed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: lastError, screenshot: shotFile, video: videoFile };
        }
      }

      results.push(testResult);

      // Console output
      if (testResult.status === 'passed') {
        passCount++;
        W.write(`  \u2713 ${t.name} (${testResult.duration}s)\n`);
      } else {
        failCount++;
        W.write(`  \u2717 ${t.name} (${testResult.duration}s)\n`);
        // Show failed steps
        printSteps(W, testResult.steps, '    ');
        if (lastError?.message) W.write(`    ${lastError.message}\n`);
        if (lastError?.screenshot) W.write(`    screenshot: ${lastError.screenshot}\n`);
      }

      if (opts.bail && testResult.status === 'failed') break;
    }

    // afterAll
    if (hooks.afterAll) try { await hooks.afterAll(ctx); } catch {}

  } finally {
    // Disconnect
    try { await browser.disconnect(); } catch {}
    // Cleanup: infrastructure hooks
    if (hooks.cleanup) try { await hooks.cleanup(); } catch {}
  }

  const finishedAt = new Date().toISOString();
  const totalDuration = results.reduce((s, r) => s + r.duration, 0);

  // Summary
  W.write(`\n${passCount} passed, ${failCount} failed, ${skipCount} skipped (${formatDuration(totalDuration)})\n\n`);

  // JSON report
  const report = {
    runner: 'web-test', url, startedAt, finishedAt,
    duration: totalDuration,
    summary: { total: results.length, passed: passCount, failed: failCount, skipped: skipCount },
    tests: results,
  };
  out(report);

  if (opts.format === 'allure') {
    writeAllure(results, reportDir);
  } else if (opts.format === 'junit') {
    writeFileSync(resolve(opts.report), buildJUnit(report, testDir));
  } else if (opts.report) {
    writeFileSync(resolve(opts.report), JSON.stringify(report, null, 2));
  }

  if (failCount > 0) process.exit(1);
}

function writeAllure(results, reportDir) {
  for (const tr of results) {
    if (tr.status === 'skipped') continue; // Allure ignores skipped without start/stop
    const uuid = randomUUID();
    const out = {
      uuid,
      name: tr.name,
      fullName: tr.file,
      status: tr.status,
      stage: 'finished',
      start: tr.start,
      stop: tr.stop,
      labels: (tr.tags || []).map(t => ({ name: 'tag', value: t })),
      steps: (tr.steps || []).map(allureStep),
      attachments: [
        ...(tr.screenshot ? [{ name: 'Screenshot on failure', source: basename(tr.screenshot), type: 'image/png' }] : []),
        ...(tr.video ? [{ name: 'Video', source: basename(tr.video), type: 'video/mp4' }] : []),
      ],
    };
    if (tr.status === 'failed' && tr.error) {
      out.statusDetails = { message: tr.error.message || '', trace: tr.output || '' };
    }
    writeFileSync(resolve(reportDir, `${uuid}-result.json`), JSON.stringify(out, null, 2));
  }
}

function allureStep(s) {
  const out = {
    name: s.name,
    status: s.status,
    stage: 'finished',
    start: s.start,
    stop: s.stop,
    steps: (s.steps || []).map(allureStep),
  };
  if (s.screenshot) {
    out.attachments = [{ name: 'Screenshot', source: basename(s.screenshot), type: 'image/png' }];
  }
  if (s.status === 'failed' && s.error) {
    out.statusDetails = { message: s.error, trace: s.error };
  }
  return out;
}

function xmlEscape(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function buildJUnit(report, testDir) {
  const { summary, duration, tests } = report;
  const suiteName = relative(process.cwd(), testDir).replace(/\\/g, '/') || '.';
  const lines = ['<?xml version="1.0" encoding="UTF-8"?>'];
  lines.push(`<testsuites name="web-test" tests="${summary.total}" failures="${summary.failed}" skipped="${summary.skipped}" time="${duration.toFixed(3)}">`);
  lines.push(`  <testsuite name="${xmlEscape(suiteName)}" tests="${summary.total}" failures="${summary.failed}" skipped="${summary.skipped}" time="${duration.toFixed(3)}">`);
  for (const t of tests) {
    const attrs = `name="${xmlEscape(t.name)}" classname="${xmlEscape(t.file)}" time="${(t.duration || 0).toFixed(3)}"`;
    if (t.status === 'passed') {
      lines.push(`    <testcase ${attrs}/>`);
    } else if (t.status === 'skipped') {
      lines.push(`    <testcase ${attrs}><skipped/></testcase>`);
    } else {
      lines.push(`    <testcase ${attrs}>`);
      const msg = t.error?.message || '';
      const trace = t.output || '';
      lines.push(`      <failure message="${xmlEscape(msg)}">${xmlEscape(trace)}</failure>`);
      if (t.screenshot) lines.push(`      <system-out>screenshot: ${xmlEscape(t.screenshot)}</system-out>`);
      lines.push(`    </testcase>`);
    }
  }
  lines.push(`  </testsuite>`);
  lines.push(`</testsuites>`);
  return lines.join('\n');
}

function discoverTests(testPath) {
  if (testPath.endsWith('.test.mjs')) return existsSync(testPath) ? [testPath] : [];
  const files = [];
  function walk(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('_') || entry.name.startsWith('.')) continue;
      const full = resolve(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.test.mjs')) files.push(full);
    }
  }
  walk(testPath);
  return files.sort();
}

async function resetState(ctx) {
  try { if (typeof ctx.dismissPendingErrors === 'function') await ctx.dismissPendingErrors(); } catch {}
  for (let i = 0; i < 10; i++) {
    try {
      const state = await ctx.getFormState();
      // form === null means no form open (desktop). form === 0 is a real background form
      // 1C exposes in some states — must still close it to fully reset.
      if (state.form == null) break;
      await ctx.closeForm({ save: false });
    } catch { break; }
  }
}

function printSteps(W, steps, indent) {
  for (let i = 0; i < steps.length; i++) {
    const s = steps[i];
    const last = i === steps.length - 1;
    const prefix = last ? '\u2514' : '\u251C';
    const mark = s.status === 'failed' ? '\u2717 ' : '';
    W.write(`${indent}${prefix} ${mark}${s.name} (${elapsed2(s.start, s.stop)}s)\n`);
    if (s.error && s.status === 'failed') {
      W.write(`${indent}  ${s.error}\n`);
    }
    if (s.steps.length) printSteps(W, s.steps, indent + '  ');
  }
}

function elapsed2(start, stop) {
  return Math.round(((stop || Date.now()) - start) / 100) / 10;
}

function interpolate(template, params) {
  return String(template).replace(/\{(\w+)\}/g, (_, key) =>
    params[key] !== undefined ? String(params[key]) : `{${key}}`);
}

function slugify(s) {
  return String(s).trim()
    .replace(/[\s/\\:*?"<>|]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60) || 'step';
}

function formatDuration(seconds) {
  if (seconds < 60) return `${Math.round(seconds * 10) / 10}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round((seconds - m * 60) * 10) / 10;
  return `${m}m ${s}s`;
}


// ============================================================
// assertions
// ============================================================

function createAssertions() {
  class AssertionError extends Error {
    constructor(msg, actual, expected) {
      super(msg);
      this.name = 'AssertionError';
      this.actual = actual;
      this.expected = expected;
    }
  }

  return {
    ok(value, msg) {
      if (!value) throw new AssertionError(msg || `Expected truthy, got ${JSON.stringify(value)}`, value, true);
    },
    equal(actual, expected, msg) {
      if (actual !== expected) throw new AssertionError(msg || `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`, actual, expected);
    },
    notEqual(actual, expected, msg) {
      if (actual === expected) throw new AssertionError(msg || `Expected not ${JSON.stringify(expected)}`, actual, expected);
    },
    deepEqual(actual, expected, msg) {
      const a = JSON.stringify(actual), b = JSON.stringify(expected);
      if (a !== b) throw new AssertionError(msg || `Deep equal failed:\n  actual:   ${a}\n  expected: ${b}`, actual, expected);
    },
    includes(haystack, needle, msg) {
      const h = Array.isArray(haystack) ? haystack : String(haystack);
      if (!h.includes(needle)) throw new AssertionError(msg || `Expected ${JSON.stringify(h)} to include ${JSON.stringify(needle)}`, haystack, needle);
    },
    match(string, regex, msg) {
      if (!regex.test(string)) throw new AssertionError(msg || `Expected ${JSON.stringify(string)} to match ${regex}`, string, regex);
    },
    async throws(fn, msg) {
      try { await fn(); } catch { return; }
      throw new AssertionError(msg || 'Expected function to throw');
    },
    // 1C-specific
    formHasField(state, fieldName, msg) {
      if (!state?.fields?.[fieldName]) throw new AssertionError(msg || `Field "${fieldName}" not found in form. Available: ${Object.keys(state?.fields || {}).join(', ')}`, null, fieldName);
    },
    formTitle(state, expected, msg) {
      if (!state?.title?.includes(expected)) throw new AssertionError(msg || `Form title "${state?.title}" does not contain "${expected}"`, state?.title, expected);
    },
    tableHasRow(table, predicate, msg) {
      const rows = table?.rows || [];
      let found;
      if (typeof predicate === 'function') {
        found = rows.some(predicate);
      } else {
        found = rows.some(r => Object.entries(predicate).every(([k, v]) => r[k] === v));
      }
      if (!found) throw new AssertionError(msg || `No row matching predicate in table (${rows.length} rows)`, null, predicate);
    },
    tableRowCount(table, expected, msg) {
      const actual = table?.rows?.length ?? 0;
      if (actual !== expected) throw new AssertionError(msg || `Expected ${expected} rows, got ${actual}`, actual, expected);
    },
    noErrors(state, msg) {
      if (state?.errors) throw new AssertionError(msg || `Form has errors: ${JSON.stringify(state.errors)}`, state.errors, null);
    },
  };
}


// ============================================================
// helpers
// ============================================================

function loadSession() {
  if (!existsSync(SESSION_FILE)) {
    die('No active session. Run: node src/run.mjs start <url>');
  }
  return JSON.parse(readFileSync(SESSION_FILE, 'utf-8'));
}

function cleanup() {
  try { unlinkSync(SESSION_FILE); } catch {}
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf-8');
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf-8');
}

function elapsed(t0) {
  return Math.round((Date.now() - t0) / 100) / 10;
}

function json(res, obj, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj, null, 2));
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + '\n');
}

function die(msg) {
  process.stderr.write(msg + '\n');
  process.exit(1);
}

function usage() {
  die(`Usage: node run.mjs <command> [args]

Commands:
  start <url>              Launch browser and connect to 1C web client
  run <url> <file|->       Autonomous: connect, execute script, disconnect
  exec <file|-> [options]  Execute script (file path or - for stdin)
  shot [file]              Take screenshot (default: shot.png)
  stop                     Logout and close browser
  status                   Check session status
  test [url] <dir|file>    Run regression tests (*.test.mjs)

Options for exec:
  --no-record              Skip video recording (record() becomes no-op)

Options for test:
  --tags=smoke,crud        Filter tests by tags
  --grep=pattern           Filter tests by name (regex)
  --bail                   Stop on first failure
  --retry=N                Retry failed tests N times
  --timeout=ms             Per-test timeout (default: 30000)
  --report=path            Write JSON report to file
  --report-dir=path        Directory for screenshots and other artifacts
  --screenshot=mode        on-failure (default) | every-step | off
  --format=fmt             json (default) | allure | junit
  --record                 Record video for each test (mp4 in report-dir)`);
}
