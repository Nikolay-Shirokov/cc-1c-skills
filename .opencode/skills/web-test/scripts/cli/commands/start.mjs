// web-test cli/commands/start v1.2
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import http from 'http';
import { writeFileSync } from 'fs';
import * as browser from '../../browser.mjs';
import { out, die } from '../util.mjs';
import { SESSION_FILE, cleanup } from '../session.mjs';
import { handleRequest } from '../server.mjs';

export async function cmdStart(url, { user, password } = {}) {
  if (!url) die('Usage: node src/run.mjs start <url> [--user=<name> [--password=<pwd>]]');

  // A startup blocker (no free 1C licence, publication asking for credentials) is a diagnosis,
  // not a crash — connect() already released the seance and closed the browser, so print the
  // message and leave instead of dumping a stack trace that reads like an engine failure.
  let state;
  try {
    state = await browser.connect(url, { user, password });
  } catch (e) {
    die(e.message);
  }

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
    // The session file and this reply carry the user, never the password.
    out({ ok: true, message: 'Browser ready', port, ...(user ? { user } : {}), ...state });
  });

  process.on('SIGINT', async () => {
    await browser.disconnect();
    cleanup();
    process.exit(0);
  });
}
