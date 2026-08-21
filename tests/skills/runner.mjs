#!/usr/bin/env node
// skill-test-runner v0.6 — Snapshot-based regression tests for 1C skill scripts
// Usage: node tests/skills/runner.mjs [filter] [--update-snapshots] [--runtime python] [--json report.json] [--concurrency N] [--with-validation]

import { execFileSync, execFile } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, unlinkSync, rmdirSync, readFileSync, writeFileSync,
         readdirSync, statSync, cpSync, copyFileSync, chmodSync } from 'fs';
import { createHash } from 'crypto';
import { join, resolve, dirname, relative, basename, extname } from 'path';
import { tmpdir, cpus } from 'os';

// ─── Paths ──────────────────────────────────────────────────────────────────

const ROOT      = resolve(dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Z]:)/i, '$1'));
const REPO_ROOT = resolve(ROOT, '../..');
const SKILLS    = resolve(REPO_ROOT, '.claude/skills');
const CASES     = resolve(ROOT, 'cases');
const CACHE     = resolve(ROOT, '.cache');

// ─── FS-хелперы ─────────────────────────────────────────────────────────────

// Node 24.x на Windows fs.rmSync/fs.cpSync ломаются, когда путь в АРГУМЕНТЕ содержит
// не-ASCII символы — кириллическое имя пользователя в %TEMP%, репозиторий в
// кириллическом каталоге, кириллическое имя объекта 1С в deletePath (nodejs/node#61067,
// проверено на v24.12.0). Проявления зависят от комбинации:
//   - rmSync (файл или каталог) — МОЛЧА ничего не удаляет: воркспейсы копятся в %TEMP%,
//     эталон не затирается перед --update-snapshots, deletePath не срабатывает;
//   - cpSync с не-ASCII приёмником — МОЛЧА ничего не копирует: кейсы гоняются на
//     пустом воркспейсе, а поверх существующего файла кидает «The operation
//     completed successfully»;
//   - cpSync с не-ASCII источником — НАТИВНО валит процесс (0xC0000409, try/catch
//     не спасает).
// unlinkSync/rmdirSync/copyFileSync/readdirSync не затронуты, поэтому такие пути
// вообще не отдаём быстрому пути, а обрабатываем ручным обходом; после быстрого
// пути дополнительно проверяем результат.
const nonAsciiPathUnsafe = (p) => process.platform === 'win32' && /[^\x00-\x7F]/.test(p);

function rmTreeWalkSync(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) rmTreeWalkSync(p);
    else unlinkSync(p);
  }
  rmdirSync(dir);
}

function rmrfSync(dir, opts) {
  if (!nonAsciiPathUnsafe(dir)) rmSync(dir, { recursive: true, force: true, ...opts });
  if (!existsSync(dir)) return;
  rmTreeWalkSync(dir);
  if (existsSync(dir)) throw new Error(`Failed to remove directory: ${dir}`);
}

// Удалить файл ИЛИ каталог; отсутствие пути — не ошибка (семантика force).
function rmPathSync(p) {
  if (!existsSync(p)) return;
  if (statSync(p).isDirectory()) rmrfSync(p);
  else unlinkSync(p);
}

// Обойти источник и докопировать всё, что не доставил быстрый путь cpSync.
function cpTreeRepairSync(src, dest) {
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(src, { withFileTypes: true })) {
    const s = join(src, entry.name);
    const d = join(dest, entry.name);
    if (entry.isDirectory()) cpTreeRepairSync(s, d);
    else if (!existsSync(d)) copyFileSync(s, d);
  }
}

function cpTreeSync(src, dest) {
  if (!nonAsciiPathUnsafe(src) && !nonAsciiPathUnsafe(dest)) {
    try { cpSync(src, dest, { recursive: true }); } catch { /* доберём обходом */ }
  }
  cpTreeRepairSync(src, dest);
}

// ─── CLI args ───────────────────────────────────────────────────────────────

function printHelp() {
  console.log(`skill-test-runner — Snapshot-based regression tests for 1C skill scripts

Usage:
  node tests/skills/runner.mjs [filter] [options]

Arguments:
  filter                  Substring to match case id (e.g. "form-compile" or "form-compile/table")

Options:
  --update-snapshots      Overwrite snapshot files with current actual output
  --runtime <ps|python>   Which script port to run (default: powershell)
  --json <path>           Write JSON report to <path>
  --concurrency <N>       Number of parallel workers (default: cpu count)
  --with-validation       Run platform validation (1cv8 design checks) after compile
  -v, --verbose           Verbose output
  -h, --help, /?          Show this help and exit
`);
}

function parseArgs(argv) {
  const args = { filter: null, updateSnapshots: false, runtime: 'powershell', jsonReport: null, verbose: false, concurrency: cpus().length, withValidation: false, help: false };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '-h' || a === '--help' || a === '/?' || a === '/help' || a === '?') { args.help = true; continue; }
    if (a === '--update-snapshots') { args.updateSnapshots = true; continue; }
    if (a === '--runtime' && rest[i + 1]) { args.runtime = rest[++i]; continue; }
    if (a === '--json' && rest[i + 1]) { args.jsonReport = rest[++i]; continue; }
    if (a === '--verbose' || a === '-v') { args.verbose = true; continue; }
    if (a === '--concurrency' && rest[i + 1]) { args.concurrency = parseInt(rest[++i], 10) || 1; continue; }
    if (a === '--with-validation') { args.withValidation = true; continue; }
    if (!a.startsWith('--') && !args.filter) { args.filter = a.replace(/\\/g, '/'); continue; }
  }
  return args;
}

// ─── Case discovery ─────────────────────────────────────────────────────────

function discoverCases(filter) {
  const results = [];
  if (!existsSync(CASES)) return results;

  for (const skillDir of readdirSync(CASES)) {
    const skillPath = join(CASES, skillDir);
    if (!statSync(skillPath).isDirectory()) continue;

    const skillJsonPath = join(skillPath, '_skill.json');
    if (!existsSync(skillJsonPath)) continue;

    const skillConfig = JSON.parse(readFileSync(skillJsonPath, 'utf8'));

    for (const file of readdirSync(skillPath)) {
      if (file.startsWith('_') || !file.endsWith('.json')) continue;
      const caseName = file.replace(/\.json$/, '');
      const caseId = `cases/${skillDir}/${caseName}`;

      // Apply filter
      if (filter) {
        const f = filter.replace(/\.json$/, '');
        if (!caseId.startsWith(f) && !caseId.includes(f)) continue;
      }

      const casePath = join(skillPath, file);
      const caseData = JSON.parse(readFileSync(casePath, 'utf8'));
      const snapshotDir = join(skillPath, 'snapshots', caseName);

      results.push({
        id: caseId,
        name: caseData.name || caseName,
        skillDir,
        skillConfig,
        caseData,
        casePath,
        snapshotDir,
      });
    }
  }

  return results;
}

// ─── Setup / Fixtures ───────────────────────────────────────────────────────

const SKIP = Symbol('skip');

function ensureSetup(setupName, runtime, skillCasesDir) {
  if (setupName === 'none' || !setupName) return null;

  if (setupName.startsWith('fixture:')) {
    // Resolve relative to skill's cases directory (e.g. cases/meta-validate/fixtures/...)
    const fixturePath = join(skillCasesDir, 'fixtures', setupName.slice('fixture:'.length));
    if (!existsSync(fixturePath)) throw new Error(`Fixture not found: ${fixturePath}`);
    return fixturePath;
  }

  if (setupName.startsWith('external:')) {
    // External path — use real config dump as read-only fixture.
    // Returns SKIP if path is unavailable (tests gracefully skipped).
    const extPath = resolve(REPO_ROOT, setupName.slice('external:'.length));
    if (!existsSync(extPath)) return SKIP;
    return extPath;
  }

  // Пустые конфигурации-фикстуры. Версия формата и режим совместимости — независимые оси:
  // формат задаёт платформа выгрузки, а режим влияет на дефолт <LineNumberLength> у ТЧ
  // (<=8_3_26 → 5, >=8_3_27 → 9). Отсюда две 2.20-фикстуры с разными режимами.
  // Фикстура 2.18 (8.3.25) держит границу между свойствами: TypeReductionMode там уже есть,
  // а LineNumberLength ещё нет — он появился только в 2.20.
  // Отпечаток фикстуры: аргументы плюс содержимое ОБОИХ портов cf-init. Порты берём оба,
  // чтобы каталог, собранный одним рантаймом, не пережил правку другого.
  const fixtureStamp = (args) => {
    const parts = [args.join(' ')];
    for (const ext of ['.ps1', '.py']) {
      const p = resolve(REPO_ROOT, '.claude/skills/cf-init/scripts/cf-init' + ext);
      parts.push(existsSync(p) ? createHash('sha1').update(readFileSync(p)).digest('hex') : 'нет');
    }
    return parts.join('\n');
  };

  const EMPTY_CONFIGS = {
    'empty-config': [],
    'empty-config-218': ['-FormatVersion', '2.18', '-CompatibilityMode', 'Version8_3_24'],
    'empty-config-220': ['-FormatVersion', '2.20', '-CompatibilityMode', 'Version8_3_27'],
    'empty-config-220-compat24': ['-FormatVersion', '2.20', '-CompatibilityMode', 'Version8_3_24'],
    // 2.21 (8.5) — в шапках MetaDataObject и Form появляется xmlns:pal.
    'empty-config-221': ['-FormatVersion', '2.21', '-CompatibilityMode', 'Version8_3_27'],
  };
  if (EMPTY_CONFIGS[setupName]) {
    const cached = join(CACHE, setupName);
    // Кэш инвалидируется по содержимому cf-init: без этого правка навыка не доходила до
    // фикстуры — старый каталог жил вечно, снэпшоты записывались с ним, и расхождение
    // всплывало только на машине с пустым кэшем (поймано на маке, свойство TextToSpeech).
    // Отпечаток лежит РЯДОМ с каталогом, а не внутри: фикстура копируется в рабочий каталог
    // кейса целиком, и файл изнутри неё попал бы в снэпшоты.
    const stamp = join(CACHE, setupName + '.stamp');
    const want = fixtureStamp(EMPTY_CONFIGS[setupName]);
    if (existsSync(cached)) {
      if (existsSync(stamp) && readFileSync(stamp, 'utf8') === want) return cached;
      rmrfSync(cached);
    }

    mkdirSync(cached, { recursive: true });
    const script = resolveScript('cf-init/scripts/cf-init', runtime);
    try {
      execSkillRaw(runtime, script, ['-Name', 'TestConfig', '-OutputDir', cached, ...EMPTY_CONFIGS[setupName]]);
      writeFileSync(stamp, want, 'utf8');
    } catch (e) {
      // Недоснятая фикстура, оставшаяся на диске, молча ушла бы в следующий прогон
      try { rmrfSync(cached); }
      catch (cleanupError) { console.warn(`Warning: failed to remove partial fixture ${cached}: ${cleanupError.message}`); }
      throw new Error(`Failed to create ${setupName} fixture: ${e.message}`);
    }
    return cached;
  }

  if (setupName === 'base-config') {
    const cached = join(CACHE, 'base-config');
    if (existsSync(cached)) return cached;
    throw new Error('base-config fixture not found. Run integration tests first.');
  }

  throw new Error(`Unknown setup: ${setupName}`);
}

