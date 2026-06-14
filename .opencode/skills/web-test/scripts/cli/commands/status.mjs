// web-test cli/commands/status v1.0 — check session
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, readFileSync } from 'fs';
import { out } from '../util.mjs';
import { SESSION_FILE } from '../session.mjs';

export function cmdStatus() {
  if (!existsSync(SESSION_FILE)) {
    out({ ok: false, message: 'No active session' });
    process.exit(1);
  }
  const sess = JSON.parse(readFileSync(SESSION_FILE, 'utf-8'));
  out({ ok: true, ...sess });
}
