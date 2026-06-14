// web-test cli/commands/test v1.3 — regression test runner
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, writeFileSync, mkdirSync } from 'fs';
import { resolve, dirname, basename, relative } from 'path';
import * as browser from '../../browser.mjs';
import { out, die, elapsed, slugify, formatDuration, interpolate, printSteps } from '../util.mjs';
import { buildContext, buildScopedContext } from '../exec-context.mjs';
import { createAssertions } from '../test-runner/assertions.mjs';
import { buildSeverityIndex } from '../test-runner/severity.mjs';
import { writeAllure, buildJUnit, syncAllureExtras } from '../test-runner/reporters.mjs';
import { discoverTests, resetState } from '../test-runner/discover.mjs';

export async function cmdTest(rawArgs) {
  // Split off everything after `--` — those args belong to user-defined hooks
  // (see spec §6: "all arguments after `--` are forwarded verbatim to _hooks.mjs
  // via the hookArgs field; the runner does not interpret them").
  const sepIdx = rawArgs.indexOf('--');
  const ownArgs  = sepIdx >= 0 ? rawArgs.slice(0, sepIdx) : rawArgs;
  const hookArgs = sepIdx >= 0 ? rawArgs.slice(sepIdx + 1) : [];

  // Parse flags
  const opts = { bail: false, retry: 0, timeout: 30000, report: null, format: 'json', screenshot: null, reportDir: null, record: false };
  let tags = null, grep = null, urlFlag = null;
  const positional = [];
  for (const a of ownArgs) {
    if (a.startsWith('--tags='))       tags = a.slice(7).split(',');
    else if (a.startsWith('--grep='))  grep = new RegExp(a.slice(7), 'i');
    else if (a.startsWith('--url='))   urlFlag = a.slice(6);
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

  // Load config if exists. config (webtest.config.mjs) and hooks (_hooks.mjs) resolve from
  // the FIRST path's directory — list paths from the same suite folder.
  const firstPath = resolve(testPaths[0]);
  const isFile = firstPath.endsWith('.test.mjs');
  const testDir = isFile ? dirname(firstPath) : firstPath;
  const configPath = resolve(testDir, 'webtest.config.mjs');
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
    if (!fallbackUrl) die('No URL provided and no webtest.config.mjs found');
    contextSpecs.default = { url: fallbackUrl };
  }
  if (!contextSpecs[defaultContextName]) {
    die(`defaultContext "${defaultContextName}" not found in contexts: [${Object.keys(contextSpecs).join(', ')}]`);
  }
  if (!url) url = contextSpecs[defaultContextName].url;

  // Apply config defaults (CLI flags override)
  if (!tags && config.tags) tags = config.tags;
  opts.timeout = ownArgs.some(a => a.startsWith('--timeout=')) ? opts.timeout : (config.timeout || opts.timeout);
  opts.retry = ownArgs.some(a => a.startsWith('--retry=')) ? opts.retry : (config.retries || opts.retry);
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
    : (opts.report && !reportToStdout ? dirname(resolve(opts.report)) : testDir);
  if (opts.screenshot !== 'off') {
    try { mkdirSync(reportDir, { recursive: true }); } catch {}
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
  const hooksPath = resolve(testDir, '_hooks.mjs');
  let hooks = {};
  if (existsSync(hooksPath)) {
    hooks = await import('file:///' + hooksPath.replace(/\\/g, '/'));
  }

  // Human-readable report goes to stdout (test-runner convention: jest/pytest/playwright).
  // In `--report -` mode the machine JSON/XML takes over stdout, so progress moves to stderr.
  const W = reportToStdout ? process.stderr : process.stdout;
  W.write(`\nweb-test -- ${url}\n`);
  W.write(`Running ${filtered.length} tests from ${relative(process.cwd(), testDir).replace(/\\/g, '/') || '.'}/\n\n`);

  const startedAt = new Date().toISOString();
  const results = [];
  let passCount = 0, failCount = 0, skipCount = 0;

  const hookLog = (...a) => W.write(`[hooks] ${a.map(String).join(' ')}\n`);
  const hookEnv = { hookArgs, log: hookLog, config };
  if (hooks.prepare) await hooks.prepare(hookEnv);

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
    // Connect: create default context up front
    await ensureContext(defaultContextName);

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
      const declaredContexts = t.contexts && t.contexts.length
        ? t.contexts
        : [t.context || defaultContextName];

      if (t.skip) {
        const reason = typeof t.skip === 'string' ? t.skip : '';
        W.write(`  ○ ${t.name}${reason ? ` (skip: ${reason})` : ' (skip)'}\n`);
        results.push({ name: t.name, file: t.file, tags: t.tags, contexts: declaredContexts, status: 'skipped', duration: 0, attempts: 0, steps: [], output: '', error: null, screenshot: null });
        skipCount++;
        continue;
      }

      const testContextNames = declaredContexts;
      try {
        for (const cn of testContextNames) await ensureContext(cn);
        await browser.setActiveContext(testContextNames[0]);
      } catch (e) {
        W.write(`  ✗ ${t.name} (context setup failed: ${e.message})\n`);
        results.push({ name: t.name, file: t.file, tags: t.tags, contexts: declaredContexts, status: 'failed', duration: 0, attempts: 0, steps: [], output: '', error: { message: e.message }, screenshot: null });
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
          try { await browser.startRecording(videoFile, { force: true }); } catch { videoFile = null; }
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

        try {
          if (hooks.beforeEach) await hooks.beforeEach(ctx);
          if (t.setup) await t.setup(ctx);

          let timeoutTimer;
          try {
            await Promise.race([
              t.fn(ctx, t.param),
              new Promise((_, reject) => { timeoutTimer = setTimeout(() => reject(new Error(`Timeout (${t.timeout}ms)`)), t.timeout); }),
            ]);
          } finally {
            // Clear the guard timer — otherwise it stays armed in the event loop and,
            // since the success path never calls process.exit(), node can't exit until
            // it fires (up to `timeout` ms after the last test finished).
            clearTimeout(timeoutTimer);
          }

          if (t.teardown) try { await t.teardown(ctx); } catch {}
          ctx.testResult = { status: 'passed', duration: elapsed(t0), attempts: attempt, error: null, steps };
          if (hooks.afterEach) try { await hooks.afterEach(ctx); } catch {}
          for (const cn of testContextNames) {
            try { await browser.setActiveContext(cn); await resetState(ctx); } catch {}
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            try { await browser.stopRecording(); } catch {}
          }
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, contexts: testContextNames, severity: t.severity, status: 'passed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: null, screenshot: null, video: videoFile };
          lastError = null;
          break;

        } catch (e) {
          // Screenshot on failure FIRST — before teardown/afterEach/resetState reset the UI.
          let shotFile = e.onecError?.screenshot;
          if (!shotFile && opts.screenshot !== 'off') {
            try {
              const png = await browser.screenshot();
              shotFile = resolve(reportDir, `error-${testIdx}-${slugify(t.file.replace(/\.test\.mjs$/, ''))}.png`);
              writeFileSync(shotFile, png);
            } catch {}
          }

          if (t.teardown) try { await t.teardown(ctx); } catch {}
          const errInfo = { message: e.message, step: e.onecError?.step, screenshot: shotFile, onecError: e.onecError };
          ctx.testResult = { status: 'failed', duration: elapsed(t0), attempts: attempt, error: errInfo, steps };
          if (hooks.afterEach) try { await hooks.afterEach(ctx); } catch {}
          for (const cn of testContextNames) {
            try { await browser.setActiveContext(cn); await resetState(ctx); } catch {}
          }
          for (const k of scopedKeys) delete ctx[k];

          if (videoFile) {
            try { await browser.stopRecording(); } catch {}
          }
          lastError = errInfo;
          const dur = elapsed(t0);
          testResult = { name: t.name, file: t.file, tags: t.tags, contexts: testContextNames, severity: t.severity, status: 'failed', duration: dur, attempts: attempt, start: t0, stop: Date.now(), steps, output: output.join('\n'), error: errInfo, screenshot: shotFile, video: videoFile };
        }
      }

      results.push(testResult);

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

      if (opts.bail && testResult.status === 'failed') break;
    }

    if (hooks.afterAll) try { await hooks.afterAll(ctx); } catch {}

  } finally {
    // Per-context teardown
    try {
      const remaining = browser.listContexts();
      if (remaining.length > 0) {
        const survivor = remaining[0];
        try { await browser.setActiveContext(survivor); } catch {}
        for (let i = remaining.length - 1; i >= 1; i--) {
          const name = remaining[i];
          if (hooks.beforeCloseContext && hookCtx) {
            try { await hooks.beforeCloseContext(hookCtx, name, contextSpecs[name]); }
            catch (e) { hookLog(`beforeCloseContext("${name}") threw: ${e.message.split('\n')[0]}`); }
          }
          try { await browser.closeContext(name); }
          catch (e) { hookLog(`closeContext("${name}") failed: ${e.message.split('\n')[0]}`); }
        }
        if (hooks.beforeCloseContext && hookCtx) {
          try { await hooks.beforeCloseContext(hookCtx, survivor, contextSpecs[survivor]); }
          catch (e) { hookLog(`beforeCloseContext("${survivor}") threw: ${e.message.split('\n')[0]}`); }
        }
      }
    } catch (e) {
      hookLog(`final teardown loop failed: ${e.message.split('\n')[0]}`);
    }
    try { await browser.disconnect(); } catch {}
    if (hooks.cleanup) try { await hooks.cleanup(hookEnv); } catch {}
  }

  const finishedAt = new Date().toISOString();
  const totalDuration = results.reduce((s, r) => s + r.duration, 0);

  W.write(`\n${passCount} passed, ${failCount} failed, ${skipCount} skipped (${formatDuration(totalDuration)})\n\n`);

  const report = {
    runner: 'web-test', url, startedAt, finishedAt,
    duration: totalDuration,
    summary: { total: results.length, passed: passCount, failed: failCount, skipped: skipCount },
    tests: results,
  };
  if (opts.format === 'allure') {
    writeAllure(results, reportDir, severityIndex);
    syncAllureExtras(testDir, reportDir);
  } else if (opts.format === 'junit') {
    if (reportToStdout) process.stdout.write(buildJUnit(report, testDir) + '\n');
    else writeFileSync(resolve(opts.report), buildJUnit(report, testDir));
  } else if (reportToStdout) {
    out(report);
  } else if (opts.report) {
    writeFileSync(resolve(opts.report), JSON.stringify(report, null, 2));
  }

  if (failCount > 0) process.exit(1);
}