// ─── Script resolution ──────────────────────────────────────────────────────

function resolveScript(scriptRelPath, runtime) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const full = join(SKILLS, scriptRelPath + ext);
  if (!existsSync(full)) throw new Error(`Script not found: ${full}`);
  return full;
}

function execSkillRaw(runtime, scriptPath, args, cwd) {
  const execCwd = cwd || REPO_ROOT;
  if (runtime === 'python') {
    return execFileSync(process.env.PYTHON || 'python', [scriptPath, ...args], {
      encoding: 'utf8',
      timeout: 60_000,
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: execCwd,
    });
  }
  // PowerShell
  return execFileSync('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', scriptPath, ...args
  ], {
    encoding: 'utf8',
    timeout: 60_000,
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: execCwd,
  });
}

function execSkillAsync(runtime, scriptPath, args, cwd) {
  return new Promise((resolve, reject) => {
    const execCwd = cwd || REPO_ROOT;
    const cmd = runtime === 'python'
      ? [process.env.PYTHON || 'python', [scriptPath, ...args]]
      : ['powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args]];

    const child = execFile(cmd[0], cmd[1], {
      encoding: 'utf8',
      timeout: 60_000,
      cwd: execCwd,
    }, (error, stdout, stderr) => {
      if (error) {
        const err = new Error(error.message);
        err.status = error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' ? 1 : (error.code ?? 1);
        err.stdout = stdout || '';
        err.stderr = stderr || '';
        reject(err);
      } else {
        // Оба потока, а не только stdout: предупреждение навыка уходит в stderr при exit 0,
        // и на успешном прогоне оно раньше терялось — expect.stderrContains не мог сработать.
        resolve({ stdout, stderr: stderr || '' });
      }
    });
  });
}

// ─── Workspace ──────────────────────────────────────────────────────────────

function createWorkspace(fixturePath, readOnly) {
  if (readOnly && fixturePath) {
    // Use fixture path directly without copying (for large external dirs)
    return { path: fixturePath, readOnly: true };
  }
  const tmp = mkdtempSync(join(tmpdir(), 'skill-test-'));
  if (fixturePath) {
    cpTreeSync(fixturePath, tmp);
  }
  return { path: tmp, readOnly: false };
}

function cleanupWorkspace(ws) {
  if (ws.readOnly) return;
  // On Windows, file handles from db-update (1cv8) may linger briefly after the
  // process exits — rmSync then throws EBUSY. Retry a few times, then swallow:
  // a leaked tmp dir is preferable to crashing the entire runner.
  try {
    rmrfSync(ws.path, { maxRetries: 10, retryDelay: 200 });
  } catch (e) {
    console.warn(`Warning: failed to clean workspace ${ws.path}: ${e.message}`);
  }
}

// ─── Arg building ───────────────────────────────────────────────────────────

function buildArgs(skillConfig, caseData, workDir, inputFilePath, runtime) {
  const args = [];
  const scriptPath = resolveScript(skillConfig.script, runtime);

  for (const mapping of skillConfig.args) {
    args.push(mapping.flag);

    switch (mapping.from) {
      case 'inputFile':
        // inputFrom: взять вход из файла в workDir, а не из case.input. Нужно, когда вход
        // производит preRun (например, декомпилятор) — case.input пишется ПОСЛЕ preRun и
        // затёр бы его.
        args.push(caseData.inputFrom ? join(workDir, caseData.inputFrom) : inputFilePath);
        break;
      case 'workDir':
        args.push(workDir);
        break;
      case 'outputPath':
        args.push(join(workDir, caseData.outputPath || ''));
        break;
      case 'workPath':
        // workDir + value from case.params or case (specified in mapping.field)
        const wpField = mapping.field || 'objectPath';
        const wpVal = caseData.params?.[wpField] ?? caseData[wpField];
        if (wpVal === undefined || wpVal === null || wpVal === '') {
          if (mapping.optional) {
            args.pop(); // remove the flag we pushed at the top of the loop
            break;
          }
          args.push(join(workDir, ''));
        } else {
          args.push(join(workDir, wpVal));
        }
        break;
      case 'switch':
        // flag already pushed, no value needed — remove the flag and re-push conditionally
        args.pop(); // remove flag, will re-add if switch is active
        if (caseData[mapping.flag.replace(/^-/, '')] !== false) {
          args.push(mapping.flag);
        }
        break;
      default:
        if (mapping.from.startsWith('case.')) {
          const field = mapping.from.slice(5);
          const val = caseData.params?.[field] ?? caseData[field] ?? '';
          args.push(String(val));
        } else if (mapping.from === 'literal') {
          args.push(mapping.value || '');
        }
    }
  }

  // Append extra args from case (for optional params like -Vendor, -Version).
  // Supports {workDir} substitution for tests that need absolute paths inside the workspace.
  if (caseData.args_extra) {
    args.push(...caseData.args_extra.map(a => typeof a === 'string' ? a.replace('{workDir}', workDir) : a));
  }

  return { scriptPath, args };
}

// ─── Snapshot normalization ─────────────────────────────────────────────────

const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

// Applied to the python runtime only: irons out ElementTree/lxml serialization quirks
// so a snapshot recorded from PowerShell can still be compared against the python port.
//
// Three former steps — space before `/>`, empty pair `<Tag></Tag>`, trailing whitespace —
// were REMOVED with the fix for issue #57. They masked exactly the divergence that issue
// was about (PS wrote `<a />` plus a trailing newline, python wrote `<a/>` without one),
// so port parity was being checked through the mask. Do not bring them back: the byte
// canon itself is now asserted per case via `preserves`.
//
// Четвёртый шаг — вырезание объявлений xmlns — снят по той же причине: он прятал
// целый класс расхождений (лишнее/недостающее объявление в шапке, как xmlns:pal
// формата 2.21) и к моменту снятия был мёртвым — ни один кейс на него не опирался.
function normalizeXmlContent(text) {
  let s = text;
  // Нормализация XML-декларации (регистр encoding) снята: измерением показано, что ни один
  // кейс на неё не опирался — порты пишут декларацию одинаково. Держать мёртвую маску вредно:
  // она прячет целый класс расхождений, как это было с вырезанием xmlns.
  // Единственная оставшаяся нормализация — схлопывание пробелов и переводов строк между тегами.
  // Она НЕ мертва: без неё падают 58 кейсов в 15 навыках (interface-edit, xdto-*, cfe-borrow и др.) —
  // порты реально отступают по-разному. Это отдельная задача: расхождения надо не маскировать,
  // а свести, после чего снять и эту нормализацию.
  s = s.replace(/>\s+</g, '><');
  return s;
}

function normalizeContent(text, config, relFile) {
  // Strip BOM
  let s = text.replace(/^\uFEFF/, '');
  // Normalize line endings
  s = s.replace(/\r\n/g, '\n');
  // Normalize XML differences (Python etree serialization quirks)
  if (config?.runtime === 'python') {
    s = normalizeXmlContent(s);
  }

  // Normalize UUIDs
  if (config?.normalizeUuids) {
    const uuidMap = new Map();
    let counter = 0;
    s = s.replace(UUID_RE, (match) => {
      const lower = match.toLowerCase();
      if (!uuidMap.has(lower)) {
        counter++;
        uuidMap.set(lower, `UUID-${String(counter).padStart(3, '0')}`);
      }
      return uuidMap.get(lower);
    });
  }

  return s;
}

// ─── Проверка содержимого файла по СЫРЫМ байтам ────────────────────────────
// Снэпшотное сравнение в py-прогоне режет объявления xmlns (normalizeXmlContent),
// поэтому наличие/отсутствие конкретного объявления через снэпшот не проверить —
// он совпадёт при любом исходе. Эта проверка читает файл как есть.
// spec: { file, text } | { file, text: [...] }. Возвращает массив ошибок.
function checkFileContains(workDir, spec, expectPresent) {
  const errs = [];
  const target = join(workDir, spec.file);
  if (!existsSync(target)) {
    errs.push(`${expectPresent ? 'fileContains' : 'fileNotContains'}: file not found: ${spec.file}`);
    return errs;
  }
  const text = readFileSync(target).toString('utf8').replace(/^﻿/, '');
  const needles = Array.isArray(spec.text) ? spec.text : [spec.text];
  for (const needle of needles) {
    const found = text.includes(needle);
    if (expectPresent && !found) errs.push(`${spec.file} does not contain "${needle}"`);
    if (!expectPresent && found) errs.push(`${spec.file} unexpectedly contains "${needle}"`);
  }
  return errs;
}

// Ключи expect, которые раннер действительно умеет. Неизвестный ключ = кейс,
// который молча ничего не проверяет (так уже было с 9 кейсами meta-edit) —
// поэтому он ошибка, а не игнор.
const KNOWN_EXPECT_KEYS = new Set([
  'files', 'filesAbsent', 'stdoutContains', 'stdoutNotContains', 'stderrContains', 'preserves',
  'fileContains', 'fileNotContains', 'filesEqual',
]);

function checkExpectKeys(caseData) {
  if (!caseData.expect) return [];
  const unknown = Object.keys(caseData.expect).filter(k => !KNOWN_EXPECT_KEYS.has(k));
  return unknown.map(k => `expect.${k}: раннер такого ключа не знает — кейс ничего не проверяет`);
}

// ─── Побайтовое равенство двух файлов ───────────────────────────────────────
// Нужно там, где эталон — не наш снэпшот, а файл, произведённый ПЛАТФОРМОЙ: снэпшот
// такую проверку не заменяет, потому что --update-snapshots молча принял бы дрейф.
// spec: { actual, expected }. Пути относительно workDir.
function checkFilesEqual(workDir, spec) {
  const errs = [];
  const a = join(workDir, spec.actual);
  const b = join(workDir, spec.expected);
  if (!existsSync(a)) { errs.push(`filesEqual: нет файла ${spec.actual}`); return errs; }
  if (!existsSync(b)) { errs.push(`filesEqual: нет файла ${spec.expected}`); return errs; }
  const bufA = readFileSync(a);
  const bufB = readFileSync(b);
  if (bufA.equals(bufB)) return errs;
  const linesA = bufA.toString('utf8').split('\n');
  const linesB = bufB.toString('utf8').split('\n');
  let i = 0;
  while (i < linesA.length && i < linesB.length && linesA[i] === linesB[i]) i++;
  errs.push(`filesEqual: ${spec.actual} != ${spec.expected}, первое расхождение в строке ${i + 1}`
    + `\n        ожидалось: ${(linesB[i] ?? '<конец файла>').trim()}`
    + `\n        получено:  ${(linesA[i] ?? '<конец файла>').trim()}`);
  return errs;
}

// ─── Byte-style preservation check (round-trip #44/#46/#47, канон #57) ──────
// Проверяет СЫРЫЕ байты файла (в обход normalizeContent): BOM / EOL / регистр
// encoding / финальный перенос / отсутствие &#13; / форма пустого элемента.
// spec: { file, bom, eol:"crlf"|"lf", encoding, finalNewline, noCR13,
//         selfClose:"tight", noEmptyPairs }. Возвращает массив ошибок.
function checkPreserves(workDir, spec) {
  const errs = [];
  const target = join(workDir, spec.file);
  if (!existsSync(target)) { errs.push(`preserves: file not found: ${spec.file}`); return errs; }
  const buf = readFileSync(target);
  const hasBom = buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF;
  const body = hasBom ? buf.subarray(3) : buf;
  const text = body.toString('utf8');
  if (spec.bom !== undefined && hasBom !== spec.bom)
    errs.push(`preserves: BOM expected ${spec.bom}, got ${hasBom}`);
  if (spec.eol) {
    // Считаем ОДИНОЧНЫЕ LF, а не «есть ли хоть один CR»: прежняя проверка пропускала
    // смешанный выход (cfe-init давал 10 CR на 70 строк и проходил её) — то есть
    // главный дефект #57 был ей невидим.
    let lf = 0, crlf = 0;
    for (let i = 0; i < body.length; i++) {
      if (body[i] === 0x0a) { lf++; if (i > 0 && body[i - 1] === 0x0d) crlf++; }
    }
    const loneLF = lf - crlf;
    if (spec.eol === 'crlf' && loneLF > 0)
      errs.push(`preserves: EOL expected crlf, got mixed (${crlf} CRLF + ${loneLF} lone LF)`);
    if (spec.eol === 'lf' && crlf > 0)
      errs.push(`preserves: EOL expected lf, got mixed (${crlf} CRLF + ${loneLF} lone LF)`);
  }
  if (spec.encoding) {
    const m = /encoding="([^"]+)"/.exec(text);
    if (!m || m[1] !== spec.encoding) errs.push(`preserves: encoding expected "${spec.encoding}", got "${m ? m[1] : '?'}"`);
  }
  if (spec.finalNewline !== undefined) {
    const endsNL = body.length > 0 && body[body.length - 1] === 0x0a;
    if (endsNL !== spec.finalNewline) errs.push(`preserves: finalNewline expected ${spec.finalNewline}, got ${endsNL}`);
  }
  if (spec.noCR13 && text.includes('&#13;')) errs.push(`preserves: unexpected &#13; literal in output`);
  // Канон Конфигуратора (#57): пустой элемент — <a/>, не <a /> и не <a></a>.
  // Проверено на 8 выгрузках в cfsrc: 21 294 119 самозакрывающихся тегов, пробельных 0.
  if (spec.selfClose === 'tight') {
    const spaced = text.match(/<[\w:.]+[^<>]*?\s\/>/g);
    if (spaced) errs.push(`preserves: expected tight self-closing, got ${spaced.length}× spaced (e.g. ${spaced[0].slice(0, 60)})`);
  }
  if (spec.noEmptyPairs) {
    const pairs = text.match(/<([\w:.]+)([^<>]*)><\/\1>/g) || [];
    // Плюс пара, разнесённая по строкам: опустевший контейнер выглядит как
    // `<ChildObjects>\n\t\t</ChildObjects>` и смежной проверкой НЕ ловился — так
    // прошёл незамеченным дефект form-remove/template-remove. Платформа пишет
    // только `<ChildObjects/>` (1394 на acc+erp, пустых пар 0 в обеих формах).
    // Дискриминатор — перевод строки внутри: значащий пробельный текст-узел
    // (`<xr:FillValue xsi:type="xs:string">   </xr:FillValue>`) его не содержит,
    // поэтому под проверку не попадает.
    const multiline = text.match(/<([\w:.]+)([^<>]*)>[ \t]*\r?\n\s*<\/\1>/g) || [];
    const all = [...pairs, ...multiline];
    if (all.length) {
      const sample = all[0].replace(/\s+/g, ' ').slice(0, 60);
      errs.push(`preserves: expected self-closing, got ${all.length}× empty pair (e.g. ${sample})`);
    }
  }
  return errs;
}

