// web-test cli/commands/run v1.1 — autonomous connect → exec → disconnect (no server)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { readFileSync } from 'fs';
import { resolve } from 'path';
import * as browser from '../../browser.mjs';
import { out, die, readStdin } from '../util.mjs';
import { executeScript } from '../exec-context.mjs';

export async function cmdRun(url, fileOrDash) {
  if (!url || !fileOrDash) die('Usage: node src/run.mjs run <url> <file|->');

  const code = fileOrDash === '-'
    ? await readStdin()
    : readFileSync(resolve(fileOrDash), 'utf-8');

  // Same as cmdStart: a startup blocker is a diagnosis, not a crash. connect() has already
  // released the seance and closed the browser; a stack trace pointing into session.mjs would
  // read as an engine bug and send the reader off to debug the wrong thing.
  try {
    await browser.connect(url);
  } catch (e) {
    die(e.message);
  }
  const result = await executeScript(code);
  await browser.disconnect();

  out(result);
  if (!result.ok) process.exit(1);
}
