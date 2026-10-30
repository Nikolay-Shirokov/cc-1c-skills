// allure.mjs v1.0 — прогон набора регресса с Allure-отчётом.
//
//   node tests/app/allure.mjs run [флаги раннера] [-- hookArgs]   прогон → результаты → HTML
//   node tests/app/allure.mjs report                              только HTML из готовых результатов
//   node tests/app/allure.mjs open                                открыть последний отчёт (локальный сервер)
//
// По умолчанию `run` гоняет весь набор со сбросом данных (--reload-data). Артефакты — рядом с набором,
// в .artifacts/ (в .gitignore): allure-results/ и allure-report/. Каталог переопределяет переменная
// REGRESS_ALLURE_DIR (для CI со своим местом под артефакты). Нужен Allure CLI (allure-commandline) в PATH.
// Срез: node tests/app/allure.mjs run --grep='утверждение' -- --reload-data

import { spawnSync } from 'child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, copyFileSync, rmSync, cpSync } from 'fs';
import { resolve, dirname, join, relative } from 'path';
import { fileURLToPath } from 'url';
import { REPO_ROOT, listExtensions, resolveSkillFile } from './_stand.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUITE = relative(REPO_ROOT, HERE).replace(/\\/g, '/') + '/';
const SELF = relative(process.cwd(), join(HERE, 'allure.mjs'));
const RUN = resolveSkillFile('web-test/scripts/run.mjs');
// Артефакты — рядом с набором: каталог заведомо свой (очистка не снесёт чужое) и переезжает вместе
// с набором. В корне проекта имя allure-results — умолчание Allure CLI, его заняли бы и другие наборы.
const ARTIFACTS = process.env.REGRESS_ALLURE_DIR ? resolve(process.env.REGRESS_ALLURE_DIR) : resolve(HERE, '.artifacts');
const RESULTS = resolve(ARTIFACTS, 'allure-results');
const REPORT = resolve(ARTIFACTS, 'allure-report');
// Срез (--grep/--tags) пишет в отдельные каталоги: одноразовый отчёт, а не точка тренда.
const RESULTS_SUBSET = resolve(ARTIFACTS, 'allure-results-subset');
const REPORT_SUBSET = resolve(ARTIFACTS, 'allure-report-subset');