// ─── Snapshot comparison ────────────────────────────────────────────────────

// Capture raw byte contents of every file in dir, keyed by relative path.
// Used by idempotency checks to verify byte-equality after a re-run.
function snapshotWorkDirBytes(dir) {
  const files = listFilesRecursive(dir);
  const map = new Map();
  for (const rel of files) {
    map.set(rel, readFileSync(join(dir, rel)));
  }
  return map;
}

// Compare two byte-snapshots. Returns null if identical, else a list of diff lines.
function diffByteSnapshots(before, after) {
  const diffs = [];
  for (const [rel, b1] of before) {
    if (!after.has(rel)) { diffs.push(`removed: ${rel}`); continue; }
    const b2 = after.get(rel);
    if (b1.length !== b2.length || !b1.equals(b2)) diffs.push(`changed: ${rel} (${b1.length} -> ${b2.length} bytes)`);
  }
  for (const rel of after.keys()) {
    if (!before.has(rel)) diffs.push(`added: ${rel}`);
  }
  return diffs.length === 0 ? null : diffs;
}

function listFilesRecursive(dir, base = '') {
  const result = [];
  if (!existsSync(dir)) return result;
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const rel = base ? `${base}/${entry}` : entry;
    if (statSync(full).isDirectory()) {
      result.push(...listFilesRecursive(full, rel));
    } else {
      result.push(rel);
    }
  }
  return result.sort();
}

