// web-test cli/commands/test v1.9 — regression test runner
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, writeFileSync, mkdirSync, renameSync, copyFileSync, unlinkSync } from 'fs';
import { resolve, dirname, basename, relative } from 'path';
import * as browser from '../../browser.mjs';
import { out, die, elapsed, slugify, formatDuration, interpolate, printSteps, softDeadline } from '../util.mjs';
import { buildContext, buildScopedContext, setErrorShotDir } from '../exec-context.mjs';
import { createAssertions } from '../test-runner/assertions.mjs';
import { buildSeverityIndex } from '../test-runner/severity.mjs';
import { writeAllure, buildJUnit, syncAllureExtras } from '../test-runner/reporters.mjs';
import { discoverTests, resetState } from '../test-runner/discover.mjs';
import { findSuiteRoot, startDirOf } from '../test-runner/suite-root.mjs';
import { planEviction, touchLru, dropLru } from '../test-runner/context-pool.mjs';

export async function cmdTest(rawArgs) {
  // Split off everything after `--` — those args belong to user-defined hooks
  // (see spec §6: "all arguments after `--` are forwarded verbatim to _hooks.mjs
  // via the hookArgs field; the runner does not interpret them").
  const sepIdx = rawArgs.indexOf('--');
  const ownArgs  = sepIdx >= 0 ? rawArgs.slice(0, sepIdx) : rawArgs;
  const hookArgs = sepIdx >= 0 ? rawArgs.slice(sepIdx + 1) : [];

  // Deadline budgets for the cleanup path. Every one of these calls reaches into Playwright
  // and can hang forever against a wedged renderer (page.evaluate has no timeout of its own),
  // so none of them may be awaited bare. A breach is always logged — silent swallowing is what
  // turned the original incident into a 29-minute mystery.
  //
  // These defaults are sized for a light stand. A heavy application legitimately needs more —
  // override per key via `deadlines: {...}` in webtest.config.mjs rather than editing this.
  const D = {
    screenshot: 10000,
    teardown: 15000,
    afterEach: 15000,
    setActive: 5000,
    resetState: 20000,
    startRecording: 15000,
    stopRecording: 40000,   // ffmpeg has its own 30s inside
    closeContext: 20000,
    disconnect: 30000,
    hooks: 120000,          // afterAll/cleanup only — prepare/beforeAll stay unbounded (see below)
    abortAll: 30000,        // whole abort+cleanup sequence for one hung test
    probe: 2000,
  };

  // Parse flags
  const opts = { bail: false, retry: 0, timeout: 30000, globalTimeout: 0, report: null, format: 'json', screenshot: null, reportDir: null, record: false };
  let tags = null, grep = null, urlFlag = null;
  const positional = [];
  for (const a of ownArgs) {
    if (a.startsWith('--tags='))       tags = a.slice(7).split(',');
    else if (a.startsWith('--grep='))  grep = new RegExp(a.slice(7), 'i');
    else if (a.startsWith('--url='))   urlFlag = a.slice(6);
    else if (a === '--bail')           opts.bail = true;
    else if (a.startsWith('--retry=')) opts.retry = parseInt(a.slice(8)) || 0;
    else if (a.startsWith('--timeout=')) opts.timeout = parseInt(a.slice(10)) || 30000;
    else if (a.startsWith('--global-timeout=')) opts.globalTimeout = parseInt(a.slice(17)) || 0;
    else if (a.startsWith('--report=')) opts.report = a.slice(9);
    else if (a.startsWith('--format=')) opts.format = a.slice(9);
    else if (a.startsWith('--screenshot=')) opts.screenshot = a.slice(13);
    else if (a.startsWith('--report-dir=')) opts.reportDir = a.slice(13);
    else if (a === '--record')         opts.record = true;
    else if (!a.startsWith('--'))      positional.push(a);
  }

  // Positional args are ALWAYS test paths (one or many). URL comes from --url= or config
  // (see webtest.config.mjs). This matches pytest/jest/playwright; a positional that looks
  // like a URL is a mistake → fail fast with a hint instead of feeding it to page.goto().
  const isUrl = (s) => /^https?:\/\//i.test(s);
  let url = urlFlag || null;
  const testPaths = [...positional];
  if (testPaths.length === 0) {
    die('Usage: node run.mjs test <dir|file>... [--url=URL] [--tags=...] [--grep=...] [--bail] [--retry=N] [--timeout=ms] [--report=path]');
  }
  for (const p of testPaths) {
    if (existsSync(resolve(p))) continue;
    if (isUrl(p)) {
      die(`"${p}" looks like a URL — use --url=<url>; positional args are test paths.`);
    }
    die(`Test path not found: "${p}". To run a subset use --grep= / --tags=, or pass an existing dir/file.`);
  }

  // Suite root — the directory `webtest.config.mjs`, `_hooks.mjs`, `_allure/` and report paths
  // all hang off. It is NOT the passed path: walking up to the nearest marker is what makes
  // `test tests/myapp/sales/` work, as docs/web-test-regression-spec.md has always promised.
  // Resolving from the passed path instead lost the hooks of any subfolder run — silently, so
  // the run went ahead against an unprepared stand.
  const startDirs = testPaths.map(p => startDirOf(p));
  const roots = startDirs.map(d => findSuiteRoot(d));
  // Paths from different suites must not share hooks — that used to resolve to "first path
  // wins", silently running suite B's tests under suite A's preparation.
  const distinct = [...new Set(roots.map(r => r?.root ?? null))];
  if (distinct.length > 1) {
    const lines = testPaths.map((p, i) => `  ${p} → ${roots[i]?.root ?? '(корень не найден)'}`);
    die(`Paths belong to different suites — config and hooks would be ambiguous:\n${lines.join('\n')}\n` +
        `Run them separately, or pass one suite root and narrow with --grep= / --tags=.`);
  }
  const suiteRoot = roots[0]?.root ?? startDirs[0];
  const suiteRootFound = !!roots[0];
  const configPath = resolve(suiteRoot, 'webtest.config.mjs');
  let config = {};
  if (existsSync(configPath)) {
    const mod = await import('file:///' + configPath.replace(/\\/g, '/'));
    config = mod.default || {};
  }
  const severityIndex = buildSeverityIndex(config);

  // Build context registry: name → url. Supports config.contexts or single config.url / CLI url.
  const contextSpecs = {};
  let defaultContextName = 'default';
  const defaultIsolation = config.isolation || 'tab';
  if (config.contexts && typeof config.contexts === 'object' && Object.keys(config.contexts).length) {
    for (const [n, spec] of Object.entries(config.contexts)) {
      contextSpecs[n] = { ...spec };
    }
    defaultContextName = config.defaultContext || Object.keys(config.contexts)[0];
    if (url) contextSpecs[defaultContextName] = { ...contextSpecs[defaultContextName], url };
  } else {
    const fallbackUrl = url || config.url;
    // Name the real problem: with no suite root there is no config to take a URL from — and,
    // more dangerously, no `_hooks.mjs` either. The old wording talked only about the URL and
    // sent readers looking in the wrong place.
    if (!fallbackUrl) {
      die(suiteRootFound
        ? `No URL: ${configPath} defines neither "contexts" nor "url", and --url= was not given.`
        : `Suite root not found above "${testPaths[0]}" — no webtest.config.mjs / _hooks.mjs up to ` +
          `the repository (or working) directory, so there is no URL and no stand preparation.\n` +
          `Pass the suite root (e.g. tests/myapp/) and narrow with --grep= / --tags=, or give --url=.`);
    }
    contextSpecs.default = { url: fallbackUrl };
  }
  if (!contextSpecs[defaultContextName]) {
    die(`defaultContext "${defaultContextName}" not found in contexts: [${Object.keys(contextSpecs).join(', ')}]`);
  }
  if (!url) url = contextSpecs[defaultContextName].url;

  // Context-pool config (license management). All three optional; without them the runner keeps
  // its legacy behavior: default stays open, contexts accumulate, no eviction.
  //   maxContexts    — cap on simultaneous 1C sessions (null = unlimited).
  //   contextPolicy  — 'reuse' (keep open within the cap) | 'strict' (close a test's non-pinned
  //                    contexts right after it, to release licenses ASAP).
  //   pinnedContexts — never evicted by LRU. Defaults to [defaultContext] so today's "default is
  //                    never closed between tests" holds; set [] to make default evictable.
  let maxContexts = null;
  if (config.maxContexts != null) {
    if (!Number.isInteger(config.maxContexts) || config.maxContexts < 1) {
      die(`Invalid maxContexts=${config.maxContexts} (expected a positive integer or omit for unlimited)`);
    }
    maxContexts = config.maxContexts;
  }
  const contextPolicy = config.contextPolicy == null ? 'reuse' : config.contextPolicy;
  if (!['reuse', 'strict'].includes(contextPolicy)) {
    die(`Invalid contextPolicy="${contextPolicy}" (expected 'reuse' or 'strict')`);
  }
  const pinnedContexts = Array.isArray(config.pinnedContexts) ? config.pinnedContexts : [defaultContextName];
  for (const n of pinnedContexts) {
    if (!contextSpecs[n]) die(`pinnedContexts entry "${n}" not found in contexts: [${Object.keys(contextSpecs).join(', ')}]`);
  }
  const pinnedSet = new Set(pinnedContexts);
  // LRU usage order — oldest first, freshest last. Drives eviction under a maxContexts cap.
  const lruOrder = [];

  // Apply config defaults (CLI flags override)
  if (!tags && config.tags) tags = config.tags;
  opts.timeout = ownArgs.some(a => a.startsWith('--timeout=')) ? opts.timeout : (config.timeout || opts.timeout);
  opts.retry = ownArgs.some(a => a.startsWith('--retry=')) ? opts.retry : (config.retries || opts.retry);
  opts.globalTimeout = ownArgs.some(a => a.startsWith('--global-timeout=')) ? opts.globalTimeout : (config.globalTimeout || opts.globalTimeout);

  // Per-key deadline overrides. Defaults suit a light stand; a heavy application may honestly
  // need longer (a big form's resetState, a slow close). Unknown keys are a typo, not a wish —
  // fail fast rather than silently ignoring an override the author believed was in effect.
  if (config.deadlines) {
    for (const [k, v] of Object.entries(config.deadlines)) {
      if (!(k in D)) die(`Invalid deadlines.${k} in config (expected one of: ${Object.keys(D).join(', ')})`);
      if (typeof v !== 'number' || !(v > 0)) die(`Invalid deadlines.${k}=${v} (expected a positive number of ms)`);
      D[k] = v;
    }
  }
  if (config.preserveClipboard === false && !ownArgs.includes('--no-preserve-clipboard')) {
    browser.setPreserveClipboard(false);
  }
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
  // `--report=-` means "machine report to stdout" (Unix `-` convention).
  // Only meaningful for streamable formats (json/junit); allure is a directory.
  const reportToStdout = opts.report === '-';
  if (reportToStdout && opts.format === 'allure') {
    die('--report=- (stdout) is not valid with --format=allure: allure emits a directory of files, not a single stream. Use --report-dir=<dir> instead.');
  }
  const reportDir = opts.reportDir
    ? resolve(opts.reportDir)
    : (opts.report && !reportToStdout ? dirname(resolve(opts.report)) : suiteRoot);
  if (opts.screenshot !== 'off') {
    try { mkdirSync(reportDir, { recursive: true }); } catch {}
    // 1C-error screenshots (taken inside the action wrapper) default to a single
    // fixed file at the skill root — outside reportDir and shared by every test.
    // Point them at reportDir so each failure keeps its own attachable file.
    setErrorShotDir(reportDir);
  }

  // Discover test files
  const testFiles = discoverTests(testPaths);
  if (!testFiles.length) die(`No *.test.mjs files found in ${testPaths.join(', ')}`);

  // Import and filter tests
  const tests = [];
  let hasOnly = false;
  for (const file of testFiles) {
    const mod = await import('file:///' + file.replace(/\\/g, '/'));
    const base = {
      // Relative to the SUITE ROOT, not to the passed path — otherwise the same test gets a
      // different id depending on how it was launched (`sales/01-x.test.mjs` vs `01-x.test.mjs`),
      // and Allure history / JUnit trends treat the two as unrelated tests.
      file: relative(suiteRoot, file).replace(/\\/g, '/'),
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
      severity: typeof mod.severity === 'string' ? mod.severity : null,
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
  const hooksPath = resolve(suiteRoot, '_hooks.mjs');
  let hooks = {};
  if (existsSync(hooksPath)) {
    hooks = await import('file:///' + hooksPath.replace(/\\/g, '/'));
  }

  // Human-readable report goes to stdout (test-runner convention: jest/pytest/playwright).
  // In `--report -` mode the machine JSON/XML takes over stdout, so progress moves to stderr.
  const W = reportToStdout ? process.stderr : process.stdout;
  W.write(`\nweb-test -- ${url}\n`);
  // Always name the resolved suite root: a climb that landed on the wrong directory is then
  // visible in the first line of output instead of being diagnosed from symptoms later.
  const rel = (p) => relative(process.cwd(), p).replace(/\\/g, '/') || '.';
  const shownPaths = testPaths.map(p => rel(resolve(p))).filter(p => p !== rel(suiteRoot));
  W.write(`Running ${filtered.length} tests from ${rel(suiteRoot)}/`);
  W.write(shownPaths.length ? ` (paths: ${shownPaths.join(', ')})\n\n` : `\n\n`);
  if (!suiteRootFound) {
    // Not fatal — a one-off test outside any suite is legitimate. But a missing suite root also
    // means no `_hooks.mjs` was even looked for above, so the stand is whatever it was.
    process.stderr.write(`! no suite root (webtest.config.mjs / _hooks.mjs) found above ${rel(startDirs[0])} — running without hooks\n`);
  }

  const startedAt = new Date().toISOString();
  const results = [];
  let passCount = 0, failCount = 0, skipCount = 0;

  // Per-test diagnostics are BUFFERED and flushed right after that test's ✓/✗ line.
  // A test's cleanup runs before its result is printed, so writing straight to the stream put
  // `! …` lines ABOVE the test they belong to — i.e. visually under the PREVIOUS test's result.
  // Anyone reading the log (a model included) attributes them to the wrong test; that misreading
  // already cost this session a wrong conclusion. Outside a test (hooks, final teardown) there is
  // nothing to attach to, so lines go straight out.
  let diagSink = null;
  const emit = (line) => { if (diagSink) diagSink.push(line); else W.write(line); };
  const flushDiag = () => {
    if (!diagSink) return;
    for (const line of diagSink) W.write(line);
    diagSink = null;
  };

  /**
   * Bounded best-effort await: the replacement for `try { await x } catch {}`.
   * Same tolerance for failure, but a call that never settles can no longer stall the run,
   * and every breach leaves a visible line instead of a silent 29-minute stall.
   */
  async function bounded(promise, ms, label) {
    const r = await softDeadline(promise, ms, label);
    if (!r.ok) emit(`    ! ${label}: ${r.timedOut ? `timed out after ${ms}ms` : r.err.message.split('\n')[0]}\n`);
    return r;
  }

  /**
   * Reset one context between tests — and only reuse it if the reset actually WORKED.
   *
   * Reusing a context whose UI was not cleaned leaks someone else's open form into the next test:
   * silent drift instead of a visible error, the worst possible outcome. Two ways to end up there,
   * and both must lead here:
   *   - the reset breached its deadline (badly-sized budget, wedged page);
   *   - the reset ran to completion but did not clean anything (a modal that refuses to close) —
   *     this one used to pass as success, because `bounded` only reports timeouts and throws.
   * Either way: destroy the slot, ensureContext recreates a clean one. The cost is a relaunch,
   * never a wrong test result.
   */
  async function resetOrAbort(cn, ctx) {
    const sw = await bounded(browser.setActiveContext(cn), D.setActive, `setActiveContext(${cn})`);
    if (!sw.ok) return false;
    const r = await bounded(resetState(ctx), D.resetState, `resetState(${cn})`);
    if (r.ok && r.value?.clean) return true;

    if (r.ok) {
      // Name what stayed open — otherwise the next investigation starts from archaeology.
      const v = r.value || {};
      const what = v.title ? `"${v.title}"` : `#${v.form}`;
      emit(`    ! resetState(${cn}): not clean — form ${what}${v.modal ? ' (modal)' : ''} still open` +
              ` after ${v.attempts} close attempt(s)` +
              `${v.lastError ? `, last error: ${v.lastError.message.split('\n')[0]}` : ''}\n`);
    }
    emit(`    ! context "${cn}" left dirty — aborting it, the next test gets a fresh one\n`);
    await bounded(browser.abortContext(cn), D.closeContext, `abortContext(${cn})`);
    dropLru(lruOrder, cn);
    return false;
  }

  // Bumped for every attempt. A timed-out test's body keeps running — a promise cannot be
  // cancelled, so when its pending call finally rejects, its own `finally` would go on to
  // drive the UI of whichever test is running by then. Silent cross-test corruption.
  //
  // The run shares one `ctx` object (hooks hold it too), so an epoch stamped on ctx could not
  // tell the zombie from the live caller — both are the same object. Each attempt therefore
  // gets its own Proxy view bound to its epoch; calls through a stale view throw.
  let abortEpoch = 0;
  function makeTestCtx(base, epoch) {
    return new Proxy(base, {
      get(target, prop, recv) {
        const v = Reflect.get(target, prop, recv);
        if (typeof v !== 'function') return v;
        return (...args) => {
          if (epoch !== abortEpoch) {
            throw new Error(`test abandoned (timeout) — blocked a late ${String(prop)}() call from its body; it would have hit the next test`);
          }
          return v.apply(target, args);
        };
      },
    });
  }

  function buildReport(state) {
    const totalDuration = results.reduce((s, r) => s + r.duration, 0);
    return {
      runner: 'web-test', url, startedAt, finishedAt: new Date().toISOString(),
      state,
      duration: totalDuration,
      summary: { total: results.length, passed: passCount, failed: failCount, skipped: skipCount },
      tests: results,
    };
  }

  let allureWritten = false;
  /**
   * Record a finished test AND persist it immediately. The report used to be written only
   * after the loop, so a single hang destroyed every result collected so far.
   * writeAllure([tr]) is byte-identical to the batch call: it mints its own uuid per test and
   * severityIndex is read-only.
   */
  function recordResult(tr) {
    results.push(tr);
    if (opts.format === 'allure') {
      try { writeAllure([tr], reportDir, severityIndex); allureWritten = true; } catch (e) { W.write(`    ! allure write: ${e.message}\n`); }
    } else if (opts.format === 'json' && opts.report && !reportToStdout) {
      try { writeFileSync(resolve(opts.report), JSON.stringify(buildReport('partial'), null, 2)); } catch {}
    }
  }

  const hookLog = (...a) => W.write(`[hooks] ${a.map(String).join(' ')}\n`);
  const hookEnv = { hookArgs, log: hookLog, config };
  // Deliberately unbounded and allowed to throw: prepare() rebuilds the stand (db-create +
  // load + update), whose honest duration depends on the application's size — a deadline here
  // would cut a legitimate rebuild. And its failure must stay fatal: proceeding into a run
  // without a stand turns one clear error into a screenful of confusing ones.
  if (hooks.prepare) await hooks.prepare(hookEnv);

  /** Force-release every open context (frees 1C licenses), then drop the browser. */
  async function shutdownAll() {
    for (const name of browser.listContexts()) {
      await bounded(browser.abortContext(name), D.closeContext, `abortContext(${name})`);
    }
    await bounded(browser.disconnect(), D.disconnect, 'disconnect');
  }

  /**
   * Wall-clock ceiling for the whole run. This works even while a test is wedged: a pending
   * Playwright await does not block the event loop, it is merely an unsettled promise — which
   * is precisely why the original incident stalled quietly instead of crashing.
   * Report first (that's what the user needs), hygiene second, exit unconditionally.
   */
  let globalTimer = null;
  let hardStopping = false;
  async function hardStop(reason) {
    if (hardStopping) return;
    hardStopping = true;
    W.write(`\n!! ${reason}: run exceeded --global-timeout=${opts.globalTimeout}ms — forcing shutdown\n`);
    abortEpoch++;
    // Last-resort exit if the shutdown itself wedges. Referenced on purpose: it must survive.
    const bailout = setTimeout(() => process.exit(3), 20000);
    try { writeFinalReport('aborted'); } catch (e) { W.write(`    ! report: ${e.message}\n`); }
    await softDeadline(shutdownAll(), 15000, 'shutdown');
    clearTimeout(bailout);
    process.exit(2);
  }
  if (opts.globalTimeout > 0) {
    globalTimer = setTimeout(() => { void hardStop('global-timeout'); }, opts.globalTimeout);
  }

  // Lazy context creation
  async function ensureContext(name) {
    if (browser.hasContext(name)) return;
    const spec = contextSpecs[name];
    if (!spec) throw new Error(`Unknown context "${name}". Defined: [${Object.keys(contextSpecs).join(', ')}]`);
    await browser.createContext(name, spec.url, { isolation: spec.isolation || defaultIsolation });
    if (hooks.afterOpenContext && hookCtx) {
      try { await hooks.afterOpenContext(hookCtx, name, spec); }
      catch (e) { hookLog(`afterOpenContext("${name}") threw: ${e.message.split('\n')[0]}`); }
    }
  }

  let hookCtx = null;

  function wrapCloseContextHook(target) {
    const orig = target.closeContext;
    if (typeof orig !== 'function') return;
    target.closeContext = async (name) => {
      if (hooks.beforeCloseContext) {
        try { await hooks.beforeCloseContext(target, name, contextSpecs[name]); }
        catch (e) { hookLog(`beforeCloseContext("${name}") threw: ${e.message.split('\n')[0]}`); }
      }
      return await orig(name);
    };
  }

  try {
    // Connect: create default context up front (hosts beforeAll / hooks). It is NOT permanently
    // pinned — under a maxContexts cap it becomes an LRU eviction candidate unless it is listed in
    // pinnedContexts. Register it in the LRU order.
    //
    // This one call needs its own catch: it sits in a try that has only a `finally`, and run.mjs
    // does not wrap cmdTest — so a throw here would escape as a raw stack trace and skip the
    // report entirely. A blocked startup (e.g. no free 1C licence) dooms the whole run anyway,
    // so say it once, keep the report, and leave.
    try {
      await ensureContext(defaultContextName);
    } catch (e) {
      W.write(`\n!! cannot open context "${defaultContextName}": ${e.message}\n\n`);
      try { writeFinalReport('aborted'); } catch {}
      // process.exit skips the `finally` below, and killing the process does NOT release a 1C
      // seance — so release what we hold explicitly before leaving.
      await softDeadline(shutdownAll(), 15000, 'shutdown');
      process.exit(1);
    }
    touchLru(lruOrder, defaultContextName);

    const ctx = buildContext({ noRecord: false });
    ctx.assert = createAssertions();
    ctx.log = (...a) => { /* per-test, overridden below */ };
    wrapCloseContextHook(ctx);
    hookCtx = ctx;

    // Default context was created BEFORE hookCtx existed → fire afterOpenContext now.
    if (hooks.afterOpenContext) {
      try { await hooks.afterOpenContext(ctx, defaultContextName, contextSpecs[defaultContextName]); }
      catch (e) { hookLog(`afterOpenContext("${defaultContextName}") threw: ${e.message.split('\n')[0]}`); }
    }

    if (hooks.beforeAll) await hooks.beforeAll(ctx);

    let testIdx = 0;
    for (const t of filtered) {
      testIdx++;
      // Buffer this test's diagnostics; they are flushed under its own result line below.
      diagSink = [];
      const declaredContexts = t.contexts && t.contexts.length
        ? t.contexts
        : [t.context || defaultContextName];

      if (t.skip) {
        const reason = typeof t.skip === 'string' ? t.skip : '';
        W.write(`  ○ ${t.name}${reason ? ` (skip: ${reason})` : ' (skip)'}\n`);
        flushDiag();
        recordResult({ name: t.name, file: t.file, tags: t.tags, contexts: declaredContexts, status: 'skipped', duration: 0, attempts: 0, steps: [], output: '', error: null, screenshot: null });
        skipCount++;
        continue;
      }

      const testContextNames = declaredContexts;
      try {
        // Make room in the license pool before opening this test's contexts. Already-open needed
        // contexts are reused (ensureContext no-ops); LRU-oldest non-pinned contexts are evicted.
        const plan = planEviction({
          open: browser.listContexts(),
          needed: testContextNames,
          pinned: pinnedSet,
          max: maxContexts,
          lruOrder,
        });
        if (plan.error) throw new Error(plan.error);
        // Needed-but-not-yet-open contexts — also serve as a parking fallback when eviction would
        // close the sole open context (can't closeContext the active slot with no survivor).
        const toOpenQueue = testContextNames.filter(n => !browser.hasContext(n));
        for (const name of plan.toEvict) {
          if (browser.getActiveContext() === name) {
            let survivor = browser.listContexts().find(n => n !== name);
            if (!survivor) {
              // `name` is the only open context. Open a needed one first to park on — room is
              // guaranteed because we free `name` right after and multi-context implies max>=2.
              if (browser.listContexts().length < maxContexts && toOpenQueue.length) {
                const parkName = toOpenQueue.shift();
                await ensureContext(parkName);
                survivor = parkName;
              } else {
                throw new Error(`cannot evict "${name}": it is the only open context and maxContexts=${maxContexts} leaves no room to switch. Use maxContexts>=2 when tests alternate contexts.`);
              }
            }
            await browser.setActiveContext(survivor);
          }
          if (hooks.beforeCloseContext && hookCtx) {
            try { await hooks.beforeCloseContext(hookCtx, name, contextSpecs[name]); }
            catch (e) { hookLog(`beforeCloseContext("${name}") threw: ${e.message.split('\n')[0]}`); }
          }
          await browser.closeContext(name);
          dropLru(lruOrder, name);
        }
        for (const cn of testContextNames) await ensureContext(cn);
        await browser.setActiveContext(testContextNames[0]);
        touchLru(lruOrder, testContextNames);
      } catch (e) {
        W.write(`  ✗ ${t.name} (context setup failed: ${e.message})\n`);
        flushDiag();
        recordResult({ name: t.name, file: t.file, tags: t.tags, contexts: declaredContexts, status: 'failed', duration: 0, attempts: 0, steps: [], output: '', error: { message: e.message }, screenshot: null });
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

        ctx.testInfo = {
          name: t.name,
          file: basename(t.file),
          filePath: t.file,
          tags: t.tags,
          timeout: t.timeout,
          attempt,
          maxAttempts,
          param: t.param,
          contexts: Object.fromEntries(testContextNames.map(n => [n, contextSpecs[n]])),
          primaryContext: testContextNames[0],
        };
        ctx.testResult = null;

        let videoFile = null;
        if (opts.record) {
          videoFile = resolve(reportDir, `${testIdx}-${slugify(t.name)}.mp4`);
          const rec = await bounded(browser.startRecording(videoFile, { force: true }), D.startRecording, 'startRecording');
          if (!rec.ok) videoFile = null;
        }

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

        const scopedKeys = [];
        if (t.contexts && t.contexts.length) {
          for (const cn of t.contexts) {
            ctx[cn] = buildScopedContext(cn);
            wrapCloseContextHook(ctx[cn]);
            scopedKeys.push(cn);
          }
        }

        const myEpoch = ++abortEpoch;
        let timedOut = false;

        try {
          if (hooks.beforeEach) await hooks.beforeEach(ctx);
          if (t.setup) await t.setup(ctx);

          let timeoutTimer;
          try {
            await Promise.race([
              t.fn(makeTestCtx(ctx, myEpoch), t.param),
              new Promise((_, reject) => { timeoutTimer = setTimeout(() => { timedOut = true; reject(new Error(`Timeout (${t.timeout}ms)`)); }, t.timeout); }),
            ]);
          } finally {
            // Clear the guard timer — otherwise it stays armed in the event loop and,
            // since the success path never calls process.exit(), node can't exit until
            // it fires (up to `timeout` ms after the last test finished).
            clearTimeout(timeoutTimer);
          }

          // Bounded even on the green path: a test can pass and still leave the UI in a state
          // where resetState wedges — that would stall the run just as dead as a failure would.
          if (t.teardown) await bounded(t.teardown(ctx), D.teardown, 'teardown');
          ctx.testResult = { status: 'passed', duration: elapsed(t0), attempts: attempt, error: null, steps };
          if (hooks.afterEach) await bounded(hooks.afterEach(ctx), D.afterEach, 'hooks.afterEach');
          for (const cn of testContextNames) {
            if (!browser.hasContext(cn)) continue;
            await resetOrAbort(cn, ctx);
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            await bounded(browser.stopRecording(), D.stopRecording, 'stopRecording');
          }
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, contexts: testContextNames, severity: t.severity, status: 'passed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: null, screenshot: null, video: videoFile };
          lastError = null;
          break;

        } catch (e) {
          // ── Timeout: diagnose, then destroy what hung. Everything below this point that
          // goes through the renderer (screenshot, teardown, resetState) is pointless on a
          // wedged page and would itself hang — so on `hang` we skip straight to the abort.
          let diagnosis = null;
          if (timedOut) {
            const active = browser.getActiveContext();
            const probe = active ? await browser.probeContext(active, { ms: D.probe }) : null;
            const diag = active ? browser.getContextDiagnostics(active) : null;
            const verdict = !probe ? 'no-context'
              : !probe.browserAlive ? 'browser-dead'
              : !probe.rendererAlive ? 'hang'
              : diag?.net.inFlight > 0 ? 'slow-network'
              : 'slow';

            const lines = [
              `verdict: ${verdict}` + (verdict === 'hang' ? ' (renderer unresponsive, browser alive)' : ''),
              `  context "${active}" [${diag?.isolation}] · renderer probe: ${probe?.rendererAlive ? `ok in ${probe.rendererMs}ms` : `timed out at ${D.probe}ms`}` +
                ` · browser probe: ${probe?.browserAlive ? `ok in ${probe.browserMs}ms` : `timed out at ${D.probe}ms`}`,
              `  network: ${diag?.net.inFlight} in flight, last event ${diag?.msSinceLastNetEvent != null ? (diag.msSinceLastNetEvent / 1000).toFixed(1) + 's ago' : 'never'}` +
                ` (${diag?.net.requests} req / ${diag?.net.responses} resp)`,
            ];
            // Same failure, different remedy — say which, or the next person guesses.
            if (verdict === 'slow' || verdict === 'slow-network') {
              lines.push('  no hang detected — the test is simply slower than its declared timeout; raise `export const timeout`');
            }

            if (verdict === 'hang' || verdict === 'browser-dead') {
              const ab = await bounded(browser.abortContext(active), D.abortAll, 'abortContext');
              const r = ab.ok ? ab.value : null;
              lines.push(`  recovery: ${r ? `context aborted (logout: ${r.logout}, closed: ${r.closed}${r.escalated ? ', escalated to browser kill' : ''})` : 'abort failed'} — next test recreates it`);
              if (r?.notes?.length) lines.push(`  notes: ${r.notes.join('; ')}`);
              if (active) dropLru(lruOrder, active);
            }
            diagnosis = { verdict, probe, net: diag?.net };
            e.message = `${e.message} — ${lines[0]}`;
            output.push(...lines);
            emit(lines.map(l => `    ${l}\n`).join(''));
          }

          const dead = diagnosis && (diagnosis.verdict === 'hang' || diagnosis.verdict === 'browser-dead');

          // Screenshot on failure FIRST — before teardown/afterEach/resetState reset the UI.
          // Skipped on a dead page: it goes through the renderer, so it can only hang.
          let shotFile = e.onecError?.screenshot;
          if (!shotFile && opts.screenshot !== 'off' && !dead) {
            const shot = await bounded(browser.screenshot(), D.screenshot, 'screenshot');
            if (shot.ok) {
              try {
                shotFile = resolve(reportDir, `error-${testIdx}-${slugify(t.file.replace(/\.test\.mjs$/, ''))}.png`);
                writeFileSync(shotFile, shot.value);
              } catch { shotFile = undefined; }
            }
          } else if (shotFile && dirname(resolve(shotFile)) !== reportDir) {
            // Shot came from a context built before setErrorShotDir (e.g. a server
            // session started earlier): reporters attach by basename, so anything
            // outside reportDir is a dead link. Move it in under a unique name.
            const dest = resolve(reportDir, `error-${testIdx}-${slugify(t.file.replace(/\.test\.mjs$/, ''))}.png`);
            try {
              renameSync(resolve(shotFile), dest);
              shotFile = dest;
            } catch {
              try {
                copyFileSync(resolve(shotFile), dest);
                try { unlinkSync(resolve(shotFile)); } catch {}
                shotFile = dest;
              } catch {}
            }
          }

          if (t.teardown && !dead) await bounded(t.teardown(ctx), D.teardown, 'teardown');
          const errInfo = { message: e.message, step: e.onecError?.step, screenshot: shotFile, onecError: e.onecError, diagnosis };
          ctx.testResult = { status: 'failed', duration: elapsed(t0), attempts: attempt, error: errInfo, steps };
          if (hooks.afterEach) await bounded(hooks.afterEach(ctx), D.afterEach, 'hooks.afterEach');
          // resetState drives the UI (up to 10 × getFormState + closeForm, all page.evaluate).
          // On a dead page it cannot succeed — the slot is already gone anyway.
          if (!dead) {
            for (const cn of testContextNames) {
              if (!browser.hasContext(cn)) continue;
              await resetOrAbort(cn, ctx);
            }
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            await bounded(browser.stopRecording(), D.stopRecording, 'stopRecording');
          }
          lastError = errInfo;
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, contexts: testContextNames, severity: t.severity, status: 'failed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: errInfo, screenshot: shotFile, video: videoFile };

          // A wedged renderer is not flakiness — retrying just buys another full timeout
          // plus another abort. Stop after the first hang.
          if (dead) break;
        }
      }

      // strict policy: release this test's non-pinned contexts right after it (all attempts done),
      // instead of keeping them for reuse. Frees 1C licenses ASAP on shared/tight stands. Parks
      // active on a survivor before closing; never closes the sole remaining context.
      if (contextPolicy === 'strict') {
        for (const name of testContextNames) {
          if (pinnedSet.has(name) || !browser.hasContext(name)) continue;
          if (browser.getActiveContext() === name) {
            const survivor = browser.listContexts().find(n => n !== name);
            if (!survivor) continue; // can't close the sole active context — leave it open
            try { await browser.setActiveContext(survivor); } catch {}
          }
          if (hooks.beforeCloseContext && hookCtx) {
            try { await hooks.beforeCloseContext(hookCtx, name, contextSpecs[name]); }
            catch (e) { hookLog(`beforeCloseContext("${name}") threw: ${e.message.split('\n')[0]}`); }
          }
          try { await browser.closeContext(name); } catch {}
          dropLru(lruOrder, name);
        }
      }

      recordResult(testResult);

      if (testResult.status === 'passed') {
        passCount++;
        W.write(`  ✓ ${t.name} (${testResult.duration}s)\n`);
      } else {
        failCount++;
        W.write(`  ✗ ${t.name} (${testResult.duration}s)\n`);
        printSteps(W, testResult.steps, '    ');
        if (lastError?.message) W.write(`    ${lastError.message}\n`);
        if (lastError?.screenshot) W.write(`    screenshot: ${lastError.screenshot}\n`);
      }

      flushDiag();

      if (opts.bail && testResult.status === 'failed') break;
    }

    // Out of the per-test scope (also on `break`): afterAll and the final teardown have no test
    // to nest under, so their diagnostics go straight to the stream again.
    flushDiag();

    if (hooks.afterAll) await bounded(hooks.afterAll(ctx), D.hooks, 'hooks.afterAll');

  } finally {
    clearTimeout(globalTimer);
    // Per-context teardown
    try {
      const remaining = browser.listContexts();
      if (remaining.length > 0) {
        const survivor = remaining[0];
        await bounded(browser.setActiveContext(survivor), D.setActive, `setActiveContext(${survivor})`);
        for (let i = remaining.length - 1; i >= 1; i--) {
          const name = remaining[i];
          if (hooks.beforeCloseContext && hookCtx) {
            try { await hooks.beforeCloseContext(hookCtx, name, contextSpecs[name]); }
            catch (e) { hookLog(`beforeCloseContext("${name}") threw: ${e.message.split('\n')[0]}`); }
          }
          // closeContext goes through the page (logout + close). If it breaches, fall back to
          // abortContext: it logs out from Node, which is the path that survives a dead page.
          const cc = await bounded(browser.closeContext(name), D.closeContext, `closeContext(${name})`);
          if (!cc.ok) await bounded(browser.abortContext(name), D.closeContext, `abortContext(${name})`);
        }
        if (hooks.beforeCloseContext && hookCtx) {
          try { await hooks.beforeCloseContext(hookCtx, survivor, contextSpecs[survivor]); }
          catch (e) { hookLog(`beforeCloseContext("${survivor}") threw: ${e.message.split('\n')[0]}`); }
        }
      }
    } catch (e) {
      hookLog(`final teardown loop failed: ${e.message.split('\n')[0]}`);
    }
    await bounded(browser.disconnect(), D.disconnect, 'disconnect');
    if (hooks.cleanup) await bounded(hooks.cleanup(hookEnv), D.hooks, 'hooks.cleanup');
  }

  const totalDuration = results.reduce((s, r) => s + r.duration, 0);
  W.write(`\n${passCount} passed, ${failCount} failed, ${skipCount} skipped (${formatDuration(totalDuration)})\n\n`);

  writeFinalReport('complete');

  if (failCount > 0) process.exit(1);

  /**
   * Allure results are already on disk (recordResult writes each test as it finishes), so this
   * only completes the formats that need whole-run totals. Also called from hardStop, where
   * `state` is 'aborted' and `results` holds whatever finished before the ceiling hit.
   */
  function writeFinalReport(state) {
    const report = buildReport(state);
    if (opts.format === 'allure') {
      // Guard against a result-producing path that skipped recordResult; normally a no-op.
      if (!allureWritten) writeAllure(results, reportDir, severityIndex);
      syncAllureExtras(suiteRoot, reportDir);
    } else if (opts.format === 'junit') {
      if (reportToStdout) process.stdout.write(buildJUnit(report, suiteRoot) + '\n');
      else writeFileSync(resolve(opts.report), buildJUnit(report, suiteRoot));
    } else if (reportToStdout) {
      out(report);
    } else if (opts.report) {
      writeFileSync(resolve(opts.report), JSON.stringify(report, null, 2));
    }
  }
}
