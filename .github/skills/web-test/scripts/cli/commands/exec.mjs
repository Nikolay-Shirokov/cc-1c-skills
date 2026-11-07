// web-test cli/commands/exec v1.0 — send script to running server
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import http from 'http';
import { readFileSync } from 'fs';
import { resolve } from 'path';
import { out, die, readStdin } from '../util.mjs';
import { loadSession } from '../session.mjs';

export async function cmdExec(fileOrDash, flags = {}) {
  if (!fileOrDash) die('Usage: node src/run.mjs exec <file|-> [--no-record]');

  const code = fileOrDash === '-'
    ? await readStdin()
    : readFileSync(resolve(fileOrDash), 'utf-8');

  const sess = loadSession();
  const headers = {};
  if (flags.noRecord) headers['x-no-record'] = '1';
  const timeoutMs = flags.execTimeoutMs ?? 30 * 60 * 1000;
  const result = await new Promise((resolveP, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: sess.port, path: '/exec',
      method: 'POST', timeout: timeoutMs, headers,
    }, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => { try { resolveP(JSON.parse(data)); } catch { reject(new Error(data)); } });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(new Error(`Exec timeout (${Math.round(timeoutMs / 60000)} min)`)); });
    req.write(code);
    req.end();
  });
  out(result);
  if (!result.ok) process.exit(1);
}