function node(args) {
  return spawnSync(process.execPath, args, { stdio: 'inherit', cwd: REPO_ROOT }).status ?? 1;
}
// allure на Windows — скрипт-обёртка (.cmd), его запускает только оболочка; оболочка же склеивает
// аргументы как есть — пути в кавычки, иначе каталог с пробелом развалится на части.
const quote = (a) => (/[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a);
function allure(args) {
  const r = spawnSync('allure', args.map(quote), { stdio: 'inherit', cwd: REPO_ROOT, shell: true });
  return r.status ?? 1;
}
// Через оболочку отсутствие программы не даёт ошибки запуска — проверяем заранее.
function requireAllure() {
  const r = spawnSync('allure', ['--version'], { stdio: 'ignore', cwd: REPO_ROOT, shell: true });
  if (r.status !== 0) { console.error('❌ Allure CLI не найден в PATH. Установите allure-commandline.'); process.exit(2); }
}

// Раннер пишет каждый результат под случайным UUID и не чистит каталог: без очистки в отчёт
// подмешиваются тесты прошлых прогонов.
function clearResults(dir) {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
}

// Тренды живут в прошлом отчёте: переносим историю в свежие результаты до `generate --clean`.
// Только для полных прогонов — срез исказил бы динамику.
function carryHistory() {
  const prev = resolve(REPORT, 'history');
  if (existsSync(prev)) {
    try { cpSync(prev, resolve(RESULTS, 'history'), { recursive: true }); } catch { /* истории нет */ }
  }
}

// «Синоним vВерсия» из Configuration.xml выгрузки — версия читается из исходников, не хардкодится.
function xmlVersionLabel(cfgFile) {
  try {
    const xml = readFileSync(cfgFile, 'utf8');
    const version = xml.match(/<Version>([^<]*)<\/Version>/)?.[1] || '';
    const name = xml.match(/<Synonym>[\s\S]*?<v8:content>([^<]*)<\/v8:content>/)?.[1]
      || xml.match(/<Name>([^<]*)<\/Name>/)?.[1] || '';
    return name ? `${name}${version ? ' v' + version : ''}` : null;
  } catch { return null; }
}
function configLabel(cfg) {
  const parts = [];
  const cf = resolve(REPO_ROOT, cfg.cfSrc || 'src/cf', 'Configuration.xml');
  const cfLabel = existsSync(cf) ? xmlVersionLabel(cf) : null;
  if (cfLabel) parts.push(cfLabel);
  try {
    for (const { dir } of listExtensions(resolve(REPO_ROOT, cfg.cfeSrc || 'src/cfe'))) {
      const l = xmlVersionLabel(resolve(dir, 'Configuration.xml'));
      if (l) parts.push('расширение ' + l);
    }
  } catch { /* нет расширений — метку не роняем */ }
  return parts.length ? parts.join(' + ') : 'не определена (нет исходников)';
}

// Перед генерацией: статика _allure/ (categories.json) и environment.properties из stand.config.json.
function prepareResults(dir) {
  mkdirSync(dir, { recursive: true });
  const extras = resolve(HERE, '_allure');
  if (existsSync(extras)) {
    for (const f of readdirSync(extras)) {
      try { copyFileSync(join(extras, f), resolve(dir, f)); } catch {}
    }
  }
  try {
    const cfg = JSON.parse(readFileSync(resolve(HERE, 'stand.config.json'), 'utf8'));
    const lines = [
      `Платформа=${(cfg.v8path || '').match(/8\.\d+\.[\d.]+/)?.[0] || '1С:Предприятие 8'}`,
      `Конфигурация=${configLabel(cfg)}`,
      `Эталон=${cfg.dtPath}`,
      // Прямые слэши: в Java-properties «\» — экранирование, путь C:\… превратился бы в «C:…»
      `Стенд=file ${(cfg.standBase || '').replace(/\\/g, '/')}; публикации ${(cfg.publications || []).map((p) => p.appName).join(', ')}`,
    ];
    writeFileSync(resolve(dir, 'environment.properties'), lines.join('\n') + '\n', 'utf8');
  } catch (e) { console.error('environment.properties не записан:', e.message); }
}

const cmd = process.argv[2] || 'run';
const rest = process.argv.slice(3);

if (['run', 'report', 'open'].includes(cmd)) requireAllure(); // до прогона, а не после

if (cmd === 'run') {
  const dashIdx = rest.indexOf('--');
  const runnerArgs = dashIdx === -1 ? rest : rest.slice(0, dashIdx);
  const hookArgs = dashIdx === -1 ? ['--reload-data'] : rest.slice(dashIdx + 1);
  const full = !runnerArgs.some((a) => /^--(grep|tags)=/.test(a));
  const outResults = full ? RESULTS : RESULTS_SUBSET;
  const outReport = full ? REPORT : REPORT_SUBSET;
  // Потолок на весь прогон — страховка от зависшего стенда; по нему раннер пишет отчёт, освобождает
  // сеансы 1С и выходит с кодом 2. Подберите под длительность своего набора с запасом.
  const GLOBAL_TIMEOUT = 3600000;
  const globalTimeoutArgs = runnerArgs.some((a) => a.startsWith('--global-timeout=')) ? [] : [`--global-timeout=${GLOBAL_TIMEOUT}`];
  clearResults(outResults);
  const status = node([RUN, 'test', SUITE, '--format=allure', `--report-dir=${outResults}`, ...globalTimeoutArgs, ...runnerArgs, '--', ...hookArgs]);
  prepareResults(outResults);
  if (full) carryHistory();
  allure(['generate', outResults, '-o', outReport, '--clean']);
  console.log(full
    ? `\n📊 Отчёт: ${outReport}\n   Открыть: node ${SELF} open`
    : `\nℹ️  Прогон среза — основной отчёт и тренд не тронуты.\n📊 Отчёт среза: ${outReport}\n   Открыть: allure open ${outReport}`);
  // Коды раннера: 0 — всё зелено; 1 — есть красные; 2 — упёрлись в --global-timeout (смотреть стенд,
  // не тесты); 3 — зависло сворачивание прогона.
  if (status === 2) console.error(`\n⏱  Прогон упёрся в --global-timeout (${GLOBAL_TIMEOUT / 60000} мин): отчёт частичный — смотреть стенд/зависание, не тесты.`);
  else if (status === 3) console.error('\n💀 Зависло сворачивание прогона — проверьте живые сеансы 1С и браузеры.');
  process.exit(status);
} else if (cmd === 'report') {
  prepareResults(RESULTS);
  allure(['generate', RESULTS, '-o', REPORT, '--clean']);
  console.log(`📊 Отчёт: ${REPORT}  (открыть: node ${SELF} open)`);
} else if (cmd === 'open') {
  allure(['open', REPORT]);
} else {
  console.log(`Использование: node ${SELF} [run|report|open]`);
  process.exit(1);
}