// Строгий режим: отсутствие эталона НЕ проходит молча. Кейс либо сверяется со снэпшотом,
// либо явно объявляет `"noSnapshot": "<причина>"`. Иначе потерянный (или не созданный при
// добавлении кейса) эталон неотличим от намеренного отсутствия — тест зелёный, а не проверяет ничего.
function compareSnapshot(workDir, snapshotDir, snapshotConfig, caseData) {
  const optOut = caseData?.noSnapshot;
  const hasSnapshotDir = existsSync(snapshotDir) && listFilesRecursive(snapshotDir).length > 0;

  if (optOut !== undefined && optOut !== false) {
    // Причина обязательна: opt-out должен стоить автору формулировки, а ревьюеру — быть виден в diff'е.
    if (typeof optOut !== 'string' || !optOut.trim()) return { match: false, badOptOut: true };
    // Мёртвый эталон: помечен как ненужный, но лежит в репозитории — выглядит покрытием, не сверяется.
    if (hasSnapshotDir) return { match: false, deadSnapshot: true };
    return { match: true, reason: `no snapshot (opt-out: ${optOut})` };
  }

  if (!hasSnapshotDir) return { match: false, missingSnapshot: true };

  const snapshotFiles = listFilesRecursive(snapshotDir);

  const diffs = [];

  for (const relFile of snapshotFiles) {
    const actualPath = join(workDir, relFile);
    const snapshotPath = join(snapshotDir, relFile);

    if (!existsSync(actualPath)) {
      diffs.push({ file: relFile, type: 'missing', detail: 'file not found in output' });
      continue;
    }

    const actualRaw = readFileSync(actualPath, 'utf8');
    const snapshotRaw = readFileSync(snapshotPath, 'utf8');

    const actual = normalizeContent(actualRaw, snapshotConfig, relFile);
    const expected = normalizeContent(snapshotRaw, snapshotConfig, relFile);

    if (actual !== expected) {
      // Find first differing line
      const actualLines = actual.split('\n');
      const expectedLines = expected.split('\n');
      let diffLine = -1;
      for (let i = 0; i < Math.max(actualLines.length, expectedLines.length); i++) {
        if (actualLines[i] !== expectedLines[i]) { diffLine = i + 1; break; }
      }
      diffs.push({
        file: relFile,
        type: 'content',
        line: diffLine,
        expected: expectedLines[diffLine - 1]?.substring(0, 600),
        actual: actualLines[diffLine - 1]?.substring(0, 600),
      });
    }
  }

  if (diffs.length === 0) return { match: true };
  return { match: false, diffs };
}

// Диагностика снэпшот-сверки — общая для обеих веток запуска (runCase / runCaseAsync),
// чтобы сообщения и условия не разъехались.
function snapshotErrors(cmp, caseId) {
  if (cmp.match) return [];
  if (cmp.badOptOut) {
    return [`Snapshot: "noSnapshot" должен быть непустой строкой с причиной, почему эталон не нужен`];
  }
  if (cmp.deadSnapshot) {
    return [`Snapshot: кейс объявил "noSnapshot", но эталон существует — он не сверяется и вводит в заблуждение.\n`
      + `  Удалите каталог snapshots/<кейс>/ либо снимите "noSnapshot"`];
  }
  if (cmp.missingSnapshot) {
    return [`Snapshot: эталон отсутствует. Создайте:\n`
      + `  node tests/skills/runner.mjs ${caseId} --update-snapshots\n`
      + `либо объявите в кейсе: "noSnapshot": "<почему эталон не нужен>"`];
  }
  const errs = [];
  for (const d of cmp.diffs || []) {
    if (d.type === 'missing') errs.push(`Snapshot: file missing — ${d.file}`);
    else errs.push(`Snapshot: ${d.file}:${d.line} differs\n  expected: ${d.expected}\n  actual:   ${d.actual}`);
  }
  return errs;
}

function updateSnapshot(workDir, snapshotDir, snapshotConfig, caseData) {
  // Кейс объявил, что эталон не нужен — не создаём. Иначе --update-snapshots по навыку
  // дорисовал бы эталон и сам породил противоречие с opt-out.
  if (caseData?.noSnapshot) return;

  // Remove old snapshot (молчаливый отказ здесь оставил бы стейл в эталоне)
  if (existsSync(snapshotDir)) rmrfSync(snapshotDir);

  // Determine which files to snapshot — all files in workDir that were created by the skill
  // For "workDir" root mode, we need to figure out what files the skill added.
  // Strategy: snapshot all files in workDir (the fixture files + skill output).
  // On comparison, only files IN the snapshot are checked, so this is safe.
  const files = listFilesRecursive(workDir);
  if (files.length === 0) return;

  mkdirSync(snapshotDir, { recursive: true });
  for (const relFile of files) {
    const src = join(workDir, relFile);
    const dst = join(snapshotDir, relFile);
    mkdirSync(dirname(dst), { recursive: true });

    const raw = readFileSync(src, 'utf8');
    const normalized = normalizeContent(raw, snapshotConfig, relFile);
    writeFileSync(dst, normalized, 'utf8');
  }
}

// ─── Post-run validation ─────────────────────────────────────────────────────

function resolveValidatePath(postValidate, caseData, workDir) {
  const pathFrom = postValidate.pathFrom || 'validatePath';
  if (pathFrom === 'workDir') return workDir;
  const relPath = caseData[pathFrom] || caseData.params?.[pathFrom];
  if (!relPath) return null; // no path — skip validation for this case
  const full = join(workDir, relPath);
  // For flat metadata objects (e.g. DefinedTypes/X) the path is a file, not a dir
  if (!existsSync(full) && existsSync(full + '.xml')) return full + '.xml';
  return full;
}

function runPostValidation(postValidate, caseData, workDir, runtime) {
  const targetPath = resolveValidatePath(postValidate, caseData, workDir);
  if (!targetPath) return null; // no validatePath in case — skip silently

  const script = resolveScript(postValidate.script, runtime);
  const args = [postValidate.flag, targetPath];
  try {
    execSkillRaw(runtime, script, args);
    return null; // validation passed
  } catch (e) {
    const detail = e.stderr?.trim() || e.stdout?.trim() || e.message;
    return `Validation failed (${postValidate.script}):\n${detail.substring(0, 500)}`;
  }
}

async function runPostValidationAsync(postValidate, caseData, workDir, runtime) {
  const targetPath = resolveValidatePath(postValidate, caseData, workDir);
  if (!targetPath) return null;

  const script = resolveScript(postValidate.script, runtime);
  const args = [postValidate.flag, targetPath];
  try {
    await execSkillAsync(runtime, script, args);
    return null;
  } catch (e) {
    const detail = e.stderr?.trim() || e.stdout?.trim() || e.message;
    return `Validation failed (${postValidate.script}):\n${detail.substring(0, 500)}`;
  }
}

// ─── Run a single case ──────────────────────────────────────────────────────

