#!/usr/bin/env node
// web-test run v1.22 — CLI entry-point
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
 *     start/run: --user=<name> [--password=<pwd>] — log in as that infobase user
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
import { usage, die } from './cli/util.mjs';
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
  // `test` has its own per-test --timeout=ms — parse the exec bound only where it applies.
  execTimeoutMs: (cmd === 'run' || cmd === 'exec') ? parseExecTimeoutMs(rawArgs) : undefined,
};
const args = rawArgs.filter(a => !a.startsWith('--'));

// Value of a --name=value flag (first occurrence), undefined when absent. Bare words are
// positional arguments, so every valued flag uses this form.
function flagValue(name, argv = rawArgs) {
  const a = argv.find(x => x.startsWith(`--${name}=`));
  return a === undefined ? undefined : a.slice(name.length + 3);
}

// Login for start/run. An empty --user= usually means an unset shell variable — refuse rather
// than fall back to the publication's user unnoticed.
const login = { user: flagValue('user'), password: flagValue('password') };
if (cmd === 'start' || cmd === 'run') {
  if (login.user === '') die('--user= is empty');
  if (login.password !== undefined && login.user === undefined) die('--password= requires --user=');
}

// Clipboard preservation: default ON. Disabled by --no-preserve-clipboard CLI flag
// or WEB_TEST_PRESERVE_CLIPBOARD=0 env. cmdTest may further disable via config.
const preserveClipboard = !rawArgs.includes('--no-preserve-clipboard')
  && process.env.WEB_TEST_PRESERVE_CLIPBOARD !== '0';
browser.setPreserveClipboard(preserveClipboard);

function parseExecTimeoutMs(argv) {
  const DEFAULT_MS = 30 * 60 * 1000;
  // setTimeout turns anything above 2^31-1 (Infinity included) into 1 ms — a bound that large
  // would kill the script at once instead of never.
  const MAX_MS = 2147483647;
  const check = (ms, source) => {
    if (!Number.isFinite(ms) || ms <= 0 || ms > MAX_MS) {
      die(`Invalid ${source}: expected a positive number of ms up to ${MAX_MS} `
        + `(--timeout=<ms>, --timeout-min=<min>, WEB_TEST_EXEC_TIMEOUT_MS=<ms>)`);
    }
    return Math.round(ms);
  };
  const ms = flagValue('timeout', argv);
  if (ms !== undefined) return check(Number(ms), `--timeout=${ms}`);
  const min = flagValue('timeout-min', argv);
  if (min !== undefined) return check(Number(min) * 60 * 1000, `--timeout-min=${min}`);
  const env = process.env.WEB_TEST_EXEC_TIMEOUT_MS;
  if (env) return check(Number(env), `WEB_TEST_EXEC_TIMEOUT_MS=${env}`);
  return DEFAULT_MS;
}

switch (cmd) {
  case 'start':  await cmdStart(args[0], login); break;
  case 'run':    await cmdRun(args[0], args[1], flags.execTimeoutMs, login); break;
  case 'exec':   await cmdExec(args[0], flags); break;
  case 'shot':   await cmdShot(args[0]); break;
  case 'stop':   await cmdStop(); break;
  case 'status': await cmdStatus(); break;
  case 'test':   await cmdTest(rawArgs); break;
  default:       usage();
}
