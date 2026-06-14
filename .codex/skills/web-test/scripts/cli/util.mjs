// web-test cli/util v1.2 — generic helpers for CLI commands
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

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

export function slugify(s) {
  return String(s).trim()
    .replace(/[\s/\\:*?"<>|]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60) || 'step';
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