async function runCaseAsync(testCase, opts) {
  const { skillConfig, caseData, snapshotDir } = testCase;
  const t0 = performance.now();
  const setupName = caseData.setup || skillConfig.setup || 'none';
  let workspace = null;
  let workDir = null;
  let inputFile = null;

  // osOnly: gate a case to one OS (e.g. a fake platform written as a .cmd cannot run on
  // macOS/Linux at all, whatever the port). Values are process.platform strings.
  // Значение — строка или массив строк process.platform: фейк платформы бывает нужен и на
  // darwin, и на linux, а дублировать кейс ради второй ОС смысла нет.
  if (caseData.osOnly && ![].concat(caseData.osOnly).includes(process.platform)) {
    return { id: testCase.id, skill: testCase.skillDir, name: testCase.name, passed: true, skipped: true, errors: [], elapsed: '0.0s' };
  }

  // runtimeOnly: gate a case to a single port (e.g. a .cmd fake platform only runs via
  // PowerShell's Start-Process; python's list-exec can't launch it). Skipped elsewhere.
  if (caseData.runtimeOnly && caseData.runtimeOnly !== opts.runtime) {
    return { id: testCase.id, skill: testCase.skillDir, name: testCase.name, passed: true, skipped: true, errors: [], elapsed: '0.0s' };
  }

  try {
    const skillCasesDir = join(CASES, testCase.skillDir);
    const fixturePath = ensureSetup(setupName, opts.runtime, skillCasesDir);
    if (fixturePath === SKIP) {
      return { id: testCase.id, skill: testCase.skillDir, name: testCase.name, passed: true, skipped: true, errors: [], elapsed: '0.0s' };
    }
    const isExternal = typeof setupName === 'string' && setupName.startsWith('external:');
    workspace = createWorkspace(fixturePath, isExternal);
    workDir = workspace.path;
    copyCaseFiles(caseData, workDir, skillCasesDir);

    // Каталог расширения не должен совпадать по имени — БЕЗ УЧЁТА РЕГИСТРА — с тем, что фикстура
    // уже положила в корень конфигурации. На регистронезависимой ФС (Windows, APFS) такие каталоги
    // сливаются в один: кейсы cfe-* просили `ext`, а cf-init создаёт платформенный `Ext/`, и эталон
    // годами фиксировал слипшееся дерево, верное только на этих ФС (issue #74).
    const extRel = caseData.params?.extensionPath || caseData.params?.outputDir;
    if (typeof extRel === 'string' && extRel && extRel !== '.' && !extRel.includes('/') && !extRel.includes('\\')) {
      const clash = readdirSync(workDir).find(e => e.toLowerCase() === extRel.toLowerCase());
      if (clash) {
        throw new Error(
          `Каталог расширения "${extRel}" совпадает с "${clash}" из фикстуры конфигурации.\n`
          + `  На регистронезависимой ФС это один каталог — эталон зафиксирует слипшееся дерево.\n`
          + `  Назовите каталог иначе (в кейсах cfe-* принято "cfe").`);
      }
    }

    // Pre-run steps
    if (caseData.preRun) {
      for (const step of caseData.preRun) {
        // writeFile step — записать произвольный файл в workDir перед запуском скрипта
        if (step.writeFile) {
          const wfPath = join(workDir, step.writeFile.path);
          const wfContent = typeof step.writeFile.content === 'string'
            ? step.writeFile.content
            : JSON.stringify(step.writeFile.content, null, 2);
          mkdirSync(dirname(wfPath), { recursive: true });
          writeFileSync(wfPath, wfContent, 'utf8');
          // Бит исполнения: на *nix навык запускает платформу через exec, и фейк без +x
          // не стартует вовсе. На Windows chmod — no-op.
          if (step.writeFile.executable) chmodSync(wfPath, 0o755);
          continue;
        }
        // deletePath step — убрать файл или каталог из workDir: так выражается состояние,
        // которое навыки сами не создают (например, пометка свойства без файла модуля).
        if (step.deletePath) {
          rmPathSync(join(workDir, step.deletePath));
          continue;
        }
        const preScript = resolveScript(step.script, opts.runtime);
        const preArgs = [];
        for (const [flag, value] of Object.entries(step.args || {})) {
          preArgs.push(flag);
          if (value === true || value === '') continue;
          preArgs.push(String(value).replace('{workDir}', workDir).replace('{inputFile}', ''));
        }
        let preInputFile = null;
        if (step.input) {
          preInputFile = join(workDir, '__pre_input.json');
          writeFileSync(preInputFile, JSON.stringify(step.input, null, 2), 'utf8');
          for (let i = 0; i < preArgs.length; i++) {
            if (preArgs[i] === '') preArgs[i] = preInputFile;
          }
        }
        try {
          const preCwd = step.cwd === '{workDir}' ? workDir : undefined;
          await execSkillAsync(opts.runtime, preScript, preArgs, preCwd);
        } catch (e) {
          throw new Error(`preRun step "${step.script}" failed: ${e.stderr || e.message}`);
        }
        if (preInputFile && existsSync(preInputFile)) unlinkSync(preInputFile);
      }
    }

    // Write input
    if (caseData.input !== undefined) {
      inputFile = join(workDir, '__input.json');
      writeFileSync(inputFile, JSON.stringify(caseData.input, null, 2), 'utf8');
    }

    // Execute
    const { scriptPath, args } = buildArgs(skillConfig, caseData, workDir, inputFile, opts.runtime);
    let stdout = '', stderr = '', exitCode = 0;
    try {
      const execCwd = (caseData.cwd || skillConfig.cwd) === 'workDir' ? workDir : undefined;
      ({ stdout, stderr } = await execSkillAsync(opts.runtime, scriptPath, args, execCwd));
    } catch (e) {
      exitCode = e.status ?? 1;
      stdout = e.stdout || '';
      stderr = e.stderr || '';
    }

    if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);

    // Assertions
    const errors = [];
    errors.push(...checkExpectKeys(caseData));
    if (caseData.expectError) {
      if (exitCode === 0) errors.push('Expected error (non-zero exit) but got exitCode=0');
      if (typeof caseData.expectError === 'string' && !stderr.includes(caseData.expectError)) {
        errors.push(`Expected stderr to contain "${caseData.expectError}", got: ${stderr.substring(0, 200)}`);
      }
    } else {
      if (exitCode !== 0) {
        errors.push(`exitCode=${exitCode}\nstdout: ${stdout.substring(0, 300)}\nstderr: ${stderr.substring(0, 300)}`);
      }
      if (caseData.expect?.files) {
        for (const f of caseData.expect.files) {
          if (!existsSync(join(workDir, f))) errors.push(`Expected file not found: ${f}`);
        }
      }
    }
    // stdout checks apply to negative cases too — a case that says what the failure must
    // print was silently checking nothing when they lived in the positive branch only.
    {
      if (caseData.expect?.stdoutContains) {
        const needles = Array.isArray(caseData.expect.stdoutContains)
          ? caseData.expect.stdoutContains : [caseData.expect.stdoutContains];
        for (const needle of needles) {
          if (!stdout.includes(needle)) errors.push(`stdout does not contain "${needle}"`);
        }
      }
      if (caseData.expect?.stdoutNotContains) {
        const needles = Array.isArray(caseData.expect.stdoutNotContains)
          ? caseData.expect.stdoutNotContains : [caseData.expect.stdoutNotContains];
        for (const needle of needles) {
          if (stdout.includes(needle)) errors.push(`stdout unexpectedly contains "${needle}"`);
        }
      }
      // Предупреждение — не отказ: навык печатает его в stderr и продолжает работу. Без
      // отдельного ключа такой кейс проверял бы только exit 0, то есть молчание вместо текста.
      if (caseData.expect?.stderrContains) {
        const needles = Array.isArray(caseData.expect.stderrContains)
          ? caseData.expect.stderrContains : [caseData.expect.stderrContains];
        for (const needle of needles) {
          if (!stderr.includes(needle)) errors.push(`stderr does not contain "${needle}"`);
        }
      }
      // Отсутствие файла — тоже утверждение, и нужно оно чаще всего НЕГАТИВНОМУ кейсу:
      // «отказ произошёл до записи». В позитивной ветке (где живёт expect.files) такой
      // проверки не было бы ровно там, где она единственная содержательная.
      if (caseData.expect?.filesAbsent) {
        const paths = Array.isArray(caseData.expect.filesAbsent)
          ? caseData.expect.filesAbsent : [caseData.expect.filesAbsent];
        for (const p of paths) {
          if (existsSync(join(workDir, p))) errors.push(`File must not exist: ${p}`);
        }
      }
    }
    if (!caseData.expectError) {
      if (caseData.expect?.preserves) {
        const specs = Array.isArray(caseData.expect.preserves)
          ? caseData.expect.preserves : [caseData.expect.preserves];
        for (const spec of specs) errors.push(...checkPreserves(workDir, spec));
      }
      if (caseData.expect?.filesEqual) {
        const specs = Array.isArray(caseData.expect.filesEqual)
          ? caseData.expect.filesEqual : [caseData.expect.filesEqual];
        for (const spec of specs) errors.push(...checkFilesEqual(workDir, spec));
      }
      if (caseData.expect?.fileContains) {
        const specs = Array.isArray(caseData.expect.fileContains)
          ? caseData.expect.fileContains : [caseData.expect.fileContains];
        for (const spec of specs) errors.push(...checkFileContains(workDir, spec, true));
      }
      if (caseData.expect?.fileNotContains) {
        const specs = Array.isArray(caseData.expect.fileNotContains)
          ? caseData.expect.fileNotContains : [caseData.expect.fileNotContains];
        for (const spec of specs) errors.push(...checkFileContains(workDir, spec, false));
      }
      if (errors.length === 0 && !caseData.expectError && !workspace.readOnly) {
        const snapshotConfig = { ...skillConfig.snapshot, runtime: opts.runtime };
        if (opts.updateSnapshots) {
          updateSnapshot(workDir, snapshotDir, snapshotConfig, caseData);
        } else {
          const cmp = compareSnapshot(workDir, snapshotDir, snapshotConfig, caseData);
          errors.push(...snapshotErrors(cmp, testCase.id));
        }
      }

      // Idempotency check: re-run the same script with the same args and assert
      // every file in workDir is byte-identical to the first-run output.
      if (errors.length === 0 && caseData.idempotent && !workspace.readOnly) {
        const before = snapshotWorkDirBytes(workDir);
        try {
          const execCwd = (caseData.cwd || skillConfig.cwd) === 'workDir' ? workDir : undefined;
          await execSkillAsync(opts.runtime, scriptPath, args, execCwd);
        } catch (e) {
          errors.push(`Idempotency rerun failed: exitCode=${e.status}\nstderr: ${(e.stderr || '').substring(0, 300)}`);
        }
        if (errors.length === 0) {
          const after = snapshotWorkDirBytes(workDir);
          const diffs = diffByteSnapshots(before, after);
          if (diffs) errors.push(`Idempotency: workspace changed on rerun:\n  ${diffs.join('\n  ')}`);
        }
      }
    }

    // Post-run validation (on real output, before cleanup)
    let validationError = null;
    if (opts.withValidation && !caseData.expectError && !caseData.skipValidation && exitCode === 0 && skillConfig.postValidate) {
      validationError = await runPostValidationAsync(skillConfig.postValidate, caseData, workDir, opts.runtime);
      if (validationError) errors.push(validationError);
    }

    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return { id: testCase.id, skill: testCase.skillDir, name: testCase.name, passed: errors.length === 0, errors, elapsed: `${elapsed}s`, snapshotUpdated: opts.updateSnapshots && !caseData.expectError && !workspace.readOnly, validationError: !!validationError };
  } catch (e) {
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return { id: testCase.id, skill: testCase.skillDir, name: testCase.name, passed: false, errors: [`Runner error: ${e.message}`], elapsed: `${elapsed}s` };
  } finally {
    if (workspace) cleanupWorkspace(workspace);
  }
}

