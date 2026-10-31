// web-test cli/session v1.0 — session-file helpers for HTTP-server mode
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { existsSync, readFileSync, unlinkSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { die } from './util.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const SESSION_FILE = resolve(__dirname, '..', '..', '.browser-session.json');

export function loadSession() {
  if (!existsSync(SESSION_FILE)) {
    die('No active session. Run: node src/run.mjs start <url>');
  }
  return JSON.parse(readFileSync(SESSION_FILE, 'utf-8'));
}

export function cleanup() {
  try { unlinkSync(SESSION_FILE); } catch {}
}
