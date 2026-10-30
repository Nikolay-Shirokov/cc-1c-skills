// _stand.mjs v1.0 — стенд регресса прикладного решения: подготовка базы и публикаций.
//
// Разворачивает одноразовую базу стенда из эталонного .dt, накладывает актуальные исходники
// (src/cf, расширения src/cfe), публикует под ролями. Стадии управляются флагами и детекцией
// изменений через sha256-отметки, засеваемые из манифеста эталона (<dt>.manifest.json).
// Все операции с 1С — через скрипты навыков db-*/web-* (не прямые команды платформы).
//
// Два входа: хук раннера web-test (_hooks.mjs → prepare) и CLI без прогона тестов:
//   node tests/app/_stand.mjs up [флаги] | down | status

import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync, statSync, realpathSync } from 'fs';
import { join, resolve, dirname, relative, basename, isAbsolute, delimiter } from 'path';
import { fileURLToPath } from 'url';
import { createHash } from 'crypto';
import { execFile, execFileSync } from 'child_process';

const HERE = dirname(fileURLToPath(import.meta.url));   // tests/app
export const REPO_ROOT = resolve(HERE, '../..');
const LOCK_DIR = join(HERE, '.cache/stand');
const REGISTRY_PATH = join(REPO_ROOT, '.v8-project.json'); // реестр баз (в .gitignore) — источник паролей и точка для db-list/web-test

// ── флаги ───────────────────────────────────────────────────────────────────
// Разбор живёт здесь, а не в _hooks.mjs: флаги описывают стадии стенда, и их понимают
// оба входа — хук раннера (после `--`) и прямой CLI (`node _stand.mjs up --reload-data`).
export function parseFlags(argv = []) {
  const f = { reloadData: false, rebuildConfig: false, rebuildExt: false, republish: false };
  for (const a of argv) {
    if (a === '--reload-data') f.reloadData = true;
    else if (a === '--rebuild-config') f.rebuildConfig = true;
    else if (a === '--rebuild-ext') f.rebuildExt = true;
    else if (a === '--republish') f.republish = true;
    else if (a === '--rebuild-stand') { f.reloadData = f.rebuildConfig = f.rebuildExt = f.republish = true; }
  }
  return f;
}

// ── конфиг ──────────────────────────────────────────────────────────────────
const abs = (p) => (p && !isAbsolute(p) ? resolve(REPO_ROOT, p) : p);

export function loadStandConfig() {
  const cfg = JSON.parse(readFileSync(join(HERE, 'stand.config.json'), 'utf8'));
  // Пути в JSON — от корня проекта; потребителям (навыки, реестр) отдаём абсолютные.
  for (const k of ['standBase', 'dtPath', 'cfSrc', 'cfeSrc', 'apachePath']) cfg[k] = abs(cfg[k]);
  cfg.v8bin = /\.exe$/i.test(cfg.v8path) ? dirname(cfg.v8path) : cfg.v8path; // для web-publish (wsap24.dll)
  return cfg;
}

// ── вызов навыков ─────────────────────────────────────────────────────────────
// Корни навыков по порядку: REGRESS_SKILLS_ROOTS (через разделитель путей ОС), затем
// skillsRoots из stand.config.json, затем каталоги навыков проекта для всех платформ, под которые
// собирается набор (список — как в scripts/switch.py). Выигрывает первый существующий файл.
const PROJECT_SKILL_DIRS = [
  '.claude/skills', '.agents/skills', '.augment/skills', '.cline/skills', '.codeassistant/skills',
  '.codex/skills', '.cursor/skills', '.github/skills', '.gemini/skills', '.kilocode/skills',
  '.kiro/skills', '.opencode/skills', '.roo/skills', '.windsurf/skills',
];
function skillRoots() {
  let fromConfig = [];
  try { fromConfig = JSON.parse(readFileSync(join(HERE, 'stand.config.json'), 'utf8')).skillsRoots || []; } catch {}
  return [
    ...(process.env.REGRESS_SKILLS_ROOTS ? process.env.REGRESS_SKILLS_ROOTS.split(delimiter).filter(Boolean) : []),
    ...fromConfig,
    ...PROJECT_SKILL_DIRS,
  ].map(abs);
}

export function resolveSkillFile(rel) {
  const roots = skillRoots();
  for (const root of roots) {
    const full = join(root, rel);
    if (existsSync(full)) return full;
  }
  throw new Error(`Файл навыка не найден: ${rel}\nискали в корнях:\n  ${roots.join('\n  ')}`);
}
export function resolveScript(rel) {
  return resolveSkillFile(rel + '.ps1');
}