// Скопировать файлы из каталога кейса в workDir — для навыков, вход которых
// не JSON, а файл (например XSD для xdto-compile). Так эталонные входы остаются
// читаемыми файлами, а не строками внутри JSON кейса.
function copyCaseFiles(caseData, workDir, skillCasesDir) {
  if (!caseData.caseFiles) return;
  for (const rel of caseData.caseFiles) {
    const src = join(skillCasesDir, rel);
    if (!existsSync(src)) throw new Error(`caseFiles: файл не найден: ${src}`);
    // Путь со слэшем сохраняет структуру каталогов (напр. дерево пакета),
    // простое имя кладётся в корень workDir
    const dst = rel.includes('/') ? join(workDir, rel) : join(workDir, basename(rel));
    mkdirSync(dirname(dst), { recursive: true });
    copyFileSync(src, dst);
  }
}

function runCase(testCase, opts) {
  const { skillConfig, caseData, snapshotDir } = testCase;
  const t0 = performance.now();
  const setupName = caseData.setup || skillConfig.setup || 'none';
  let workspace = null;
  let workDir = null;
  let inputFile = null;

  try {
    // 1. Setup workspace
    const skillCasesDir = join(CASES, testCase.skillDir);
    const fixturePath = ensureSetup(setupName, opts.runtime, skillCasesDir);
    if (fixturePath === SKIP) {
      const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
      return {
        id: testCase.id,
        skill: testCase.skillDir,
        name: testCase.name,
        passed: true,
        skipped: true,
        errors: [],
        elapsed: `${elapsed}s`,
      };
    }
    const isExternal = typeof setupName === 'string' && setupName.startsWith('external:');
    workspace = createWorkspace(fixturePath, isExternal);
    workDir = workspace.path;
    copyCaseFiles(caseData, workDir, skillCasesDir);

    // 2. Pre-run steps (setup prerequisites like creating objects)
    if (caseData.preRun) {
      for (const step of caseData.preRun) {
        const preScript = resolveScript(step.script, opts.runtime);
        const preArgs = [];
        for (const [flag, value] of Object.entries(step.args || {})) {
          preArgs.push(flag);
          if (value === true || value === '') {
            // Switch parameter — no value
            continue;
          }
          const resolved = String(value)
            .replace('{workDir}', workDir)
            .replace('{inputFile}', '');
          preArgs.push(resolved);
        }
        // Write step input to temp file if needed
        let preInputFile = null;
        if (step.input) {
          preInputFile = join(workDir, '__pre_input.json');
          writeFileSync(preInputFile, JSON.stringify(step.input, null, 2), 'utf8');
          // Replace {inputFile} references in args
          for (let i = 0; i < preArgs.length; i++) {
            if (preArgs[i] === '') preArgs[i] = preInputFile;
          }
        }
        try {
          const preCwd = step.cwd === '{workDir}' ? workDir : undefined;
          execSkillRaw(opts.runtime, preScript, preArgs, preCwd);
        } catch (e) {
          throw new Error(`preRun step "${step.script}" failed: ${e.stderr || e.message}`);
        }
        if (preInputFile && existsSync(preInputFile)) unlinkSync(preInputFile);
      }
    }

    // 3. Write input JSON if needed
    if (caseData.input !== undefined) {
      inputFile = join(workDir, '__input.json');
      writeFileSync(inputFile, JSON.stringify(caseData.input, null, 2), 'utf8');
    }

    // 4. Build CLI args and execute
    const { scriptPath, args } = buildArgs(skillConfig, caseData, workDir, inputFile, opts.runtime);
    let stdout = '', stderr = '', exitCode = 0;

    try {
      const execCwd = (caseData.cwd || skillConfig.cwd) === 'workDir' ? workDir : undefined;
      stdout = execSkillRaw(opts.runtime, scriptPath, args, execCwd);
    } catch (e) {
      exitCode = e.status ?? 1;
      stdout = e.stdout || '';
      stderr = e.stderr || '';
    }

    // Remove temp input file from workDir before snapshot comparison
    if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);

    // 4. Assertions
    const errors = [];
    errors.push(...checkExpectKeys(caseData));

    if (caseData.expectError) {
      // Negative case — expect failure
      if (exitCode === 0) {
        errors.push('Expected error (non-zero exit) but got exitCode=0');
      }
      if (typeof caseData.expectError === 'string' && !stderr.includes(caseData.expectError)) {
        errors.push(`Expected stderr to contain "${caseData.expectError}", got: ${stderr.substring(0, 200)}`);
      }
    } else {
      // Positive case — expect success
      if (exitCode !== 0) {
        errors.push(`exitCode=${exitCode}\nstdout: ${stdout.substring(0, 300)}\nstderr: ${stderr.substring(0, 300)}`);
      }

      // expect.files
      if (caseData.expect?.files) {
        for (const f of caseData.expect.files) {
          if (!existsSync(join(workDir, f))) {
            errors.push(`Expected file not found: ${f}`);
          }
        }
      }
    }

    // expect.stdoutContains / stdoutNotContains (string or array) — applies to negative
    // cases too: a case that says what the failure must print was silently checking
    // nothing while these lived in the positive branch only.
    {
      if (caseData.expect?.stdoutContains) {
        const needles = Array.isArray(caseData.expect.stdoutContains)
          ? caseData.expect.stdoutContains : [caseData.expect.stdoutContains];
        for (const needle of needles) {
          if (!stdout.includes(needle)) errors.push(`stdout does not contain "${needle}"`);
        }
      }
      if (caseData.expect?.stdoutNotContains) {
        const needles = Array.isArray(caseData.expect.stdoutNotContains)
          ? caseData.expect.stdoutNotContains : [caseData.expect.stdoutNotContains];
        for (const needle of needles) {
          if (stdout.includes(needle)) errors.push(`stdout unexpectedly contains "${needle}"`);
        }
      }
      // Предупреждение — не отказ: навык печатает его в stderr и продолжает работу. Без
      // отдельного ключа такой кейс проверял бы только exit 0, то есть молчание вместо текста.
      if (caseData.expect?.stderrContains) {
        const needles = Array.isArray(caseData.expect.stderrContains)
          ? caseData.expect.stderrContains : [caseData.expect.stderrContains];
        for (const needle of needles) {
          if (!stderr.includes(needle)) errors.push(`stderr does not contain "${needle}"`);
        }
      }
      // Отсутствие файла — тоже утверждение, и нужно оно чаще всего НЕГАТИВНОМУ кейсу:
      // «отказ произошёл до записи». В позитивной ветке (где живёт expect.files) такой
      // проверки не было бы ровно там, где она единственная содержательная.
      if (caseData.expect?.filesAbsent) {
        const paths = Array.isArray(caseData.expect.filesAbsent)
          ? caseData.expect.filesAbsent : [caseData.expect.filesAbsent];
        for (const p of paths) {
          if (existsSync(join(workDir, p))) errors.push(`File must not exist: ${p}`);
        }
      }
    }

    if (!caseData.expectError) {
      if (caseData.expect?.preserves) {
        const specs = Array.isArray(caseData.expect.preserves)
          ? caseData.expect.preserves : [caseData.expect.preserves];
        for (const spec of specs) errors.push(...checkPreserves(workDir, spec));
      }
      if (caseData.expect?.fileContains) {
        const specs = Array.isArray(caseData.expect.fileContains)
          ? caseData.expect.fileContains : [caseData.expect.fileContains];
        for (const spec of specs) errors.push(...checkFileContains(workDir, spec, true));
      }
      if (caseData.expect?.fileNotContains) {
        const specs = Array.isArray(caseData.expect.fileNotContains)
          ? caseData.expect.fileNotContains : [caseData.expect.fileNotContains];
        for (const spec of specs) errors.push(...checkFileContains(workDir, spec, false));
      }

      // Snapshot comparison (skip for external/read-only workspaces)
      if (errors.length === 0 && !caseData.expectError && !workspace.readOnly) {
        const snapshotConfig = { ...skillConfig.snapshot, runtime: opts.runtime };
        if (opts.updateSnapshots) {
          updateSnapshot(workDir, snapshotDir, snapshotConfig, caseData);
        } else {
          const cmp = compareSnapshot(workDir, snapshotDir, snapshotConfig, caseData);
          errors.push(...snapshotErrors(cmp, testCase.id));
        }
      }

      // Idempotency check: re-run the same script and assert byte-equality.
      if (errors.length === 0 && caseData.idempotent && !workspace.readOnly) {
        const before = snapshotWorkDirBytes(workDir);
        try {
          const execCwd = (caseData.cwd || skillConfig.cwd) === 'workDir' ? workDir : undefined;
          execSkillRaw(opts.runtime, scriptPath, args, execCwd);
        } catch (e) {
          errors.push(`Idempotency rerun failed: exitCode=${e.status}\nstderr: ${(e.stderr || '').substring(0, 300)}`);
        }
        if (errors.length === 0) {
          const after = snapshotWorkDirBytes(workDir);
          const diffs = diffByteSnapshots(before, after);
          if (diffs) errors.push(`Idempotency: workspace changed on rerun:\n  ${diffs.join('\n  ')}`);
        }
      }
    }

    // Post-run validation (on real output, before cleanup)
    let validationError = null;
    if (opts.withValidation && !caseData.expectError && !caseData.skipValidation && exitCode === 0 && skillConfig.postValidate) {
      validationError = runPostValidation(skillConfig.postValidate, caseData, workDir, opts.runtime);
      if (validationError) errors.push(validationError);
    }

    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return {
      id: testCase.id,
      skill: testCase.skillDir,
      name: testCase.name,
      passed: errors.length === 0,
      errors,
      elapsed: `${elapsed}s`,
      snapshotUpdated: opts.updateSnapshots && !caseData.expectError && !workspace.readOnly,
      validationError: !!validationError,
    };

  } catch (e) {
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return {
      id: testCase.id,
      skill: testCase.skillDir,
      name: testCase.name,
      passed: false,
      errors: [`Runner error: ${e.message}`],
      elapsed: `${elapsed}s`,
    };
  } finally {
    if (workspace) cleanupWorkspace(workspace);
  }
}

