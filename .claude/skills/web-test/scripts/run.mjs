#!/usr/bin/env node
// web-test run v1.3 — CLI runner for 1C web client automation
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
 */
import http from 'http';
import * as browser from './browser.mjs';
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

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

async function executeScript(code, { noRecord } = {}) {
  const output = [];
  const origLog = console.log;
  const origErr = console.error;
  console.log = (...a) => output.push(a.map(String).join(' '));
  console.error = (...a) => output.push('[ERR] ' + a.map(String).join(' '));

  const t0 = Date.now();
  try {
    // Build sandbox: all browser.mjs exports + useful Node globals
    const exports = {};
    for (const [k, v] of Object.entries(browser)) {
      if (k !== 'default') exports[k] = v;
    }
    exports.writeFileSync = writeFileSync;
    exports.readFileSync = readFileSync;

    // --no-record: stub recording/narration functions to return safe defaults
    if (noRecord) {
      const noop = async () => {};
      exports.startRecording = noop;
      exports.stopRecording = async () => ({ file: null, duration: 0, size: 0 });
      exports.addNarration = async () => ({ file: null, duration: 0, size: 0, captions: 0 });
      for (const fn of ['showCaption', 'hideCaption']) {
        exports[fn] = noop;
      }
      exports.isRecording = () => false;
      exports.getCaptions = () => [];
    }

    // Wrap action functions to auto-detect 1C errors (modal, balloon)
    // and stop execution immediately with diagnostic info
    const ACTION_FNS = [
      'clickElement', 'fillFields', 'fillField', 'selectValue', 'fillTableRow',
      'deleteTableRow', 'openCommand', 'navigateSection', 'navigateLink', 'openFile',
      'closeForm', 'filterList', 'unfilterList'
    ];
    for (const name of ACTION_FNS) {
      if (typeof exports[name] !== 'function') continue;
      const orig = exports[name];
      exports[name] = async (...args) => {
        const result = await orig(...args);
        const errors = result?.errors;
        if (errors?.modal || errors?.balloon) {
          // Screenshot while the error modal is still visible (before fetchErrorStack closes it)
          let errorShot;
          try {
            const png = await exports.screenshot();
            errorShot = resolve(__dirname, '..', 'error-shot.png');
            writeFileSync(errorShot, png);
          } catch {}
          // Try to fetch call stack for modal errors before throwing
          let stack = null;
          if (errors?.modal && typeof exports.fetchErrorStack === 'function') {
            try {
              stack = await exports.fetchErrorStack(errors.modal.formNum, errors.modal.hasReport);
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

    // Normalize Windows backslash paths to prevent JS parse errors
    // (e.g. C:\Users\... → \u triggers "Invalid Unicode escape sequence")
    code = code.replace(/[A-Za-z]:\\[^\s'"`;\n)}\]]+/g, m => m.replace(/\\/g, '/'));

    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    const fn = new AsyncFunction(...Object.keys(exports), code);
    await fn(...Object.values(exports));

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
  die(`Usage: node src/run.mjs <command> [args]

Commands:
  start <url>              Launch browser and connect to 1C web client
  run <url> <file|->       Autonomous: connect, execute script, disconnect
  exec <file|-> [options]  Execute script (file path or - for stdin)
  shot [file]              Take screenshot (default: shot.png)
  stop                     Logout and close browser
  status                   Check session status

Options for exec:
  --no-record              Skip video recording (record() becomes no-op)`);
}