export function execSkill(scriptPath, args) {
  return new Promise((res, rej) => {
    execFile(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args],
      { encoding: 'utf8', timeout: 45 * 60_000, cwd: REPO_ROOT, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) rej(new Error((stderr || '').trim() || (stdout || '').trim() || err.message));
        else res(stdout);
      },
    );
  });
}

// web-publish / web-stop работают со своим экземпляром Apache стенда, если он задан
const apacheArgs = (cfg) => (cfg.apachePath ? ['-ApachePath', cfg.apachePath] : []);

// Вход в базу стенда для загрузок: пользователь из конфига. Основной путь — у него в эталоне нет
// пароля (стенд — одноразовая копия). Альтернатива, когда без пароля нельзя: переменная
// REGRESS_STAND_PASSWORD или запись реестра с тем же пользователем и базой. Запись засевает стадия
// publish — она идёт после загрузок, поэтому на первом up пароль даёт только переменная.
export function standAuth(cfg) {
  const auth = ['-UserName', cfg.user];
  let password = process.env.REGRESS_STAND_PASSWORD;
  if (password === undefined) {
    const same = (a, b) => a && b && resolve(a).toLowerCase() === resolve(b).toLowerCase();
    password = readRegistry()?.databases?.find((d) => d.user === cfg.user && same(d.path, cfg.standBase))?.password;
  }
  return password ? [...auth, '-Password', password] : auth;
}

// ── хэши и отметки ─────────────────────────────────────────────────────────────
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const relFromRoot = (p) => relative(REPO_ROOT, p).replace(/\\/g, '/');

// git-команды выполняются из корня проекта; он не обязан совпадать с корнем репозитория,
// поэтому пути — относительно него: pathspec как есть, в `HEAD:` — с префиксом `./`
function git(args, opts = {}) {
  return execFileSync('git', ['-C', REPO_ROOT, ...args], { encoding: 'utf8', ...opts });
}

export function readLock(name) {
  const f = join(LOCK_DIR, name + '.lock');
  return existsSync(f) ? readFileSync(f, 'utf8').trim() : null;
}
export function writeLock(name, hash) {
  mkdirSync(LOCK_DIR, { recursive: true });
  writeFileSync(join(LOCK_DIR, name + '.lock'), hash + '\n', 'utf8');
}

// git-дерево src/cf + отпечаток незакоммиченного по содержимому (быстро даже на большой
// конфигурации). Одних имён из `git status` мало: повторная правка уже изменённого файла
// не меняет строку статуса, и стенд пропустил бы загрузку.
export function cfHash(cfSrcAbs) {
  const rel = relFromRoot(cfSrcAbs);
  const tree = git(['rev-parse', `HEAD:./${rel}`]).trim();
  const h = createHash('sha256').update(tree + '\n');
  h.update(git(['diff', 'HEAD', '--binary', '--no-color', '--', rel], { maxBuffer: 256 * 1024 * 1024 }));
  // -z и quotePath=false: иначе git экранирует не-ASCII имена (src/cf/Catalogs/Товары.xml) и файл не прочитать
  const untracked = git(['-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard', '--', rel])
    .split('\0').filter(Boolean).sort();
  for (const f of untracked) h.update(f).update(readFileSync(join(REPO_ROOT, f)));
  return h.digest('hex');
}

// контент-хэш папки расширения (объём небольшой — честный хэш содержимого)
export function extHash(dir) {
  const h = createHash('sha256');
  const files = [];
  (function walk(d) {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else files.push(p);
    }
  })(dir);
  files.sort();
  for (const f of files) {
    h.update(f.slice(dir.length).replace(/\\/g, '/'));
    h.update(readFileSync(f));
  }
  return h.digest('hex');
}

export function extName(dir) {
  const xml = readFileSync(join(dir, 'Configuration.xml'), 'utf8');
  const m = xml.match(/<Name>([^<]+)<\/Name>/);
  if (!m) throw new Error(`Нет <Name> в ${join(dir, 'Configuration.xml')}`);
  return m[1];
}

