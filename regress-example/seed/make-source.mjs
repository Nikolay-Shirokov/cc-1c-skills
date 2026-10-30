// make-source.mjs v1.0 — база-источник эталона ДЛЯ ПРИМЕРА (в реальном проекте не нужна).
//
// В реальном проекте источник эталона — рабочая или разведочная база с настоящими данными,
// и эталон собирают из неё: tests/app/build-etalon.mjs --source <база|.dt>. У примера такой базы
// нет, поэтому этот скрипт синтезирует её: пустая база → src/cf и расширения → запуск с /C init
// (решение само создаёт пользователей по ролям и данные — см. ИнициализацияПримера) → base/source.dt.
//
//   node seed/make-source.mjs
//   node tests/app/build-etalon.mjs --source base/source.dt --out etalon/app.dt

import { existsSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT, loadStandConfig, resolveScript, execSkill, listExtensions, applyExtProps, removeDir } from '../tests/app/_stand.mjs';

const cfg = loadStandConfig();
const base = join(REPO_ROOT, 'base', 'source');
const out = join(REPO_ROOT, 'base', 'source.dt');
const INIT_TIMEOUT_MS = 5 * 60_000;
const log = (m) => console.log(m);

// db-run запускает 1С в фоне и печатает PID; ждём выхода процесса сами — так надёжнее, чем
// угадывать паузу. process.kill(pid, 0) только проверяет, жив ли процесс.
async function waitForExit(pid, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try { process.kill(pid, 0); } catch { return true; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

try {
  if (existsSync(base)) removeDir(base);
  log(`1. db-create ${base}`);
  await execSkill(resolveScript('db-create/scripts/db-create'), ['-InfoBasePath', base, '-V8Path', cfg.v8path]);

  log('2. db-load-xml src/cf + обновление БД');
  await execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
    ['-InfoBasePath', base, '-ConfigDir', cfg.cfSrc, '-UpdateDB', '-V8Path', cfg.v8path]);
  for (const { dir, name } of listExtensions(cfg.cfeSrc)) {
    log(`3. db-load-xml расширение ${name} + обновление БД`);
    await execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
      ['-InfoBasePath', base, '-ConfigDir', dir, '-Extension', name, '-UpdateDB', '-V8Path', cfg.v8path]);
    await applyExtProps(cfg, base, name, [], log);
  }

  log('4. db-run /C init — наполнение базы');
  const runOut = await execSkill(resolveScript('db-run/scripts/db-run'),
    ['-InfoBasePath', base, '-CParam', 'init', '-V8Path', cfg.v8path]);
  const pid = Number((runOut.match(/PID:\s*(\d+)/) || [])[1]);
  if (!pid) throw new Error('db-run не сообщил PID:\n' + runOut);
  if (!(await waitForExit(pid, INIT_TIMEOUT_MS))) {
    throw new Error(`1С (PID ${pid}) не завершилась за ${INIT_TIMEOUT_MS / 1000}с — наполнение зависло, проверьте сеанс вручную`);
  }

  // Выгрузка от имени администратора заодно проверяет, что пользователи созданы:
  // в базе без пользователей такой вход не пройдёт.
  log(`5. db-dump-dt → ${out}`);
  await execSkill(resolveScript('db-dump-dt/scripts/db-dump-dt'),
    ['-InfoBasePath', base, '-UserName', cfg.user, '-OutputFile', out, '-V8Path', cfg.v8path]);

  log('\nГотово. Эталон: node tests/app/build-etalon.mjs --source base/source.dt --out etalon/app.dt');
} catch (e) {
  console.error('❌ ' + e.message);
  process.exit(1);
}
