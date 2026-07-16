// web-test cli/commands/status v1.1 — check session (active liveness probe)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, readFileSync } from 'fs';
import { out } from '../util.mjs';
import { SESSION_FILE, cleanup } from '../session.mjs';

export async function cmdStatus() {
  if (!existsSync(SESSION_FILE)) {
    out({ ok: false, ready: false, message: 'No active session' });
    process.exit(1);
  }
  const sess = JSON.parse(readFileSync(SESSION_FILE, 'utf-8'));
  // The session file is written only after connect() finished, but the server process may have
  // died since (crash/reboot) and left the file behind. Don't trust the file — probe the
  // in-process /status endpoint for real liveness.
  try {
    const resp = await fetch(`http://127.0.0.1:${sess.port}/status`, { signal: AbortSignal.timeout(2000) });
    const body = await resp.json();
    if (body.connected) {
      out({ ok: true, ready: true, ...sess });
    } else {
      out({ ok: false, ready: false, reason: 'browser-disconnected', ...sess });
      process.exit(1);
    }
  } catch {
    // Server unreachable → the file is stale (process gone). Self-heal by removing it so the
    // next status/start reads clean.
    cleanup();
    out({ ok: false, ready: false, reason: 'server-unreachable', ...sess });
    process.exit(1);
  }
}