// подпапки cfeSrc, содержащие Configuration.xml → { dir, name }
export function listExtensions(cfeSrc) {
  if (!cfeSrc || !existsSync(cfeSrc)) return [];
  return readdirSync(cfeSrc, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(cfeSrc, e.name, 'Configuration.xml')))
    .map((e) => ({ dir: join(cfeSrc, e.name), name: extName(join(cfeSrc, e.name)) }));
}

export function readManifest(dtPath) {
  const f = dtPath + '.manifest.json';
  return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : null;
}

function isCommit(ref) {
  try { git(['cat-file', '-e', ref + '^{commit}'], { stdio: 'ignore' }); return true; }
  catch { return false; }
}
function gitCleanSubtree(absPath) {
  return git(['status', '--porcelain', '--', relFromRoot(absPath)]).trim() === '';
}
function isAncestorOfHead(ref) {
  try { git(['merge-base', '--is-ancestor', ref, 'HEAD'], { stdio: 'ignore' }); return true; }
  catch { return false; }
}
const headCommit = () => git(['rev-parse', 'HEAD']).trim();
const engineLabel = (p) => (/ibcmd/i.test(p) ? 'ibcmd' : '1cv8');

// rmSync на Windows молча не удаляет пути с не-ASCII символами — проверяем результат
export function removeDir(dir) {
  rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
  if (existsSync(dir)) throw new Error(`Не удалось удалить ${dir} — база занята (Apache, открытый сеанс) или путь не поддерживается`);
}

// ── стадии ─────────────────────────────────────────────────────────────────────
async function webStop(cfg, log) {
  try {
    await execSkill(resolveScript('web-stop/scripts/web-stop'), apacheArgs(cfg));
    log('  apache stopped');
  } catch (e) {
    log('  web-stop: ' + e.message.split('\n')[0]);
  }
}

async function stageRestore(cfg, flags, log) {
  const exists = existsSync(join(cfg.standBase, '1Cv8.1CD'));
  if (exists && !flags.reloadData) {
    log('restore: skip (база есть; для сброса — --reload-data)');
    return false;
  }
  if (!existsSync(cfg.dtPath)) throw new Error(`Эталон не найден: ${cfg.dtPath} (dtPath в stand.config.json)`);
  log('restore: web-stop → drop → db-create → db-load-dt');
  // Apache держит файл базы — без остановки удалить её нельзя
  await webStop(cfg, log);
  if (existsSync(cfg.standBase)) {
    removeDir(cfg.standBase);
    log('  старая база удалена');
  }
  await execSkill(resolveScript('db-create/scripts/db-create'),
    ['-InfoBasePath', cfg.standBase, '-V8Path', cfg.v8path]);
  log(`  база создана: ${cfg.standBase}`);

  const dtMb = (statSync(cfg.dtPath).size / 1024 / 1024).toFixed(1);
  const tDt = Date.now();
  await execSkill(resolveScript('db-load-dt/scripts/db-load-dt'),
    ['-InfoBasePath', cfg.standBase, '-InputFile', cfg.dtPath, '-V8Path', cfg.v8path]);
  log(`  эталон загружен: ${basename(cfg.dtPath)} (${dtMb} МБ) за ${((Date.now() - tDt) / 1000).toFixed(1)}с`);

  // Отметки живут вне базы и переживают её пересоздание — начинаем с чистого листа, иначе
  // отметка расширения, которого нет в манифесте, совпала бы и его загрузка пропустилась.
  rmSync(LOCK_DIR, { recursive: true, force: true });
  const m = readManifest(cfg.dtPath);
  if (m) {
    if (m.cfHash) writeLock('config', m.cfHash);
    if (m.sourceCommit && isCommit(m.sourceCommit)) writeLock('config-commit', m.sourceCommit);
    for (const [n, h] of Object.entries(m.ext || {})) writeLock('ext-' + n, h);
    const parts = [];
    // sourceCommit бывает "(bootstrap)" — тогда коммита нет, отпечаток только по хэшу
    const cfRef = m.sourceCommit && isCommit(m.sourceCommit) ? m.sourceCommit.slice(0, 8) : null;
    if (m.cfHash) parts.push(`cf@${m.cfHash.slice(0, 7)}${cfRef ? ` (${cfRef})` : ''}`);
    for (const [n, h] of Object.entries(m.ext || {})) parts.push(`ext[${n}]@${h.slice(0, 7)}`);
    log(`  baseline эталона: ${parts.join(', ')} (объявлен манифестом, не сверялся с базой)`);
  } else {
    log('  ВНИМАНИЕ: манифест не найден — baseline эталона неизвестен, первая загрузка будет полной');
  }
  return true;
}

