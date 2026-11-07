// web-test cli/commands/run v1.4 — autonomous connect → exec → disconnect (no server)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { readFileSync } from 'fs';
import { resolve } from 'path';
import * as browser from '../../browser.mjs';
import { die, readStdin } from '../util.mjs';
import { executeScript } from '../exec-context.mjs';

// Exit codes: 0 — ok, 1 — script error, 2 — script hit --timeout (same code as `test --global-timeout`).
export async function cmdRun(url, fileOrDash, execTimeoutMs, { user, password } = {}) {
  if (!url || !fileOrDash) die('Usage: node src/run.mjs run <url> <file|-> [--timeout=<ms>|--timeout-min=<min>] [--user=<name> [--password=<pwd>]]');

  const code = fileOrDash === '-'
    ? await readStdin()
    : readFileSync(resolve(fileOrDash), 'utf-8');

  // Same as cmdStart: a startup blocker is a diagnosis, not a crash. connect() has already
  // released the seance and closed the browser; a stack trace pointing into session.mjs would
  // read as an engine bug and send the reader off to debug the wrong thing.
  try {
    await browser.connect(url, { user, password });
  } catch (e) {
    die(e.message);
  }
  const result = await executeScript(code, { timeoutMs: execTimeoutMs });
  // disconnect() bounds every step itself and kills Chromium as the last resort.
  await browser.disconnect();

  // Explicit exit — after a timeout the script may still hold timers — but only once stdout has
  // drained: on POSIX pipes the write is async and an early exit cuts the JSON short.
  const exitCode = result.timedOut ? 2 : result.ok ? 0 : 1;
  process.stdout.write(JSON.stringify(result, null, 2) + '\n', () => process.exit(exitCode));
}
