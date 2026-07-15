// web-test _hang/check v1.0 — automated verdict for the hang fixture
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// The fixture itself cannot assert on the runner that is running it, and its expected result
// (`1 passed, 1 failed`, exit code 1 — the red test IS the success) is too easy to misread.
// This harness spawns the runner as a child process and turns that into a plain 0/1.
//
//   node tests/web-test/_hang/check.mjs
//
// Exit codes: 0 — the abort machinery works; 1 — it regressed; 2 — inconclusive (stand down).
import { spawn } from 'child_process';
import { existsSync, readdirSync, readFileSync, rmSync, mkdirSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { tmpdir } from 'os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '../../..');
const RUNNER = resolve(REPO, '.claude/skills/web-test/scripts/run.mjs');
const URL = 'http://localhost:9191/webtest-runner/ru_RU';

// Generous: the fixture takes ~20s (10s test timeout + probe + abort + browser relaunch).
// This bound is the point of the whole check — a regressed runner hangs forever instead.
const DEADLINE_MS = 90000;

const reportDir = resolve(tmpdir(), 'webtest-hang-check-' + process.pid);

async function standIsUp() {
  try {
    const res = await fetch(URL, { signal: AbortSignal.timeout(5000) });
    return res.ok;
  } catch { return false; }
}

function runFixture() {
  return new Promise((done) => {
    const child = spawn(process.execPath, [RUNNER, 'test', resolve(__dirname), '--format=allure', `--report-dir=${reportDir}`], {
      cwd: REPO,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { out += d; });

    const killer = setTimeout(() => {
      child.kill('SIGKILL');
      done({ out, code: null, timedOut: true });
    }, DEADLINE_MS);

    child.on('close', (code) => {
      clearTimeout(killer);
      done({ out, code, timedOut: false });
    });
  });
}

function allureResults() {
  if (!existsSync(reportDir)) return [];
  return readdirSync(reportDir)
    .filter(f => f.endsWith('-result.json'))
    .map(f => { try { return JSON.parse(readFileSync(resolve(reportDir, f), 'utf8')); } catch { return null; } })
    .filter(Boolean);
}

// ── main ──────────────────────────────────────────────────────────────────
if (!await standIsUp()) {
  console.error(`INCONCLUSIVE: стенд не отвечает на ${URL}`);
  console.error('  Фикстура проверяет раннер, а не стенд, и своих _hooks.mjs не имеет.');
  console.error('  Подними публикацию: /web-publish webtest  (или прогони обычный набор — его хуки поднимут стенд)');
  process.exit(2);
}

mkdirSync(reportDir, { recursive: true });
console.log(`running fixture (deadline ${DEADLINE_MS / 1000}s)…`);
const { out, code, timedOut } = await runFixture();
const results = allureResults();

const hung = results.find(r => /заблокированный JS-поток/.test(r.name));
const survivor = results.find(r => /следующий тест работает/.test(r.name));

const checks = [
  {
    name: 'раннер завершился (не завис)',
    ok: !timedOut,
    detail: timedOut
      ? `процесс не завершился за ${DEADLINE_MS / 1000}s и был убит — прерывание зависшего теста НЕ работает`
      : `exit code ${code}`,
  },
  {
    name: 'зависший тест распознан как hang',
    ok: /verdict: hang/.test(out),
    detail: /verdict: (\S+)/.exec(out)?.[0] || 'строки verdict в выводе нет',
  },
  {
    name: 'контекст прерван, сеанс 1С освобождён',
    ok: /recovery: context aborted \(logout: (node|page|sibling)/.test(out),
    detail: /recovery: [^\n]*/.exec(out)?.[0] || 'строки recovery в выводе нет',
  },
  {
    name: 'следующий тест прошёл (прогон поехал дальше, лицензия вернулась)',
    ok: survivor?.status === 'passed',
    detail: survivor ? `status=${survivor.status}` : 'результата 02-survivor нет вовсе',
  },
  {
    name: 'результат зависшего теста записан в отчёт',
    ok: hung?.status === 'failed',
    detail: hung ? `status=${hung.status}` : 'результата 01 нет — инкрементальная запись сломана',
  },
  {
    name: 'код выхода 1 (падение зависшего теста — штатное)',
    ok: code === 1,
    detail: `exit code ${code}`,
  },
];

console.log();
for (const c of checks) console.log(`  ${c.ok ? '✓' : '✗'} ${c.name}\n      ${c.detail}`);

const failed = checks.filter(c => !c.ok);
console.log();
if (failed.length) {
  console.log(`FAIL: ${failed.length}/${checks.length} проверок не прошло — механика прерывания сломана`);
  console.log('\n─── вывод раннера ───');
  console.log(out.trim());
  process.exit(1);
}
try { rmSync(reportDir, { recursive: true, force: true }); } catch {}
console.log(`OK: ${checks.length}/${checks.length} — таймаут прерывает зависший тест, прогон продолжается, отчёт пишется`);
process.exit(0);