async function stageConfig(cfg, flags, log) {
  const cur = cfHash(cfg.cfSrc);
  if (!flags.rebuildConfig && cur === readLock('config')) {
    log('config: skip (src/cf совпадает с baseline)');
    return false;
  }
  // configEngine (необязательно) — ibcmd для загрузки типовой, заметно быстрее 1cv8;
  // расширения всё равно грузятся через v8path: ibcmd не разбирает расширение без типовой.
  const engine = cfg.configEngine || cfg.v8path;
  // Загрузка только изменений <последний загруженный коммит>..HEAD через db-load-git. Последний
  // загруженный — коммит эталона после restore или HEAD прошлой загрузки с чистого дерева. Можно,
  // когда HEAD — его потомок (ветку не сменили назад) и в src/cf нет незакоммиченного; иначе база
  // может держать чужую версию объектов — грузим полностью.
  const base = readLock('config-commit');
  const clean = gitCleanSubtree(cfg.cfSrc);
  const canPartial = !flags.rebuildConfig && base && isCommit(base) && isAncestorOfHead(base) && clean;
  // что теперь в базе: известный коммит (чистое дерево) или неизвестно (грязное)
  const markLoaded = () => {
    writeLock('config', cfHash(cfg.cfSrc));
    if (clean) writeLock('config-commit', headCommit());
    else rmSync(join(LOCK_DIR, 'config-commit.lock'), { force: true });
  };

  if (canPartial) {
    log(`config: partial db-load-git ${base.slice(0, 8)}..HEAD (${engineLabel(engine)})`);
    try {
      await execSkill(resolveScript('db-load-git/scripts/db-load-git'),
        ['-InfoBasePath', cfg.standBase, ...standAuth(cfg), '-ConfigDir', cfg.cfSrc,
          '-Source', 'Commit', '-CommitRange', `${base}..HEAD`, '-UpdateDB', '-V8Path', engine]);
      markLoaded();
      return true;
    } catch (e) {
      log('  partial упал → полная загрузка: ' + e.message.split('\n')[0]);
    }
  }

  log(`config: full db-load-xml src/cf + обновление БД (${engineLabel(engine)})`);
  await execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
    ['-InfoBasePath', cfg.standBase, ...standAuth(cfg), '-ConfigDir', cfg.cfSrc, '-UpdateDB', '-V8Path', engine]);
  markLoaded();
  return true;
}

// Свойства подключения расширения (stand.config.json → extensions.<имя>): безопасный режим,
// защита от опасных действий, активность. Загрузка из XML ставит безопасный режим, а в нём
// платформа не даёт перехватывать модули объектов — и сообщает об этом только в журнале
// регистрации, запись при этом проходит молча. Свойства меняет ibcmd, ему нужна монопольная
// блокировка базы: Apache, если он её держит, остановите до вызова.
const EXT_PROPS = { safeMode: '-SafeMode', unsafeActionProtection: '-UnsafeActionProtection', active: '-Active' };
export async function applyExtProps(cfg, basePath, name, auth, log) {
  const props = cfg.extensions?.[name];
  const args = Object.entries(props || {}).filter(([k]) => EXT_PROPS[k]).flatMap(([k, v]) => [EXT_PROPS[k], String(v)]);
  if (!args.length) return false;
  await execSkill(resolveScript('db-cfe-admin/scripts/db-cfe-admin'),
    ['-Command', 'set-properties', '-InfoBasePath', basePath, ...auth, '-Name', name, ...args, '-V8Path', cfg.v8bin]);
  log(`  ext[${name}]: свойства ${args.join(' ')}`);
  return true;
}

async function stageExt(cfg, flags, configRan, restored, log) {
  let anyRan = false;
  let apacheStopped = restored; // restore уже остановил Apache
  for (const { dir, name } of listExtensions(cfg.cfeSrc)) {
    const cur = extHash(dir);
    // После загрузки типовой расширения перегружаем всегда: она может сбросить их привязку.
    const load = flags.rebuildExt || configRan || cur !== readLock('ext-' + name);
    // Свойства из эталона могут отличаться от заданных — после restore применяем их и без загрузки.
    if (!load && !restored) {
      log(`ext[${name}]: skip`);
      continue;
    }
    if (load) {
      log(`ext[${name}]: db-load-xml -Extension + обновление БД`);
      await execSkill(resolveScript('db-load-xml/scripts/db-load-xml'),
        ['-InfoBasePath', cfg.standBase, ...standAuth(cfg), '-ConfigDir', dir, '-Extension', name, '-UpdateDB', '-V8Path', cfg.v8path]);
      writeLock('ext-' + name, extHash(dir));
      anyRan = true;
    }
    if (cfg.extensions?.[name] && !apacheStopped) {
      await webStop(cfg, log); // публикации поднимет стадия publish
      apacheStopped = true;
    }
    await applyExtProps(cfg, cfg.standBase, name, standAuth(cfg), log);
  }
  return anyRan;
}

