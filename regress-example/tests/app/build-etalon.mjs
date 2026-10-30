// build-etalon.mjs v1.0 — сборка эталонного .dt: актуальный код (src/cf + расширения) поверх
// данных существующей базы или слепка, выгрузка .dt и манифест хэшей рядом с ним.
// Данные не пересоздаются — переносятся из источника.
//
//   node tests/app/build-etalon.mjs --source <база|.dt> --out <.dt> [опции]
//   node tests/app/build-etalon.mjs --source-server <srv> --source-ref <ref> --out <.dt> [опции]
//
// --source         файловая база ИЛИ готовый .dt
// --source-server  сервер 1С источника (клиент-серверная база) — вместо --source
// --source-ref     имя базы на сервере источника
// --out            эталонный .dt (рядом пишется <out>.manifest.json)
// --user / --pwd   учётная запись (по умолчанию user из stand.config.json, пароль пустой) —
//                  одна для источника и временной базы: та восстановлена из источника
// --v8path         другая программа платформы (1cv8.exe / ibcmd.exe)
// --keep-temp      не удалять временную базу (для разбора)
// --allow-dirty    собирать при незакоммиченных src/cf, src/cfe (манифест тогда неточен)
//
// Временная база — локальная файловая; эталон на выходе — переносимый .dt.

import { existsSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { join, resolve, dirname, isAbsolute, relative } from 'path';
import { execFileSync } from 'child_process';
import {
  REPO_ROOT, loadStandConfig, resolveScript, execSkill,
  cfHash, extHash, listExtensions, applyExtProps, removeDir,
} from './_stand.mjs';

function parseArgs(argv) {
  const a = { user: null, keepTemp: false, allowDirty: false, v8path: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--source') a.source = argv[++i];
    else if (argv[i] === '--source-server') a.sourceServer = argv[++i];
    else if (argv[i] === '--source-ref') a.sourceRef = argv[++i];
    else if (argv[i] === '--out') a.out = argv[++i];
    else if (argv[i] === '--user') a.user = argv[++i];
    else if (argv[i] === '--pwd') a.pwd = argv[++i];
    else if (argv[i] === '--v8path') a.v8path = argv[++i];
    else if (argv[i] === '--keep-temp') a.keepTemp = true;
    else if (argv[i] === '--allow-dirty') a.allowDirty = true;
  }
  a.serverSource = Boolean(a.sourceServer && a.sourceRef);
  if (!a.out) throw new Error('Требуется --out <.dt>. См. шапку файла.');
  if (!a.source && !a.serverSource) {
    throw new Error('Нужен источник: --source <база|.dt> ИЛИ --source-server <srv> --source-ref <ref>.');
  }
  if (a.source && a.serverSource) throw new Error('Указаны и --source, и --source-server — выберите один источник.');
  return a;
}

const abs = (p) => (isAbsolute(p) ? p : resolve(REPO_ROOT, p));
const log = (...m) => console.log('[build-etalon]', ...m);

// Замер каждой операции: старт, длительность, итоговая сводка.
const timings = [];
async function timed(label, fn) {
  log(`▶ ${label} …`);
  const t0 = Date.now();
  const r = await fn();
  const sec = (Date.now() - t0) / 1000;
  timings.push([label, sec]);
  log(`✔ ${label} — ${sec.toFixed(1)}s`);
  return r;
}

// Манифест фиксирует коммит исходников. Незакоммиченные правки в него не попадут, и стенд
// потом загрузит изменения от этого коммита — без них. Поэтому собираем на чистом дереве.
function dirtyPaths(paths) {
  return paths.filter((p) => p && existsSync(p)).filter((p) =>
    execFileSync('git', ['-C', REPO_ROOT, 'status', '--porcelain', '--', relative(REPO_ROOT, p)], { encoding: 'utf8' }).trim() !== '');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cfg = loadStandConfig();
  if (args.v8path) {
    cfg.v8path = args.v8path;
    cfg.v8bin = /\.exe$/i.test(args.v8path) ? dirname(args.v8path) : args.v8path; // ibcmd той же платформы
  }
  const dirty = dirtyPaths([cfg.cfSrc, cfg.cfeSrc]);
  if (dirty.length && !args.allowDirty) {
    throw new Error(`Есть незакоммиченные изменения: ${dirty.map((p) => relative(REPO_ROOT, p)).join(', ')}.\n` +
      'Закоммитьте их (манифест ссылается на коммит) или передайте --allow-dirty.');
  }
  const user = args.user || cfg.user;
  const auth = args.pwd ? ['-UserName', user, '-Password', args.pwd] : ['-UserName', user];
  const out = abs(args.out);
  const tempBase = join(REPO_ROOT, 'base', '_build_etalon_tmp');
  const tempDt = join(REPO_ROOT, 'base', '_build_etalon_source.dt');
  let sourceDt = null;
  let createdTempDt = false;
  const wall0 = Date.now();
  log('движок:', cfg.v8path);

  // 1. Источник → слепок данных (.dt): серверная база / файловая база / готовый .dt.
  mkdirSync(dirname(tempDt), { recursive: true });
  if (args.serverSource) {
    await timed(`db-dump-dt (база ${args.sourceServer}\\${args.sourceRef} → слепок)`, () =>
      execSkill(resolveScript('db-dump-dt/scripts/db-dump-dt'),
        ['-InfoBaseServer', args.sourceServer, '-InfoBaseRef', args.sourceRef, ...auth, '-OutputFile', tempDt, '-V8Path', cfg.v8path]));
    sourceDt = tempDt; createdTempDt = true;
  } else if (/\.dt$/i.test(args.source)) {
    sourceDt = abs(args.source); // готовый слепок — выгружать не нужно
  } else {
    await timed('db-dump-dt (файловая база → слепок)', () =>
      execSkill(resolveScript('db-dump-dt/scripts/db-dump-dt'),
        ['-InfoBasePath', abs(args.source), ...auth, '-OutputFile', tempDt, '-V8Path', cfg.v8path]));
    sourceDt = tempDt; createdTempDt = true;
  }

  try {
    // 2. Временная база: источник не трогаем.
    if (existsSync(tempBase)) removeDir(tempBase);
    await timed('db-create (временная база)', () =>
      execSkill(resolveScript('db-create/scripts/db-create'), ['-InfoBasePath', tempBase, '-V8Path', cfg.v8path]));

    // 3. Данные источника.
    await timed('db-load-dt (данные источника)', () =>
      execSkill(resolveScript('db-load-dt/scripts/db-load-dt'),
        ['-InfoBasePath', tempBase, '-InputFile', sourceDt, '-V8Path', cfg.v8path]));

    // 4. Актуальный код: src/cf и все расширения.
    await timed('db-load-xml src/cf + обновление БД', () =>
      execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
        ['-InfoBasePath', tempBase, ...auth, '-ConfigDir', cfg.cfSrc, '-UpdateDB', '-V8Path', cfg.v8path]));
    const exts = listExtensions(cfg.cfeSrc);
    for (const { dir, name } of exts) {
      await timed(`db-load-xml -Extension ${name} + обновление БД`, () =>
        execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
          ['-InfoBasePath', tempBase, ...auth, '-ConfigDir', dir, '-Extension', name, '-UpdateDB', '-V8Path', cfg.v8path]));
      await applyExtProps(cfg, tempBase, name, auth, log);
    }

    // 5. Эталон.
    mkdirSync(dirname(out), { recursive: true });
    await timed('db-dump-dt (временная база → эталон)', () =>
      execSkill(resolveScript('db-dump-dt/scripts/db-dump-dt'),
        ['-InfoBasePath', tempBase, ...auth, '-OutputFile', out, '-V8Path', cfg.v8path]));

    // 6. Манифест: хэши исходников, из которых собран эталон (теми же функциями, что и стенд).
    const manifest = {
      cfHash: cfHash(cfg.cfSrc),
      ext: Object.fromEntries(exts.map(({ dir, name }) => [name, extHash(dir)])),
      sourceCommit: execFileSync('git', ['-C', REPO_ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
      builtAt: new Date().toISOString(),
    };
    writeFileSync(out + '.manifest.json', JSON.stringify(manifest, null, 2) + '\n', 'utf8');
    log(`манифест: ${out}.manifest.json`);
  } finally {
    if (!args.keepTemp && existsSync(tempBase)) rmSync(tempBase, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
    if (createdTempDt && !args.keepTemp && existsSync(tempDt)) rmSync(tempDt, { force: true });
  }

  const total = (Date.now() - wall0) / 1000;
  log('── тайминги ──');
  for (const [label, sec] of timings) log(`   ${sec.toFixed(1).padStart(7)}s  ${label}`);
  log(`   ${total.toFixed(1).padStart(7)}s  итого (${/ibcmd/i.test(cfg.v8path) ? 'ibcmd' : '1cv8'})`);
}

main().catch((e) => { console.error('[build-etalon] ОШИБКА:', e.message); process.exit(1); });
