// web-test cli/server v1.0 — HTTP server для exec/shot/stop/status в процессе start
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import * as browser from '../browser.mjs';
import { json, readBody } from './util.mjs';
import { cleanup } from './session.mjs';
import { executeScript } from './exec-context.mjs';

export async function handleRequest(req, res) {
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
