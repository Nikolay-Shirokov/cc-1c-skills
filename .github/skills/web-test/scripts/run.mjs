#!/usr/bin/env node
// web-test run v1.19 — CLI entry-point (распилено по cli/)
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
 *   node src/run.mjs test <dir|file>... [--url]  — run regression tests
 *
 * Внутренности живут в cli/: util, session, exec-context, server,
 * commands/{start,run,exec,shot,stop,status,test}, test-runner/*.
 */
import * as browser from './browser.mjs';
import { usage } from './cli/util.mjs';
import { cmdStart } from './cli/commands/start.mjs';
import { cmdRun } from './cli/commands/run.mjs';
import { cmdExec } from './cli/commands/exec.mjs';
import { cmdShot } from './cli/commands/shot.mjs';
import { cmdStop } from './cli/commands/stop.mjs';
import { cmdStatus } from './cli/commands/status.mjs';
import { cmdTest } from './cli/commands/test.mjs';

const [,, cmd, ...rawArgs] = process.argv;
const flags = {
  noRecord: rawArgs.includes('--no-record'),
  execTimeoutMs: parseExecTimeoutMs(rawArgs),
};
const args = rawArgs.filter(a => !a.startsWith('--'));

// Clipboard preservation: default ON. Disabled by --no-preserve-clipboard CLI flag
// or WEB_TEST_PRESERVE_CLIPBOARD=0 env. cmdTest may further disable via config.
const preserveClipboard = !rawArgs.includes('--no-preserve-clipboard')
  && process.env.WEB_TEST_PRESERVE_CLIPBOARD !== '0';
browser.setPreserveClipboard(preserveClipboard);

function parseExecTimeoutMs(argv) {
  const DEFAULT_MS = 30 * 60 * 1000;
  const flagMs = argv.find(a => a.startsWith('--timeout='));
  if (flagMs) return Math.max(1, Number(flagMs.slice('--timeout='.length))) || DEFAULT_MS;
  const flagMin = argv.find(a => a.startsWith('--timeout-min='));
  if (flagMin) return Math.max(1, Number(flagMin.slice('--timeout-min='.length))) * 60 * 1000 || DEFAULT_MS;
  const env = process.env.WEB_TEST_EXEC_TIMEOUT_MS;
  if (env) return Math.max(1, Number(env)) || DEFAULT_MS;
  return DEFAULT_MS;
}

switch (cmd) {
  case 'start':  await cmdStart(args[0]); break;
  case 'run':    await cmdRun(args[0], args[1]); break;
  case 'exec':   await cmdExec(args[0], flags); break;
  case 'shot':   await cmdShot(args[0]); break;
  case 'stop':   await cmdStop(); break;
  case 'status': await cmdStatus(); break;
  case 'test':   await cmdTest(rawArgs); break;
  default:       usage();
}