// ─── Reporter ───────────────────────────────────────────────────────────────

function printReport(results, opts, wallTime) {
  const skipped = results.filter(r => r.skipped);
  const passed = results.filter(r => r.passed && !r.skipped);
  const failed = results.filter(r => !r.passed);

  // Group by skill
  const bySkill = new Map();
  for (const r of results) {
    if (!bySkill.has(r.skill)) bySkill.set(r.skill, []);
    bySkill.get(r.skill).push(r);
  }

  console.log('');

  for (const [skill, cases] of bySkill) {
    const skillPassed = cases.filter(r => r.passed).length;
    const skillTotal = cases.length;
    const skillFailed = cases.filter(r => !r.passed);
    const skillTime = cases.reduce((s, r) => s + parseFloat(r.elapsed), 0).toFixed(1);
    const allOk = skillFailed.length === 0;

    if (opts.verbose) {
      // Verbose: show every case with id
      console.log(`  ${skill}`);
      for (const r of cases) {
        const icon = r.skipped ? '\u25CB' : r.passed ? '\u2713' : r.validationError ? '\u2717' : '\u2717';
        const suffix = r.skipped ? ' [skipped]' : r.snapshotUpdated ? ' [snapshot updated]' : r.validationError ? ' [VFAIL]' : '';
        console.log(`    ${icon} ${r.name} (${r.elapsed})  ${r.id}${suffix}`);
        if (!r.passed) {
          for (const err of r.errors) {
            for (const line of err.split('\n')) {
              console.log(`      ${line}`);
            }
          }
        }
      }
    } else {
      // Compact: one line per skill, details only for failures
      const skillSkipped = cases.filter(r => r.skipped).length;
      const icon = allOk ? '\u2713' : '\u2717';
      const skipSuffix = skillSkipped > 0 ? `, ${skillSkipped} skipped` : '';
      console.log(`  ${icon} ${skill}  ${skillPassed}/${skillTotal} (${skillTime}s${skipSuffix})`);
      if (!allOk) {
        for (const r of skillFailed) {
          console.log(`    \u2717 ${r.name}  ${r.id}`);
          for (const err of r.errors) {
            for (const line of err.split('\n')) {
              console.log(`      ${line}`);
            }
          }
        }
      }
    }
  }

  const cpuTime = results.reduce((s, r) => s + parseFloat(r.elapsed), 0).toFixed(1);
  const vfails = results.filter(r => r.validationError).length;
  console.log('');
  const skippedStr = skipped.length > 0 ? ` | Skipped: ${skipped.length}` : '';
  const vfailStr = vfails > 0 ? ` | VFail: ${vfails}` : '';
  const timeStr = wallTime ? `${wallTime}s wall, ${cpuTime}s cpu` : `${cpuTime}s`;
  console.log(`  Passed: ${passed.length} | Failed: ${failed.length}${vfailStr}${skippedStr} | Total: ${results.length} | Time: ${timeStr}`);
  console.log('');

  if (opts.jsonReport) {
    const report = {
      timestamp: new Date().toISOString(),
      runtime: opts.runtime,
      passed: passed.length,
      failed: failed.length,
      total: results.length,
      results: results.map(r => ({
        id: r.id,
        name: r.name,
        passed: r.passed,
        elapsed: r.elapsed,
        errors: r.errors.length > 0 ? r.errors : undefined,
      })),
    };
    writeFileSync(opts.jsonReport, JSON.stringify(report, null, 2), 'utf8');
    console.log(`  Report: ${opts.jsonReport}`);
  }

  return failed.length === 0;
}

// ─── Parallel pool ─────────────────────────────────────────────────────────

