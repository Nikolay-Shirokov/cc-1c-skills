// web-test cli/commands/start v1.0
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import http from 'http';
import { writeFileSync } from 'fs';
import * as browser from '../../browser.mjs';
import { out, die } from '../util.mjs';
import { SESSION_FILE, cleanup } from '../session.mjs';
import { handleRequest } from '../server.mjs';

export async function cmdStart(url) {
  if (!url) die('Usage: node src/run.mjs start <url>');

  const state = await browser.connect(url);

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
