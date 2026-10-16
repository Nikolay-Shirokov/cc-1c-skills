// web-test cli/commands/stop v1.0 — send stop to server
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { out } from '../util.mjs';
import { loadSession, cleanup } from '../session.mjs';

export async function cmdStop() {
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