// Публикация отвечает, если Apache жив и путь ему известен: 404 — Apache работает, но такой
// публикации в нём нет (иначе свежая публикация считалась бы готовой и пропускалась).
async function probeAlive(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(2500) });
    return r.status >= 200 && r.status < 500 && r.status !== 404;
  } catch {
    return false;
  }
}

// Apache стартует асинхронно после web-publish — ждём, пока публикация начнёт отвечать.
async function probeReady(url, timeoutMs, log, name) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (await probeAlive(url)) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`  ВНИМАНИЕ: ${name} не ответила за ${timeoutMs}мс`);
  return false;
}

// Реестр баз .v8-project.json (в .gitignore). null — и когда файла нет, и когда он битый;
// различает вызывающий через existsSync: нет файла → создаём, есть, но битый → не трогаем.
function readRegistry() {
  try { return JSON.parse(readFileSync(REGISTRY_PATH, 'utf8')); }
  catch { return null; }
}
// Корень алиаса — первое слово label в нижнем регистре: «Стенд примера» → «стенд».
// Алиас несёт и базу, и роль, иначе db-list спутает публикации разных баз с одной ролью.
const labelSlug = (label) => label.trim().split(/\s+/)[0].toLowerCase();

async function stagePublish(cfg, flags, log) {
  const fileExists = existsSync(REGISTRY_PATH);
  let reg = readRegistry();
  if (!reg && fileExists) {
    log('  ВНИМАНИЕ: .v8-project.json есть, но не читается — засев пропущен (файл не трогаем)');
  } else if (!reg) {
    reg = { v8path: cfg.v8bin, databases: [], default: cfg.publications[0]?.appName || '' };
  }
  const byId = new Map((reg?.databases || []).map((d) => [d.id, d]));
  const label = cfg.label || basename(cfg.standBase);
  const seeded = [];
  let published = false;

  for (const pub of cfg.publications) {
    const url = `http://localhost:${cfg.port}/${pub.appName}/`;
    const who = pub.user || 'без пользователя';

    // Пароль — только из реестра: он локальный и в .gitignore, а stand.config.json в репозитории.
    // Пользователь публикации всегда из конфига; реестр лишь добавляет пароль.
    const entry = byId.get(pub.appName);
    const creds = pub.user ? ['-UserName', pub.user] : [];
    if (pub.user && entry && entry.user !== pub.user) {
      log(`  ВНИМАНИЕ: реестр[${pub.appName}].user=«${entry.user}» ≠ publications=«${pub.user}» — пароль не подставлен, сверьте .v8-project.json`);
    } else if (pub.user && entry?.password) {
      creds.push('-Password', entry.password);
    }

    if (!flags.republish && (await probeAlive(url))) {
      log(`publish[${pub.appName}]: отвечает`);
    } else {
      log(`publish[${pub.appName}]: web-publish (${who})`);
      await execSkill(resolveScript('web-publish/scripts/web-publish'),
        ['-InfoBasePath', cfg.standBase, '-AppName', pub.appName, ...creds, '-Port', String(cfg.port),
          '-V8Path', cfg.v8bin, ...apacheArgs(cfg)]);
      published = true;
    }

    // Запись в реестр — только если её нет: локальная точка, где вписать пароль и откуда
    // db-list/web-test поднимут сессию под ролью. Существующую не трогаем — её правит человек.
    if (reg && !entry) {
      reg.databases.push({
        id: pub.appName,
        name: `${label} (${who})`,
        type: 'file',
        path: cfg.standBase,
        user: pub.user || '',
        password: '',
        aliases: [`${labelSlug(label)}-${(pub.user || pub.appName).toLowerCase()}`],
        webUrl: url.replace(/\/$/, ''),
        configSrc: cfg.cfSrc,
      });
      seeded.push(pub.appName);
    }
  }

  if (seeded.length) {
    writeFileSync(REGISTRY_PATH, JSON.stringify(reg, null, 2) + '\n', 'utf8');
    const verb = fileExists ? 'досеяны' : 'создан реестр, засеяны';
    log(`  реестр: ${verb} ${seeded.join(', ')} (пароли пустые — впишите при необходимости)`);
  }

  // Публикация перезапускает Apache — ждём, пока он поднимется. Все публикации в одном Apache,
  // поэтому достаточно готовности первой.
  if (published) {
    const first = cfg.publications[0];
    await probeReady(`http://localhost:${cfg.port}/${first.appName}/`, 60_000, log, first.appName);
  }
}