async function runPool(cases, opts) {
  const results = new Array(cases.length);
  let next = 0;

  async function worker() {
    while (next < cases.length) {
      const idx = next++;
      results[idx] = await runCaseAsync(cases[idx], opts);
    }
  }

  const workers = [];
  for (let i = 0; i < Math.min(opts.concurrency, cases.length); i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}

// ─── Integration tests ──────────────────────────────────────────────────────

const INTEGRATION = resolve(ROOT, 'integration');

// ─── Platform context (.v8-project.json) ─────────────────────────────────────

function loadV8Context() {
  const projectFile = join(REPO_ROOT, '.v8-project.json');
  if (!existsSync(projectFile)) return null;
  try {
    const proj = JSON.parse(readFileSync(projectFile, 'utf8'));
    const v8bin = proj.v8path;
    // Platform executable names: Windows uses .exe; *nix (macOS/Linux) plain names.
    const exeName = process.platform === 'win32' ? '1cv8.exe' : '1cv8';
    const ibcmdName = process.platform === 'win32' ? 'ibcmd.exe' : 'ibcmd';
    const v8exe = v8bin && existsSync(join(v8bin, exeName)) ? join(v8bin, exeName) : null;
    if (!v8exe) return null;
    const ibcmdExe = v8bin && existsSync(join(v8bin, ibcmdName)) ? join(v8bin, ibcmdName) : null;
    const defaultDb = proj.databases?.find(d => d.id === proj.default) || proj.databases?.[0];
    return {
      v8path: v8bin,
      v8exe,
      ibcmdExe,
      dbPath: defaultDb?.path || '',
      dbUser: defaultDb?.user || '',
      dbPassword: defaultDb?.password || '',
      configSrc: defaultDb?.configSrc || '',
      databases: proj.databases || [],
    };
  } catch { return null; }
}

async function discoverIntegration(filter) {
  if (!existsSync(INTEGRATION)) return [];
  const results = [];
  for (const file of readdirSync(INTEGRATION)) {
    if (!file.endsWith('.test.mjs')) continue;
    const testName = file.replace(/\.test\.mjs$/, '');
    const id = `integration/${testName}`;
    if (filter && !id.startsWith(filter) && !id.includes(filter)) continue;
    const mod = await import(`file://${join(INTEGRATION, file).replace(/\\/g, '/')}`);
    const engines = Array.isArray(mod.engines) && mod.engines.length ? mod.engines : ['1cv8'];
    results.push({ id, name: mod.name || testName, steps: mod.steps || [], file, cache: mod.cache, setup: mod.setup || 'empty-config', requiresPlatform: !!mod.requiresPlatform, engines });
  }
  return results;
}

// Run a test once per declared engine (engine matrix). The ibcmd pass swaps
// {v8path} → ibcmd.exe so the same steps exercise the ibcmd opt-in branch.
async function runIntegrationTest(test, opts) {
  const engines = test.engines && test.engines.length ? test.engines : ['1cv8'];
  // No platform at all → single skipped result (don't multiply across engines)
  if (test.requiresPlatform && !opts.v8ctx) {
    return [{ id: test.id, name: test.name, passed: true, skipped: true, skipReason: 'no platform', steps: [], elapsed: '0.0s', errors: [] }];
  }
  const out = [];
  const labelEngine = engines.length > 1;
  for (const engine of engines) {
    out.push(await runIntegrationOnce(test, opts, engine, labelEngine));
  }
  return out;
}

async function runIntegrationOnce(test, opts, engine, labelEngine) {
  const t0 = performance.now();
  const stepResults = [];
  let workspace = null;
  const idSuffix = labelEngine ? ` [${engine}]` : '';
  const id = test.id + idSuffix;
  const name = test.name + idSuffix;

  // ibcmd pass requires ibcmd.exe alongside 1cv8.exe
  if (engine === 'ibcmd' && !opts.v8ctx?.ibcmdExe) {
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return { id, name, passed: true, skipped: true, skipReason: 'no ibcmd.exe', steps: [], elapsed: `${elapsed}s`, errors: [] };
  }

  try {
    // Start from configured fixture or empty workspace
    const fixturePath = test.setup === 'none' ? null : ensureSetup(test.setup, opts.runtime, CASES);
    if (fixturePath === SKIP) {
      const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
      return { id, name, passed: true, skipped: true, skipReason: 'fixture unavailable', steps: [], elapsed: `${elapsed}s`, errors: [] };
    }
    workspace = createWorkspace(fixturePath, false);
    const workDir = workspace.path;

    // Platform placeholders. {v8path} resolves to ibcmd.exe on the ibcmd pass
    // (engine detected by exe name) and to the bin dir otherwise (auto-resolves 1cv8.exe).
    const v8 = opts.v8ctx || {};
    const v8pathForEngine = engine === 'ibcmd' ? (v8.ibcmdExe || '') : (v8.v8path || '');
    const replacePlaceholders = (s) => s
      .replace('{workDir}', workDir)
      .replace('{inputFile}', '')
      .replace('{v8path}', v8pathForEngine)
      .replace('{v8exe}', v8.v8exe || '')
      .replace('{dbPath}', v8.dbPath || '')
      .replace('{dbUser}', v8.dbUser || '')
      .replace('{dbPassword}', v8.dbPassword || '')
      .replace('{configSrc}', v8.configSrc || '');

    for (let i = 0; i < test.steps.length; i++) {
      const step = test.steps[i];
      const stepT0 = performance.now();

      // writeFile step: записать содержимое (обычно .bsl модуля) в workDir
      if (step.writeFile) {
        try {
          const target = replacePlaceholders(step.writeFile);
          const abs = target.includes(':') || target.startsWith('/') ? target : join(workDir, target);
          mkdirSync(dirname(abs), { recursive: true });
          writeFileSync(abs, step.content ?? '', 'utf8');
          // Бит исполнения: на *nix навык запускает платформу через exec, и фейк без +x
          // не стартует вовсе. На Windows chmod — no-op.
          if (step.executable) chmodSync(abs, 0o755);
          const stepElapsed = ((performance.now() - stepT0) / 1000).toFixed(1);
          stepResults.push({ name: step.name, passed: true, elapsed: `${stepElapsed}s` });
        } catch (e) {
          stepResults.push({ name: step.name, passed: false, error: `writeFile failed: ${e.message}` });
          break;
        }
        continue;
      }

      // editFile step: substring replace in an existing file (e.g. inject a marker)
      if (step.editFile) {
        try {
          const target = replacePlaceholders(step.editFile);
          const abs = target.includes(':') || target.startsWith('/') ? target : join(workDir, target);
          let txt = readFileSync(abs, 'utf8');
          if (!txt.includes(step.replace)) throw new Error(`pattern not found: ${step.replace}`);
          txt = txt.replace(step.replace, replacePlaceholders(step.with ?? ''));
          writeFileSync(abs, txt, 'utf8');
          const stepElapsed = ((performance.now() - stepT0) / 1000).toFixed(1);
          stepResults.push({ name: step.name, passed: true, elapsed: `${stepElapsed}s` });
        } catch (e) {
          stepResults.push({ name: step.name, passed: false, error: `editFile failed: ${e.message}` });
          break;
        }
        continue;
      }

      // assertContains step: fail unless target file contains the expected substring
      if (step.assertContains) {
        try {
          const target = replacePlaceholders(step.assertContains);
          const abs = target.includes(':') || target.startsWith('/') ? target : join(workDir, target);
          const txt = existsSync(abs) ? readFileSync(abs, 'utf8') : '';
          const needle = replacePlaceholders(step.expect ?? '');
          if (!txt.includes(needle)) throw new Error(`"${needle}" not found in ${target}`);
          const stepElapsed = ((performance.now() - stepT0) / 1000).toFixed(1);
          stepResults.push({ name: step.name, passed: true, elapsed: `${stepElapsed}s` });
        } catch (e) {
          stepResults.push({ name: step.name, passed: false, error: `assert failed: ${e.message}` });
          break;
        }
        continue;
      }

      // Write input if provided
      let inputFile = null;
      if (step.input) {
        inputFile = join(workDir, '__input.json');
        writeFileSync(inputFile, JSON.stringify(step.input, null, 2), 'utf8');
      }

      // Resolve args: replace placeholders
      const script = resolveScript(step.script, opts.runtime);
      const args = [];
      for (const [flag, value] of Object.entries(step.args || {})) {
        args.push(flag);
        if (value === true) continue; // switch
        let resolved = String(value).replace('{inputFile}', inputFile || '');
        resolved = replacePlaceholders(resolved);
        args.push(resolved);
      }

      // Execute
      let stdout = '', stderr = '';
      try {
        ({ stdout, stderr } = await execSkillAsync(opts.runtime, script, args));
      } catch (e) {
        const detail = e.stderr?.trim() || e.stdout?.trim() || e.message;
        stepResults.push({ name: step.name, passed: false, error: `Step ${i + 1} failed: ${detail.substring(0, 1000)}` });
        break; // stop on first failure
      }

      if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);

      // Post-step validation
      if (opts.withValidation && step.validate) {
        const valScript = resolveScript(step.validate.script, opts.runtime);
        let valPath = workDir;
        if (step.validate.path) {
          valPath = join(workDir, step.validate.path);
          if (!existsSync(valPath) && existsSync(valPath + '.xml')) valPath += '.xml';
        }
        try {
          await execSkillAsync(opts.runtime, valScript, [step.validate.flag, valPath]);
        } catch (e) {
          const detail = e.stderr?.trim() || e.stdout?.trim() || e.message;
          stepResults.push({ name: step.name, passed: false, error: `Validation: ${detail.substring(0, 500)}` });
          break;
        }
      }

      const stepElapsed = ((performance.now() - stepT0) / 1000).toFixed(1);
      stepResults.push({ name: step.name, passed: true, elapsed: `${stepElapsed}s` });
    }

    // Cache result if configured
    if (test.cache && stepResults.every(s => s.passed)) {
      const cachePath = join(CACHE, test.cache);
      if (existsSync(cachePath)) rmrfSync(cachePath);
      cpTreeSync(workDir, cachePath);
    }

    const allPassed = stepResults.every(s => s.passed);
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return { id, name, passed: allPassed, steps: stepResults, elapsed: `${elapsed}s`, errors: allPassed ? [] : stepResults.filter(s => !s.passed).map(s => s.error) };
  } catch (e) {
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
    return { id, name, passed: false, steps: stepResults, elapsed: `${elapsed}s`, errors: [`Runner error: ${e.message}`] };
  } finally {
    if (workspace) cleanupWorkspace(workspace);
  }
}

function printIntegrationReport(results, opts) {
  console.log('');
  for (const r of results) {
    const icon = r.skipped ? '\u25CB' : r.passed ? '\u2713' : '\u2717';
    const suffix = r.skipped ? ` [skipped — ${r.skipReason || 'no platform'}]` : '';
    console.log(`  ${icon} ${r.name} (${r.elapsed})  ${r.id}${suffix}`);
    for (const step of r.steps) {
      const sIcon = step.passed ? '\u2713' : '\u2717';
      console.log(`    ${sIcon} ${step.name}${step.elapsed ? ` (${step.elapsed})` : ''}`);
      if (!step.passed) {
        for (const line of step.error.split('\n')) {
          console.log(`      ${line}`);
        }
      }
    }
  }
  const passed = results.filter(r => r.passed).length;
  const failed = results.filter(r => !r.passed).length;
  console.log('');
  console.log(`  Integration: Passed: ${passed} | Failed: ${failed} | Total: ${results.length}`);
  console.log('');
  return failed === 0;
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) { printHelp(); return; }
  mkdirSync(CACHE, { recursive: true });

  // Load platform context for platform-dependent tests
  opts.v8ctx = loadV8Context();

  const isIntegrationFilter = opts.filter && opts.filter.startsWith('integration');

  // Run integration tests if filter matches or no filter (run both)
  let integrationOk = true;
  if (isIntegrationFilter || !opts.filter) {
    const integrationTests = await discoverIntegration(opts.filter);
    if (integrationTests.length > 0) {
      const valStr = opts.withValidation ? ', +validation' : '';
      console.log(`\nRunning ${integrationTests.length} integration test(s)... [runtime: ${opts.runtime}${valStr}]`);
      const integrationResults = [];
      for (const test of integrationTests) {
        integrationResults.push(...await runIntegrationTest(test, opts));
      }
      integrationOk = printIntegrationReport(integrationResults, opts);
    }
  }

  // Run unit cases (skip if filter is purely integration)
  let casesOk = true;
  if (!isIntegrationFilter) {
    const cases = discoverCases(opts.filter);
    if (cases.length > 0) {
      const parallel = opts.concurrency > 1;
      const modeStr = parallel ? `${opts.concurrency} workers` : 'sequential';
      const valStr = opts.withValidation ? ', +validation' : '';
      console.log(`\nRunning ${cases.length} test(s)... [runtime: ${opts.runtime}, ${modeStr}${valStr}]`);

      // Pre-warm shared fixtures before parallel run
      const setups = new Set(cases.map(c => c.caseData.setup || c.skillConfig.setup || 'none'));
      for (const setup of setups) {
        if (setup === 'empty-config' || setup === 'base-config') {
          try { ensureSetup(setup, opts.runtime, CASES); } catch {}
        }
      }

      const wallStart = performance.now();
      let results;
      if (parallel) {
        results = await runPool(cases, opts);
      } else {
        results = [];
        for (const tc of cases) {
          results.push(await runCaseAsync(tc, opts));
        }
      }
      const wallTime = ((performance.now() - wallStart) / 1000).toFixed(1);
      casesOk = printReport(results, opts, wallTime);
    } else if (opts.filter && !isIntegrationFilter) {
      console.log('No test cases found.' + (opts.filter ? ` Filter: "${opts.filter}"` : ''));
    }
  }

  process.exit(integrationOk && casesOk ? 0 : 1);
}

main();
