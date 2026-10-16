// web-test cli/util v1.4 — generic helpers for CLI commands
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

// Wall-clock bounds live in the engine (session.mjs needs them too, and the engine must not
// depend on cli/). Re-exported here so CLI callers have one import site.
export { withDeadline, softDeadline, DeadlineError } from '../engine/core/deadline.mjs';

export function out(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + '\n');
}

export function die(msg) {
  process.stderr.write(msg + '\n');
  process.exit(1);
}

export function json(res, obj, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj, null, 2));
}

export async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf-8');
}

export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf-8');
}

export function elapsed(t0) {
  return Math.round((Date.now() - t0) / 100) / 10;
}

export function elapsed2(start, stop) {
  return Math.round(((stop || Date.now()) - start) / 100) / 10;
}

const TRANSLIT = {
  а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i',
  й: 'y', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't',
  у: 'u', ф: 'f', х: 'h', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '',
  э: 'e', ю: 'yu', я: 'ya',
};

/**
 * ASCII-only slug for artifact file names (screenshots, videos).
 * Non-ASCII names are unusable as Allure attachments: the Allure CLI silently
 * fails to resolve them and emits `"size": 0` with no link to the file
 * (JAVA_OPTS encoding flags do not help). Cyrillic is transliterated so the
 * name stays readable; anything else non-ASCII collapses to `-`.
 */
export function slugify(s) {
  const ascii = String(s).trim().toLowerCase()
    .replace(/[а-яё]/g, ch => TRANSLIT[ch] ?? '-');
  return ascii
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60)
    .replace(/^-|-$/g, '') || 'step';
}

export function formatDuration(seconds) {
  if (seconds < 60) return `${Math.round(seconds * 10) / 10}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round((seconds - m * 60) * 10) / 10;
  return `${m}m ${s}s`;
}

export function xmlEscape(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function interpolate(template, params) {
  return String(template).replace(/\{(\w+)\}/g, (_, key) =>
    params[key] !== undefined ? String(params[key]) : `{${key}}`);
}

export function printSteps(W, steps, indent) {
  for (let i = 0; i < steps.length; i++) {
    const s = steps[i];
    const last = i === steps.length - 1;
    const prefix = last ? '└' : '├';
    const mark = s.status === 'failed' ? '✗ ' : '';
    W.write(`${indent}${prefix} ${mark}${s.name} (${elapsed2(s.start, s.stop)}s)\n`);
    if (s.error && s.status === 'failed') {
      W.write(`${indent}  ${s.error}\n`);
    }
    if (s.steps.length) printSteps(W, s.steps, indent + '  ');
  }
}

export function usage() {
  die(`Usage: node run.mjs <command> [args]

Commands:
  start <url>              Launch browser and connect to 1C web client
  run <url> <file|->       Autonomous: connect, execute script, disconnect
  exec <file|-> [options]  Execute script (file path or - for stdin)
  shot [file]              Take screenshot (default: shot.png)
  stop                     Logout and close browser
  status                   Check session status
  test <dir|file>...       Run regression tests (*.test.mjs); accepts multiple paths

Options for exec:
  --no-record              Skip video recording (record() becomes no-op)

Global options (any command):
  --no-preserve-clipboard  Don't save/restore OS clipboard around action calls.
                           Default: on (env: WEB_TEST_PRESERVE_CLIPBOARD=0 to disable globally).

Options for test:
  --url=URL                Override the base URL (default: from webtest.config.mjs)
  --tags=smoke,crud        Filter tests by tags
  --grep=pattern           Filter tests by name (regex)
  --bail                   Stop on first failure
  --retry=N                Retry failed tests N times
  --timeout=ms             Per-test timeout (default: 30000)
  --report=path            Write machine report (JSON/JUnit) to file
  --report=-               Write machine report to stdout (progress moves to stderr)
  --report-dir=path        Directory for screenshots and other artifacts
  --screenshot=mode        on-failure (default) | every-step | off
  --format=fmt             json (default) | allure | junit
  --record                 Record video for each test (mp4 in report-dir)
  -- <hook-args...>        Everything after \`--\` is forwarded to _hooks.mjs
                           prepare/cleanup as hookArgs (runner does not parse it).
                           Example: ... tests/web-test/ -- --rebuild-stand`);
}