export async function runStages(cfg, flags, log) {
  const t0 = Date.now();
  log('stand prepare: flags=' + JSON.stringify(flags));
  const restored = await stageRestore(cfg, flags, log);
  const configRan = await stageConfig(cfg, flags, log);
  await stageExt(cfg, flags, configRan, restored, log);
  await stagePublish(cfg, flags, log);
  log('stand ready in ' + ((Date.now() - t0) / 1000).toFixed(1) + 's');
}

// Погашение: только web-stop. База, публикации и отметки целы — следующий up поднимет
// стенд без перезаливки эталона. Смысл — отпустить 1С-лицензии и порт.
export async function stopStand(cfg, log) {
  await webStop(cfg, log);
  log(`стенд погашен: база и публикации целы, для подъёма — node ${relative(process.cwd(), join(HERE, '_stand.mjs'))} up`);
}

// Статус: жив ли стенд с точки зрения потребителя — отвечают ли публикации.
export async function standStatus(cfg, log) {
  const dbFile = join(cfg.standBase, '1Cv8.1CD');
  log(`база:        ${existsSync(dbFile) ? 'есть' : 'НЕТ'} (${cfg.standBase})`);

  const cfLock = readLock('config');
  const parts = [];
  if (cfLock) parts.push(`cf@${cfLock.slice(0, 7)}`);
  for (const { name } of listExtensions(cfg.cfeSrc)) {
    const h = readLock('ext-' + name);
    if (h) parts.push(`ext[${name}]@${h.slice(0, 7)}`);
  }
  log(`baseline:    ${parts.length ? parts.join(', ') : 'отметок нет — следующий up загрузит config/ext полностью'}`);

  const alive = await Promise.all(
    cfg.publications.map((p) => probeAlive(`http://localhost:${cfg.port}/${p.appName}/`)),
  );
  const marks = cfg.publications.map((p, i) => `${p.appName} ${alive[i] ? '✓' : '✗'}`);
  log(`публикации:  ${marks.join(', ')}  (:${cfg.port})`);
  const up = alive.filter(Boolean).length;
  log(alive.every(Boolean) ? 'стенд поднят — все публикации отвечают'
    : up === 0 ? 'стенд погашен — ни одна публикация не отвечает'
      : `ЧАСТИЧНО: отвечают ${up} из ${alive.length} — Apache жив, но не все публикации на месте`);
}

// ── CLI ─────────────────────────────────────────────────────────────────────
// Блок под защитой: _stand.mjs импортируют _hooks.mjs, allure.mjs и build-etalon.mjs, и без неё
// их запуск исполнял бы CLI-ветку с чужим process.argv.
// realpath: путь модуля ESM уже разрешён (junction, symlink), а argv[1] — как набрали.
const isCli = (() => {
  try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; }
})();
if (isCli) {
  const cmd = process.argv[2] || 'status';
  const argv = process.argv.slice(3);
  const log = (m) => console.log(m);
  const cfg = loadStandConfig();
  try {
    if (cmd === 'up') await runStages(cfg, parseFlags(argv), log);
    else if (cmd === 'down') await stopStand(cfg, log);
    else if (cmd === 'status') await standStatus(cfg, log);
    else {
      console.log('Использование: node _stand.mjs [up [флаги]|down|status]\n' +
        '  up      поднять стенд (флаги: --reload-data, --rebuild-config, --rebuild-ext, --republish, --rebuild-stand)\n' +
        '  down    погасить Apache стенда (база цела, 1С-лицензии освобождаются)\n' +
        '  status  есть ли база, baseline, отвечают ли публикации');
      process.exit(1);
    }
  } catch (e) {
    console.error('❌ ' + e.message);
    process.exit(1);
  }
}
