#!/usr/bin/env node
// verify-snapshots v0.2 — Platform verification of skill test snapshots
// Reruns skill scripts from test-case DSL, then loads into 1C platform.
// Usage: node tests/skills/verify-snapshots.mjs [--skill meta-compile] [--case catalog-basic] [--runtime powershell|python] [--keep] [--verbose]
// Supports: meta-compile, form-compile, form-add, form-edit, skd-compile, skd-edit,
//           role-compile, subsystem-compile, subsystem-edit, mxl-compile, template-add,
//           help-add, cf-init, cf-edit, epf-init, meta-edit, interface-edit,
//           cfe-init, cfe-borrow, cfe-patch-method
// Работает и с кейсами навыков, которые сами ничего не пишут (info/validate), если у кейса
// есть preRun: проверяется, что платформа принимает собранную им фикстуру.
// Для кейсов на `setup: external:` проверка вырождается — 1С грузит собственную выгрузку
// типовой конфигурации (~3 мин на кейс, ноль информации). Такие гонять через --case.

import { execFileSync } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, unlinkSync, rmdirSync, readFileSync, writeFileSync,
         readdirSync, statSync, cpSync, copyFileSync, chmodSync } from 'fs';
import { join, resolve, dirname, basename } from 'path';
import { tmpdir } from 'os';

// ─── Paths ──────────────────────────────────────────────────────────────────

const ROOT      = resolve(dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Z]:)/i, '$1'));
const REPO_ROOT = resolve(ROOT, '../..');
const SKILLS    = resolve(REPO_ROOT, '.claude/skills');
const CASES     = resolve(ROOT, 'cases');
const REPORT_DIR = resolve(REPO_ROOT, 'debug/snapshot-verify');

// ─── FS-хелперы ─────────────────────────────────────────────────────────────

// Node 24.x на Windows fs.rmSync/fs.cpSync ломаются, когда путь в АРГУМЕНТЕ содержит
// не-ASCII символы — например кириллическое имя пользователя в %TEMP%
// (nodejs/node#61067, проверено на v24.12.0). Проявления зависят от комбинации:
// rmSync молча ничего не удаляет; cpSync с не-ASCII приёмником молча ничего не
// копирует (а поверх существующего файла кидает «The operation completed
// successfully»); cpSync с не-ASCII источником НАТИВНО валит процесс (0xC0000409).
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

function rmrfSync(dir) {
  if (!nonAsciiPathUnsafe(dir)) rmSync(dir, { recursive: true, force: true });
  if (!existsSync(dir)) return;
  rmTreeWalkSync(dir);
  if (existsSync(dir)) throw new Error(`Failed to remove directory: ${dir}`);
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
  console.log(`verify-snapshots — Platform verification of skill test snapshots

Reruns skill scripts from test-case DSL, then loads results into 1C platform.

Usage:
  node tests/skills/verify-snapshots.mjs [options]

Options:
  --skill <name>           Run only cases for the given skill (e.g. form-compile)
  --case <name>            Run only the case with this name
  --runtime <ps|python>    Which script port to run (default: powershell)
  --v8path <path>          1C executable/dir override (e.g. .../ibcmd to run via ibcmd).
                           Precedence: --v8path > .v8-project.json > auto-detect.
  --keep                   Keep generated work directories on disk after run
  -v, --verbose            Verbose output
  -h, --help, /?           Show this help and exit
`);
}

function parseArgs(argv) {
  const args = { skill: null, caseName: null, runtime: 'powershell', v8path: null, keep: false, verbose: false, help: false };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '-h' || a === '--help' || a === '/?' || a === '/help' || a === '?') { args.help = true; continue; }
    if (a === '--skill' && rest[i + 1]) { args.skill = rest[++i]; continue; }
    if (a === '--case' && rest[i + 1]) { args.caseName = rest[++i]; continue; }
    if (a === '--runtime' && rest[i + 1]) { args.runtime = rest[++i]; continue; }
    if (a === '--v8path' && rest[i + 1]) { args.v8path = rest[++i]; continue; }
    if (a === '--keep') { args.keep = true; continue; }
    if (a === '--verbose' || a === '-v') { args.verbose = true; continue; }
  }
  return args;
}

// ─── Platform context ───────────────────────────────────────────────────────

// Имя исполняемого файла платформы зависит от ОС: Windows — 1cv8.exe, *nix (macOS/Linux) — 1cv8.
const V8_EXE = process.platform === 'win32' ? '1cv8.exe' : '1cv8';

// Числовой ключ версии из пути к 1cv8 (лексикографическая сортировка врёт: "8.3.9" > "8.3.27").
// Версия-папка: <ver>/1cv8 (*nix) или <ver>/bin/1cv8.exe (win) — отбрасываем хвост bin, если он есть.
function versionKey(exePath) {
  let dir = dirname(exePath);
  if (basename(dir).toLowerCase() === 'bin') dir = dirname(dir);
  return (basename(dir).match(/\d+/g) || []).map(Number);
}

function compareVersionKeys(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] || 0) - (b[i] || 0);
    if (d) return d;
  }
  return 0;
}

// Резолвит исполняемый файл платформы внутри каталога v8bin.
// На *nix 1cv8 лежит прямо в <ver>/ (наш /opt/1cv8/<ver>/1cv8), на Windows — в <ver>/bin/.
function resolveV8Exe(v8bin) {
  if (!v8bin) return null;
  const direct = join(v8bin, V8_EXE);
  if (existsSync(direct)) return direct;
  const inBin = join(v8bin, 'bin', V8_EXE);
  if (existsSync(inBin)) return inBin;
  return null;
}

// Auto-detect платформы, когда v8path не задан — зеркалит resolve_v8path из py/ps1-портов навыков db-*:
// Windows — Program Files[ (x86)]\1cv8\*\bin\1cv8.exe; *nix — /opt/1cv8/*/1cv8; берём максимальную версию.
function autodetectV8Exe() {
  const candidates = [];
  const scan = (base, sub) => {
    if (!existsSync(base)) return;
    for (const d of readdirSync(base)) {
      const exe = sub ? join(base, d, sub, V8_EXE) : join(base, d, V8_EXE);
      if (existsSync(exe)) candidates.push(exe);
    }
  };
  if (process.platform === 'win32') {
    scan('C:\\Program Files\\1cv8', 'bin');
    scan('C:\\Program Files (x86)\\1cv8', 'bin');
  } else {
    scan('/opt/1cv8', null);
  }
  if (!candidates.length) return null;
  return candidates.sort((a, b) => compareVersionKeys(versionKey(a), versionKey(b))).pop();
}

// Приоритет резолва платформы зеркалит навыки db-* (resolve_v8path):
// явный параметр (--v8path) → .v8-project.json → авто-поиск 1cv8.
function loadV8Context(override) {
  let v8bin = override || null;
  if (!v8bin) {
    const projectFile = join(REPO_ROOT, '.v8-project.json');
    if (existsSync(projectFile)) {
      try { v8bin = JSON.parse(readFileSync(projectFile, 'utf8')).v8path || null; } catch { /* ignore */ }
    }
  }
  if (v8bin) {
    // v8path указывает прямо на исполняемый файл (1cv8/ibcmd) — используем как есть, не подменяя авто-детектом.
    // Так verify умеет гонять цикл через ibcmd (db-* навыки сами выбирают движок по basename).
    if (existsSync(v8bin) && statSync(v8bin).isFile()) return { v8path: v8bin, v8exe: v8bin };
    const v8exe = resolveV8Exe(v8bin);
    // Явно заданный, но неразрешимый путь — это ошибка конфигурации, НЕ повод молча брать другую платформу.
    return v8exe ? { v8path: v8bin, v8exe } : null;
  }
  // v8path не задан — авто-детект (Program Files на win, /opt/1cv8 на маке).
  const v8exe = autodetectV8Exe();
  return v8exe ? { v8path: v8exe, v8exe } : null;
}

// ─── Script execution ───────────────────────────────────────────────────────

function resolveScript(relPath, runtime) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const full = join(SKILLS, relPath + ext);
  if (!existsSync(full)) throw new Error(`Script not found: ${full}`);
  return full;
}

function execSkill(runtime, scriptRelPath, args, timeout = 60_000, cwd = REPO_ROOT) {
  const scriptPath = resolveScript(scriptRelPath, runtime);
  if (runtime === 'python') {
    return execFileSync(process.env.PYTHON || 'python', [scriptPath, ...args], {
      encoding: 'utf8', timeout, stdio: ['pipe', 'pipe', 'pipe'], cwd,
    });
  }
  return execFileSync('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', scriptPath, ...args
  ], { encoding: 'utf8', timeout, stdio: ['pipe', 'pipe', 'pipe'], cwd });
}

// ─── Dependency resolution ──────────────────────────────────────────────────

const ID = '[\\w\\u0400-\\u04FF]+';

function extractTypeRefs(input) {
  const refs = new Map();
  const json = JSON.stringify(input);

  const refPattern = new RegExp(`(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|ExchangePlan)Ref\\.(${ID})`, 'g');
  let m;
  while ((m = refPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  const directPattern = new RegExp(`(ChartOfAccounts|ChartOfCalculationTypes|ChartOfCharacteristicTypes)\\.(${ID})`, 'g');
  while ((m = directPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  // Прямые ссылки Тип.Имя: картинки, макеты, хранилища настроек, определяемые типы
  const directPattern2 = new RegExp(`(CommonPicture|CommonTemplate|SettingsStorage|DefinedType)\\.(${ID})`, 'g');
  while ((m = directPattern2.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  // Characteristic.X (тип-характеристика в составе типа значения) → ChartOfCharacteristicTypes.X
  const charPattern = new RegExp(`Characteristic\\.(${ID})`, 'g');
  while ((m = charPattern.exec(json)) !== null) {
    refs.set(`ChartOfCharacteristicTypes.${m[1]}`, { type: 'ChartOfCharacteristicTypes', name: m[1] });
  }

  const objPattern = new RegExp(`(Document|Catalog|BusinessProcess|Task|ExchangePlan)Object\\.(${ID})`, 'g');
  while ((m = objPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  const modPattern = new RegExp(`CommonModule\\.(${ID})\\.${ID}`, 'g');
  while ((m = modPattern.exec(json)) !== null) {
    refs.set(`CommonModule.${m[1]}`, { type: 'CommonModule', name: m[1] });
  }

  if (input && input.type === 'ScheduledJob' && input.methodName) {
    const parts = input.methodName.split('.');
    if (parts.length >= 2) {
      refs.set(`CommonModule.${parts[0]}`, { type: 'CommonModule', name: parts[0] });
    }
  }

  return refs;
}

// ─── Structural dependencies ────────────────────────────────────────────────

function getStructuralDeps(input) {
  const deps = [];
  const inputs = Array.isArray(input) ? input : [input];
  if (!inputs[0] || !inputs[0].type) return deps;

  for (const inp of inputs) {
    const regTypePrefix = {
      AccumulationRegister: 'AccumulationRegister',
      AccountingRegister: 'AccountingRegister',
      CalculationRegister: 'CalculationRegister',
    }[inp.type];

    // InformationRegister needs a registrar only when subordinated to a recorder
    // (writeMode: 'Subordinate' / RecorderSubordinate).
    const isSubordinatedInfoReg = inp.type === 'InformationRegister' &&
      (inp.writeMode === 'Subordinate' || inp.writeMode === 'RecorderSubordinate' ||
       inp.recorderSubordinate === true);
    const effectivePrefix = regTypePrefix || (isSubordinatedInfoReg ? 'InformationRegister' : null);

    if (effectivePrefix) {
      deps.push({
        type: 'Document', name: 'ТестовыйДокумент',
        dsl: { type: 'Document', name: 'ТестовыйДокумент' },
        postEdit: [{ op: 'add-registerRecord', val: `${effectivePrefix}.${inp.name}` }],
      });
    }

    switch (inp.type) {
      case 'BusinessProcess': {
        const taskRef = inp.task;
        if (taskRef) {
          const taskName = taskRef.split('.').pop();
          deps.push({ type: 'Task', name: taskName, dsl: { type: 'Task', name: taskName, descriptionLength: 100 } });
        }
        break;
      }
      case 'Document':
        // RegisterRecords (движения) ссылаются на регистры по MDObjectRef — 1С требует их существования. Стабим.
        if (inp.registerRecords) {
          const regSyn = { 'РегистрСведений': 'InformationRegister', 'РегистрНакопления': 'AccumulationRegister', 'РегистрБухгалтерии': 'AccountingRegister', 'РегистрРасчета': 'CalculationRegister' };
          for (const rr of inp.registerRecords) {
            const ref = String(rr).split(':')[0].trim();
            const dot = ref.indexOf('.');
            if (dot < 0) continue;
            const t = regSyn[ref.substring(0, dot)] || ref.substring(0, dot);
            const n = ref.substring(dot + 1);
            const dsl = makeStubDSL(t, n);
            if (dsl) deps.push({ type: t, name: n, dsl });
          }
        }
        break;
      case 'ChartOfCharacteristicTypes':
        // Доп. значения характеристик (CharacteristicExtValues) — ссылка на справочник, ПОДЧИНЁННЫЙ этому ПВХ
        // (Owner = ChartOfCharacteristicTypes.X). 1С требует такой справочник для целостности; плоский стаб не годится
        // (тип предопределённых должен входить в тип значения ПВХ, а справочник — быть подчинён). Стабим с Owner.
        if (inp.characteristicExtValues) {
          const ref = String(inp.characteristicExtValues);
          const dot = ref.indexOf('.');
          const cn = dot >= 0 ? ref.substring(dot + 1) : ref;
          deps.push({
            type: 'Catalog', name: cn,
            dsl: { type: 'Catalog', name: cn, owners: [`ChartOfCharacteristicTypes.${inp.name}`] },
          });
        }
        break;
      case 'DocumentJournal':
        if (inp.registeredDocuments) {
          for (const docRef of inp.registeredDocuments) {
            const docName = docRef.split('.').pop();
            deps.push({ type: 'Document', name: docName, dsl: { type: 'Document', name: docName } });
          }
        }
        break;
      case 'ExchangePlan':
        // Состав плана обмена (Content.xml) ссылается на объекты по MDObjectRef "Type.Name" —
        // 1С требует их существования при загрузке. Стабим каждый.
        if (inp.content) {
          const entries = Array.isArray(inp.content) ? inp.content : [inp.content];
          for (const e of entries) {
            let ref = typeof e === 'string' ? e : (e.metadata || e['Метаданные'] || e['объект'] || '');
            ref = String(ref).split(':')[0].trim();   // отбросить ": autoRecord"/флаг
            const dot = ref.indexOf('.');
            if (dot < 0) continue;
            const t = ref.substring(0, dot);
            const n = ref.substring(dot + 1);
            const dsl = makeStubDSL(t, n);
            if (dsl) deps.push({ type: t, name: n, dsl });
          }
        }
        break;
      case 'EventSubscription': {
        // Обработчик подписки ссылается на экспортный метод общего модуля — 1С требует его существования.
        // Стабим CommonModule и дописываем экспортную процедуру в его модуль (postWrite).
        let h = String(inp.handler || '').replace(/^CommonModule\./, '');
        const hdot = h.indexOf('.');
        if (hdot > 0) {
          const modName = h.substring(0, hdot), methodName = h.substring(hdot + 1);
          deps.push({ type: 'CommonModule', name: modName,
            dsl: { type: 'CommonModule', name: modName, server: true },
            postWrite: [{ relPath: `CommonModules/${modName}/Ext/Module.bsl`,
              content: `Процедура ${methodName}(Источник, Отказ) Экспорт\nКонецПроцедуры\n` }] });
        }
        break;
      }
      case 'Sequence':
        // Документы последовательности (documents) + реквизиты из documentMap — 1С требует существования
        // самого Document.X И реквизита, на который ссылается измерение. Стабим документ с нужными реквизитами
        // (тип реквизита берём из соответствующего измерения последовательности).
        if (inp.documents) {
          const norm = (s) => String(s).replace(/^Документ\./, 'Document.').replace(/\.Реквизит\./, '.Attribute.');
          const docAttrs = {};   // имя документа -> Set("Реквизит: Тип")
          for (const dim of (inp.dimensions || [])) {
            const dtype = dim.type || 'CatalogRef.Организации';
            for (const mp of (dim.documentMap || [])) {
              const m = norm(mp).match(/^Document\.([^.]+)\.Attribute\.(.+)$/);
              if (m) (docAttrs[m[1]] = docAttrs[m[1]] || new Set()).add(`${m[2]}: ${dtype}`);
            }
          }
          for (const dref of inp.documents) {
            const dn = String(dref).split('.').pop();
            const attrs = [...(docAttrs[dn] || [])];
            deps.push({ type: 'Document', name: dn, dsl: { type: 'Document', name: dn, ...(attrs.length ? { attributes: attrs } : {}) } });
          }
        }
        break;
    }
  }
  return deps;
}

// ─── Stub creation ──────────────────────────────────────────────────────────

function makeStubDSL(type, name) {
  switch (type) {
    case 'Catalog': return { type: 'Catalog', name };
    case 'Document': return { type: 'Document', name };
    case 'Enum': return { type: 'Enum', name, values: ['Значение1'] };
    case 'Constant': return { type: 'Constant', name, valueType: 'Boolean' };
    case 'InformationRegister': return { type: 'InformationRegister', name, dimensions: ['Ключ: String(10)'] };
    case 'AccumulationRegister': return { type: 'AccumulationRegister', name, dimensions: ['Ключ: String(10)'], resources: ['Значение: Number(15,2)'] };
    case 'ChartOfAccounts': return { type: 'ChartOfAccounts', name, codeLength: 4, descriptionLength: 100, maxExtDimensionCount: 0 };
    case 'ChartOfCharacteristicTypes': return { type: 'ChartOfCharacteristicTypes', name, codeLength: 9, descriptionLength: 100 };
    case 'ChartOfCalculationTypes': return { type: 'ChartOfCalculationTypes', name, codeLength: 9, descriptionLength: 100 };
    case 'CommonModule': return { type: 'CommonModule', name, server: true };
    case 'BusinessProcess': return { type: 'BusinessProcess', name };
    case 'Task': return { type: 'Task', name };
    case 'ExchangePlan': return { type: 'ExchangePlan', name, codeLength: 9, descriptionLength: 100 };
    case 'Role': return { type: 'Role', name: name };
    case 'DefinedType': return { type: 'DefinedType', name, valueType: 'Number(15,2)' };
    case 'CommonPicture': return { type: 'CommonPicture', name };
    case 'CommonTemplate': return { type: 'CommonTemplate', name };
    case 'SettingsStorage': return { type: 'SettingsStorage', name };
    case 'Subsystem': return null; // Subsystems need special handling
    default: return null;
  }
}

const TYPE_TO_PREFIX = {
  Catalog: 'Catalog', Document: 'Document', Enum: 'Enum', Constant: 'Constant',
  CommonModule: 'CommonModule', DataProcessor: 'DataProcessor', Report: 'Report',
  InformationRegister: 'InformationRegister', AccumulationRegister: 'AccumulationRegister',
  AccountingRegister: 'AccountingRegister', CalculationRegister: 'CalculationRegister',
  ChartOfAccounts: 'ChartOfAccounts', ChartOfCharacteristicTypes: 'ChartOfCharacteristicTypes',
  ChartOfCalculationTypes: 'ChartOfCalculationTypes', BusinessProcess: 'BusinessProcess',
  Task: 'Task', ExchangePlan: 'ExchangePlan', DocumentJournal: 'DocumentJournal',
  EventSubscription: 'EventSubscription', ScheduledJob: 'ScheduledJob',
  DefinedType: 'DefinedType', HTTPService: 'HTTPService', WebService: 'WebService',
  Subsystem: 'Subsystem', Role: 'Role',
  CommonPicture: 'CommonPicture', CommonTemplate: 'CommonTemplate', SettingsStorage: 'SettingsStorage',
};

const TYPE_TO_DIR = {
  Catalog: 'Catalogs', Document: 'Documents', Enum: 'Enums', Constant: 'Constants',
  CommonModule: 'CommonModules', DataProcessor: 'DataProcessors', Report: 'Reports',
  InformationRegister: 'InformationRegisters', AccumulationRegister: 'AccumulationRegisters',
  AccountingRegister: 'AccountingRegisters', CalculationRegister: 'CalculationRegisters',
  ChartOfAccounts: 'ChartsOfAccounts', ChartOfCharacteristicTypes: 'ChartsOfCharacteristicTypes',
  ChartOfCalculationTypes: 'ChartsOfCalculationTypes', BusinessProcess: 'BusinessProcesses',
  Task: 'Tasks', ExchangePlan: 'ExchangePlans', DocumentJournal: 'DocumentJournals',
  EventSubscription: 'EventSubscriptions', ScheduledJob: 'ScheduledJobs',
  DefinedType: 'DefinedTypes', HTTPService: 'HTTPServices', WebService: 'WebServices',
  Subsystem: 'Subsystems', Role: 'Roles',
  CommonPicture: 'CommonPictures', CommonTemplate: 'CommonTemplates', SettingsStorage: 'SettingsStorages',
};

// ─── Кросс-объектные ссылки на поля → богатые стабы ─────────────────────────
// Разбор MDObjectRef-пути "Тип.Имя[.ТабличнаяЧасть.ТЧ].Реквизит|Измерение|Ресурс.Поле" (+рус.синонимы)
// в стаб объекта с нужными полями. Плюс сбор предопределённых значений перечислений / элементов справочников
// из fillValue/choiceParameters. Обобщение ветки Sequence (documentMap) на все типы, ссылающиеся на чужие поля.

const TYPE_SYN = {
  'Документ': 'Document', 'Справочник': 'Catalog', 'РегистрНакопления': 'AccumulationRegister',
  'РегистрСведений': 'InformationRegister', 'РегистрБухгалтерии': 'AccountingRegister',
  'РегистрРасчета': 'CalculationRegister', 'Константа': 'Constant',
  'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes', 'ПланСчетов': 'ChartOfAccounts',
  'ПланВидовРасчета': 'ChartOfCalculationTypes', 'ПланОбмена': 'ExchangePlan',
  'БизнесПроцесс': 'BusinessProcess', 'Задача': 'Task',
};
const FIELD_SYN = { 'Реквизит': 'Attribute', 'Измерение': 'Dimension', 'Ресурс': 'Resource', 'ТабличнаяЧасть': 'TabularSection' };
const asArray = (v) => (v == null ? [] : (Array.isArray(v) ? v : [v]));

function parseFieldRef(rawPath) {
  const parts = String(rawPath).split(':')[0].trim().split('.');
  if (parts.length < 2) return null;
  const type = TYPE_SYN[parts[0]] || parts[0];
  const name = parts[1];
  let ts = null, fieldKind = null, fieldName = null, i = 2;
  while (i < parts.length) {
    const seg = FIELD_SYN[parts[i]] || parts[i];
    if (seg === 'TabularSection' && i + 1 < parts.length) { ts = parts[i + 1]; i += 2; continue; }
    if ((seg === 'Attribute' || seg === 'Dimension' || seg === 'Resource') && i + 1 < parts.length) {
      fieldKind = seg; fieldName = parts[i + 1]; i += 2; continue;
    }
    i++;
  }
  return { type, name, ts, fieldKind, fieldName };
}

function getFieldStubs(input) {
  const inputs = Array.isArray(input) ? input : [input];
  const mainKeys = new Set(inputs.filter(i => i && i.type).map(i => `${i.type}.${i.name}`));
  const acc = new Map();   // key -> { type, name, attrs, dims, res, tsAttrs, enumVals, predef }
  const ID2 = '[\\wА-Яа-яЁё]+';

  const ent = (type, name) => {
    const key = `${type}.${name}`;
    if (!TYPE_TO_DIR[type] || mainKeys.has(key)) return null;   // неизвестный тип или сам проверяемый объект — не трогаем
    let e = acc.get(key);
    if (!e) { e = { type, name, attrs: new Set(), dims: new Set(), res: new Set(), tsAttrs: new Map(), enumVals: new Set(), predef: new Set() }; acc.set(key, e); }
    return e;
  };
  const addRef = (raw, attrType) => {
    if (!raw) return;
    const p = parseFieldRef(raw); if (!p) return;
    const e = ent(p.type, p.name); if (!e) return;
    if (p.fieldKind) {
      const spec = `${p.fieldName}: ${attrType || 'String(10)'}`;
      if (p.ts) { if (!e.tsAttrs.has(p.ts)) e.tsAttrs.set(p.ts, new Set()); e.tsAttrs.get(p.ts).add(spec); }
      else if (p.fieldKind === 'Attribute') e.attrs.add(spec);
      else if (p.fieldKind === 'Dimension') e.dims.add(spec);
      else if (p.fieldKind === 'Resource') e.res.add(spec);
    }
  };
  const addPredef = (val, ctxType) => {
    if (typeof val !== 'string' || !val) return;
    if (val === 'EmptyRef' || val.includes('ПустаяСсылка')) return;
    let m = val.match(new RegExp(`(?:Enum|Перечисление)\\.(${ID2})\\.(?:EnumValue|ЗначениеПеречисления)\\.(${ID2})`));
    if (m) { const e = ent('Enum', m[1]); if (e) e.enumVals.add(m[2]); return; }
    m = val.match(new RegExp(`^(?:Catalog|Справочник)\\.(${ID2})\\.(${ID2})$`));
    if (m && m[2] !== 'EmptyRef' && m[2] !== 'Predefined') { const e = ent('Catalog', m[1]); if (e) e.predef.add(m[2]); return; }
    if (ctxType && !val.includes('.')) {   // короткая запись — тип несёт реквизит
      let em = ctxType.match(/^EnumRef\.(.+)$/); if (em) { const e = ent('Enum', em[1]); if (e) e.enumVals.add(val); return; }
      let cm = ctxType.match(/^CatalogRef\.(.+)$/); if (cm) { const e = ent('Catalog', cm[1]); if (e) e.predef.add(val); return; }
    }
  };
  const scanAttrs = (attrs) => {
    for (const a of asArray(attrs)) {
      if (!a || typeof a !== 'object') continue;
      if (typeof a.fillValue === 'string') addPredef(a.fillValue, a.type);
      for (const cp of asArray(a.choiceParameters)) {
        if (cp && typeof cp === 'object') for (const v of asArray(cp.value)) addPredef(v, cp.type);
      }
    }
  };

  for (const inp of inputs) {
    if (!inp || !inp.type) continue;
    switch (inp.type) {
      case 'FilterCriterion': for (const c of asArray(inp.content)) addRef(c, inp.valueType); break;
      case 'FunctionalOption': addRef(inp.location); for (const c of asArray(inp.content)) addRef(c); break;
      case 'FunctionalOptionsParameter': for (const u of asArray(inp.use)) addRef(u); break;
      case 'CommonAttribute':
        for (const c of asArray(inp.content)) addRef(typeof c === 'string' ? c : (c.metadata || c['Метаданные'] || c['объект'] || ''));
        break;
    }
    for (const b of asArray(inp.basedOn)) addRef(b);
    for (const o of asArray(inp.owners)) addRef(o);
    scanAttrs(inp.attributes);
    if (inp.tabularSections && typeof inp.tabularSections === 'object' && !Array.isArray(inp.tabularSections)) {
      for (const ts of Object.values(inp.tabularSections)) scanAttrs(Array.isArray(ts) ? ts : (ts && (ts.attributes || ts.columns)));
    }
    if (inp.standardAttributes && typeof inp.standardAttributes === 'object') {
      for (const sa of Object.values(inp.standardAttributes)) if (sa && typeof sa === 'object') scanAttrs([{ ...sa, type: '' }]);
    }
    if (inp.type === 'DocumentJournal') {
      for (const col of asArray(inp.columns)) if (col && typeof col === 'object') for (const r of asArray(col.references)) addRef(r);
    }
  }

  const deps = [];
  for (const e of acc.values()) {
    const base = makeStubDSL(e.type, e.name) || { type: e.type, name: e.name };
    if (e.attrs.size) base.attributes = [...(base.attributes || []), ...e.attrs];
    if (e.dims.size) base.dimensions = [...(base.dimensions || []), ...e.dims];
    if (e.res.size) base.resources = [...(base.resources || []), ...e.res];
    if (e.tsAttrs.size) { base.tabularSections = base.tabularSections || {}; for (const [ts, set] of e.tsAttrs) base.tabularSections[ts] = [...set]; }
    if (e.enumVals.size) base.values = [...e.enumVals];
    if (e.predef.size) base.predefined = [...e.predef];
    deps.push({ type: e.type, name: e.name, dsl: base });
    // Регистру накопления/бухгалтерии/расчёта нужен документ-регистратор, иначе 1С отвергает
    // конфигурацию («ни один документ не является регистратором для регистра»).
    if (e.type === 'AccumulationRegister' || e.type === 'AccountingRegister' || e.type === 'CalculationRegister') {
      const rn = `Регистратор${e.name}`;
      deps.push({ type: 'Document', name: rn, dsl: { type: 'Document', name: rn },
        postEdit: [{ op: 'add-registerRecord', val: `${e.type}.${e.name}` }] });
    }
  }
  return deps;
}

// ─── Auto-detect objects in config dir for cf-edit ──────────────────────────

function scanConfigObjects(configDir) {
  const objects = [];
  // DIR_TO_TYPE: reverse mapping of TYPE_TO_DIR
  const DIR_TO_TYPE = {};
  for (const [type, dir] of Object.entries(TYPE_TO_DIR)) DIR_TO_TYPE[dir] = type;

  for (const dir of readdirSync(configDir)) {
    const type = DIR_TO_TYPE[dir];
    if (!type) continue;
    const fullDir = join(configDir, dir);
    if (!statSync(fullDir).isDirectory()) continue;
    for (const item of readdirSync(fullDir)) {
      // Object = either dir or .xml file (for flat objects like DefinedTypes)
      if (statSync(join(fullDir, item)).isDirectory()) {
        objects.push({ type, name: item });
      } else if (item.endsWith('.xml')) {
        const name = item.replace('.xml', '');
        // Avoid duplicates: if dir "Foo" exists and "Foo.xml" too, skip the xml
        if (!existsSync(join(fullDir, name))) {
          objects.push({ type, name });
        }
      }
    }
  }
  return objects;
}

// ─── Build skill args from _skill.json mapping ─────────────────────────────

function buildSkillArgs(skillConfig, caseData, workDir, inputFile, runtime) {
  const args = [];
  const scriptPath = resolveScript(skillConfig.script, runtime);

  for (const mapping of skillConfig.args) {
    args.push(mapping.flag);
    switch (mapping.from) {
      case 'inputFile':
        // inputFrom: вход берётся из файла в workDir, а не из case.input. Нужно, когда вход
        // производит preRun (например, декомпилятор) — case.input пишется ПОСЛЕ preRun и
        // затёр бы его. Как в runner.mjs.
        args.push(caseData.inputFrom ? join(workDir, caseData.inputFrom) : (inputFile || ''));
        break;
      case 'workDir':
        args.push(workDir);
        break;
      case 'outputPath':
        args.push(join(workDir, caseData.outputPath || ''));
        break;
      case 'workPath': {
        const field = mapping.field || 'objectPath';
        const val = caseData.params?.[field] ?? caseData[field];
        if (val === undefined || val === null || val === '') {
          if (mapping.optional) {
            args.pop(); // remove flag pushed above
            break;
          }
          args.push(join(workDir, ''));
        } else {
          args.push(join(workDir, val));
        }
        break;
      }
      case 'switch':
        args.pop();
        if (caseData[mapping.flag.replace(/^-/, '')] !== false) args.push(mapping.flag);
        break;
      default:
        if (mapping.from.startsWith('case.')) {
          const field = mapping.from.slice(5);
          args.push(String(caseData.params?.[field] ?? caseData[field] ?? ''));
        } else if (mapping.from === 'literal') {
          args.push(mapping.value || '');
        } else {
          // Незнакомый from раньше молча не давал значения — флаг уходил без аргумента, и
          // это выглядело как дефект навыка. DSL читают два раннера, поэтому расхождение
          // должно быть громким.
          throw new Error(`_skill.json: неизвестный "from": "${mapping.from}" у флага ${mapping.flag}`
            + ' — verify-snapshots.mjs не знает этого маппинга (см. buildSkillArgs)');
        }
    }
  }
  // Плейсхолдер {workDir} раскрывается и в args_extra — как в runner.mjs.
  if (caseData.args_extra) {
    args.push(...caseData.args_extra.map(a => typeof a === 'string' ? a.replace('{workDir}', workDir) : a));
  }
  return { scriptPath, args };
}

// ─── Execute preRun steps ───────────────────────────────────────────────────

function runPreSteps(preRun, workDir, runtime, log) {
  if (!preRun) return;
  for (const step of preRun) {
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
      log(`preRun: writeFile ${step.writeFile.path}`, true);
      continue;
    }
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
    const stepName = step.script.split('/').pop();
    try {
      // cwd: "{workDir}" — шаг запускается из рабочего каталога, чтобы относительные
      // пути в его args (напр. -OutputPath Template.xml) легли в фикстуру, а не в репозиторий.
      const preCwd = step.cwd === '{workDir}' ? workDir : REPO_ROOT;
      execSkill(runtime, step.script, preArgs, 60_000, preCwd);
      log(`preRun: ${stepName}`, true);
    } catch (e) {
      log(`preRun: ${stepName}`, false, e.stderr || e.message);
      throw new Error(`preRun "${step.script}" failed: ${(e.stderr || e.message).substring(0, 500)}`);
    }
    if (preInputFile && existsSync(preInputFile)) unlinkSync(preInputFile);
  }
}

// ─── Skills that DON'T produce loadable configs ─────────────────────────────
// These produce standalone files (SKD templates, MXL templates) that can't be
// loaded into platform without wrapping in a container object.

// Standalone file skills — produce files (not configs), platform load = just run script
const STANDALONE_SKILLS = new Set([
  'skd-compile', 'skd-edit', 'skd-info', 'skd-validate',
  'mxl-decompile', 'mxl-info', 'mxl-validate',
]);

// Standalone skills that CAN be platform-verified by wrapping their output in
// an external report (ERF) and running erf-build — the platform parses the
// schema and we know if it's accepted.
const SKD_PLATFORM_VERIFY = new Set(['skd-compile', 'skd-edit']);

// MXL: wrap produced Template.xml as a SpreadsheetDocument template inside
// an EPF source and run epf-build — platform parses the macro layout.
const MXL_PLATFORM_VERIFY = new Set(['mxl-compile']);

// EPF/ERF skills — verified by epf-build on the produced source.
// Map skill -> output extension (.epf/.erf).
const EPF_SKILLS = new Map([
  ['epf-init', '.epf'],
  ['erf-init', '.erf'],
]);

// Skills that produce either an EPF/ERF source or a full Configuration —
// route is auto-detected after the main script runs.
const EPF_OR_CONFIG_SKILLS = new Set(['template-add', 'help-add']);

// Диагностика падения навыка. Оба потока вместе: ps1 печатает строку ошибки в stdout, py — в
// stderr, а лог платформы оба кладут в stdout. Читать только `stderr || stdout` значило на
// python-порте потерять лог целиком — падение выглядело как «Error loading configuration (code: 1)»
// без причины, и по нему нельзя было отличить неподдерживаемый формат от реального дефекта.
function errDetail(e) {
  return [e.stdout, e.stderr, e.message].filter(Boolean).join('\n').trim();
}

// Режим совместимости конфигурации против версии платформы: "Version8_3_27" на 8.3.24 не
// загрузится. Возвращает причину пропуска либо null, если платформа подходит.
function compatibilityGap(configDir, v8path) {
  const cfgFile = join(configDir, 'Configuration.xml');
  if (!existsSync(cfgFile)) return null;
  const m = /<CompatibilityMode>Version(\d+)_(\d+)_(\d+)<\/CompatibilityMode>/.exec(readFileSync(cfgFile, 'utf8'));
  if (!m) return null;
  const need = [+m[1], +m[2], +m[3]];
  const p = /(\d+)\.(\d+)\.(\d+)/.exec(v8path || '');
  if (!p) return null;
  const have = [+p[1], +p[2], +p[3]];
  for (let i = 0; i < 3; i++) {
    if (have[i] > need[i]) return null;
    if (have[i] < need[i]) {
      return `режим совместимости ${need.join('.')} выше платформы ${have.join('.')} — запустите с --v8path`;
    }
  }
  return null;
}

// Аргументы cf-init для вариантов пустой конфигурации. Копия таблицы EMPTY_CONFIGS из
// runner.mjs — держать одинаковыми: разойдутся, и верификация пойдёт не на том формате,
// на котором прогонялся кейс.
const EMPTY_CONFIG_ARGS = {
  'empty-config': [],
  'empty-config-218': ['-FormatVersion', '2.18', '-CompatibilityMode', 'Version8_3_24'],
  'empty-config-220': ['-FormatVersion', '2.20', '-CompatibilityMode', 'Version8_3_27'],
  'empty-config-220-compat24': ['-FormatVersion', '2.20', '-CompatibilityMode', 'Version8_3_24'],
  'empty-config-221': ['-FormatVersion', '2.21', '-CompatibilityMode', 'Version8_3_27'],
};

// CFE skills — two-stage load: base config → extension
const CFE_SKILLS = new Set([
  'cfe-init', 'cfe-borrow', 'cfe-patch-method',
]);

// cf-init produces a config dir — verify by loading the created config
const CONFIG_INIT_SKILLS = new Set(['cf-init']);

// ─── Main verification pipeline ────────────────────────────────────────────

async function verifyCase(skillName, caseName, skillConfig, caseData, opts) {
  const result = {
    skill: skillName, case: caseName, name: caseData.name || caseName,
    passed: false, steps: [], errors: [], warnings: [], workDir: null,
  };

  const workDir = mkdtempSync(join(tmpdir(), `verify-${skillName}-${caseName}-`));
  result.workDir = workDir;

  // Кейс может осознанно исключаться из платформенной проверки — когда его
  // результат невалиден by design (например, операция намеренно оставляет
  // висящий импорт). Причина обязательна, молча пропускать нельзя.
  // Строка — пропуск всегда. Объект `{reason, platforms:[…]}` — пропуск ТОЛЬКО на перечисленных
  // сборках платформы: бывает, что кейс валиден и проверяется на всех стендах, кроме одного,
  // где сама платформа отвергает даже собственный артефакт. Глухой пропуск в таком случае снял
  // бы проверку и там, где она работает.
  if (caseData.skipPlatformVerify) {
    const spec = caseData.skipPlatformVerify;
    const isObj = typeof spec === 'object' && spec !== null;
    const reason = isObj ? spec.reason : String(spec);
    if (!reason) {
      result.errors.push('skipPlatformVerify: причина обязательна');
      return result;
    }
    const builds = isObj && Array.isArray(spec.platforms) ? spec.platforms : null;
    const v8exe = (opts.v8ctx && opts.v8ctx.v8exe) || '';
    if (!builds || builds.some(b => v8exe.includes(b))) {
      result.skipped = true;
      result.skipReason = reason;
      return result;
    }
  }

  // caseFiles — файловый вход кейса (напр. XSD для xdto-compile), как в runner.mjs
  for (const rel of caseData.caseFiles || []) {
    const src = join(CASES, skillName, rel);
    if (!existsSync(src)) throw new Error(`caseFiles: файл не найден: ${src}`);
    const dst = rel.includes('/') ? join(workDir, rel) : join(workDir, basename(rel));
    mkdirSync(dirname(dst), { recursive: true });
    copyFileSync(src, dst);
  }

  const log = (step, ok, detail) => {
    result.steps.push({ step, ok, detail: detail?.substring(0, 2000) });
    if (opts.verbose) {
      const icon = ok ? '\u2713' : '\u2717';
      console.log(`    ${icon} ${step}${detail ? ': ' + detail.substring(0, 200) : ''}`);
    }
  };

  // Determine config dir.
  // setup кейса перекрывает setup навыка — как в runner.mjs. Без этого кейсы с гейтом по версии
  // формата (empty-config-218/220/221) проверялись на конфигурации 2.17, то есть платформа не
  // видела ровно того поведения, ради которого кейс написан.
  const caseSetup = typeof caseData.setup === 'string' ? caseData.setup : null;
  const setupType = (caseSetup && caseSetup.startsWith('empty-config')) ? caseSetup : (skillConfig.setup || 'empty-config');
  const isStandalone = STANDALONE_SKILLS.has(skillName);
  let epfExt = EPF_SKILLS.get(skillName);
  let isEpf = !!epfExt;
  const isCfInit = CONFIG_INIT_SKILLS.has(skillName);
  // For 'empty-config': workDir is the config (setup creates it)
  // For cf-init: workDir becomes the config after the script runs
  // For 'none' + non-special: no config (standalone/EPF)
  let configDir = (setupType.startsWith('empty-config') || isCfInit) ? workDir : null;

  try {
    // ── Step 0: Case-level fixture/external setup (runner.mjs compatibility) ──
    // A case may declare:
    //   "setup": "fixture:<name>"  — copy tests/skills/cases/<skill>/fixtures/<name>
    //   "setup": "external:<path>" — copy contents of an external dump (e.g. ERP/БП)
    if (typeof caseData.setup === 'string' && caseData.setup.startsWith('fixture:')) {
      const fixtureName = caseData.setup.slice('fixture:'.length);
      const fixturePath = join(CASES, skillName, 'fixtures', fixtureName);
      if (!existsSync(fixturePath)) {
        result.errors.push(`Fixture not found: ${fixturePath}`);
        return result;
      }
      cpTreeSync(fixturePath, workDir);
      log(`fixture: ${fixtureName}`, true);
    } else if (typeof caseData.setup === 'string' && caseData.setup.startsWith('external:')) {
      const extPath = resolve(REPO_ROOT, caseData.setup.slice('external:'.length));
      // Недоступная внешняя выгрузка — СКИП, как в runner.mjs (`ensureSetup`, ветка
      // external). Путь к дампу ERP/БП машинозависим: на маке его нет, и падение
      // здесь красило набор при полностью исправном навыке — расхождение двух
      // раннеров по одному и тому же ключу DSL.
      if (!existsSync(extPath)) {
        result.skipped = true;
        result.skipReason = `внешняя выгрузка недоступна на этой машине: ${extPath}`;
        return result;
      }
      cpTreeSync(extPath, workDir);
      log(`external: ${extPath}`, true);
      configDir = workDir;
    }

    // ── Step 1: Setup (cf-init for empty-config, nothing for 'none') ──
    // Skip cf-init if external/fixture setup already provided a complete config
    const caseProvidedConfig = typeof caseData.setup === 'string' &&
      (caseData.setup.startsWith('external:') || caseData.setup.startsWith('fixture:'));
    // Skip setup for cf-init skill — the test itself creates the config
    if (configDir && setupType.startsWith('empty-config') && !CONFIG_INIT_SKILLS.has(skillName) && !caseProvidedConfig) {
      try {
        const initArgs = ['-Name', 'VerifyTest', '-OutputDir', workDir, ...(EMPTY_CONFIG_ARGS[setupType] || [])];
        execSkill(opts.runtime, 'cf-init/scripts/cf-init', initArgs);
        log('cf-init', true, (EMPTY_CONFIG_ARGS[setupType] || []).join(' '));
      } catch (e) {
        log('cf-init', false, e.stderr || e.message);
        result.errors.push(`cf-init failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }
    }

    // ── Step 2: Dependency stubs ──
    // Collect all inputs: from caseData.input AND from preRun steps
    const allInputs = [];
    if (caseData.input && (caseData.input.type || Array.isArray(caseData.input))) {
      const inputs = Array.isArray(caseData.input) ? caseData.input : [caseData.input];
      allInputs.push(...inputs.filter(i => i.type));
    }
    // Also scan preRun inputs for type refs (D3 fix)
    if (caseData.preRun) {
      for (const step of caseData.preRun) {
        if (step.input && step.input.type) allInputs.push(step.input);
        if (Array.isArray(step.input)) allInputs.push(...step.input.filter(i => i && i.type));
      }
    }

    if (configDir && allInputs.length > 0) {
      const mainNames = new Set(allInputs.map(i => `${i.type}.${i.name}`));

      // Structural deps (scanned across both main input and preRun inputs).
      // NB: только зависимости (стабы объектов, на которые ССЫЛАЕТСЯ вход). Верификатор НЕ правит сам
      // проверяемый объект — иначе в 1С грузится не то, что выдал компилятор (маскировка дефекта DSL).
      const structDeps = [...getStructuralDeps(allInputs), ...getFieldStubs(allInputs)];
      const structDSLs = new Map();
      const structPostEdits = new Map();
      const structPostWrites = new Map();
      for (const dep of structDeps) {
        const key = `${dep.type}.${dep.name}`;
        if (dep.dsl) structDSLs.set(key, dep.dsl);
        if (dep.postEdit) structPostEdits.set(key, dep.postEdit);
        if (dep.postWrite) structPostWrites.set(key, dep.postWrite);
      }

      // Type refs from ALL inputs (main + preRun)
      const allRefs = new Map();
      for (const inp of allInputs) {
        for (const [key, ref] of extractTypeRefs(inp)) {
          if (!mainNames.has(key)) allRefs.set(key, ref);
        }
      }
      for (const dep of structDeps) {
        const key = `${dep.type}.${dep.name}`;
        if (!mainNames.has(key) && !allRefs.has(key)) allRefs.set(key, { type: dep.type, name: dep.name });
      }

      // Create stubs
      for (const [key, ref] of allRefs) {
        const stubDSL = structDSLs.get(key) || makeStubDSL(ref.type, ref.name);
        if (!stubDSL) { result.warnings.push(`Cannot create stub for ${key}`); continue; }
        try {
          const stubFile = join(workDir, `__stub.json`);
          writeFileSync(stubFile, JSON.stringify(stubDSL, null, 2), 'utf8');
          execSkill(opts.runtime, 'meta-compile/scripts/meta-compile', ['-JsonPath', stubFile, '-OutputDir', configDir]);
          log(`stub: ${key}`, true);
        } catch (e) {
          log(`stub: ${key}`, false, e.stderr || e.message);
          result.warnings.push(`Stub failed: ${key}`);
        }

        // Post-edit (e.g. add-registerRecord)
        const edits = structPostEdits.get(key);
        if (edits) {
          const dir = TYPE_TO_DIR[ref.type];
          const objPath = dir ? join(configDir, dir, ref.name) : null;
          if (objPath && existsSync(objPath)) {
            for (const edit of edits) {
              try {
                execSkill(opts.runtime, 'meta-edit/scripts/meta-edit',
                  ['-ObjectPath', objPath, '-Operation', edit.op, '-Value', edit.val]);
                log(`postEdit: ${key}`, true, `${edit.op} ${edit.val}`);
              } catch (e) {
                log(`postEdit: ${key}`, false, e.stderr || e.message);
                result.warnings.push(`PostEdit failed: ${key}`);
              }
            }
          }
        }

        // Post-write: перезаписать файл стаба (напр. тело модуля CommonModule с экспортным методом-обработчиком)
        const writes = structPostWrites.get(key);
        if (writes) {
          for (const w of writes) {
            try {
              writeFileSync(join(configDir, w.relPath), '﻿' + w.content, 'utf8');
              log(`postWrite: ${key}`, true, w.relPath);
            } catch (e) { log(`postWrite: ${key}`, false, e.message); }
          }
        }
      }
    }

    // ── Step 3: preRun steps ──
    try {
      runPreSteps(caseData.preRun, workDir, opts.runtime, log);
    } catch (e) {
      result.errors.push(e.message);
      return result;
    }

    // ── Step 4: Main skill script ──
    let inputFile = null;
    if (caseData.input !== undefined) {
      inputFile = join(workDir, '__input.json');
      writeFileSync(inputFile, JSON.stringify(caseData.input, null, 2), 'utf8');
    }

    try {
      const { args } = buildSkillArgs(skillConfig, caseData, workDir, inputFile, opts.runtime);
      const mainCwd = (caseData.cwd || skillConfig.cwd) === 'workDir' ? workDir : REPO_ROOT;
      const output = execSkill(opts.runtime, skillConfig.script, args, 60_000, mainCwd);
      const lastLine = output.trim().split('\n').pop();
      if (caseData.expectError) {
        log(skillName, false, 'expected non-zero exit but got success');
        result.errors.push(`${skillName}: expected error but got success`);
        return result;
      }
      log(skillName, true, lastLine);
    } catch (e) {
      const detail = errDetail(e);
      if (caseData.expectError) {
        if (typeof caseData.expectError === 'string' && !detail.includes(caseData.expectError)) {
          log(skillName, false, `expected "${caseData.expectError}" in stderr, got: ${detail.substring(0, 200)}`);
          result.errors.push(`${skillName}: stderr does not contain "${caseData.expectError}"`);
          return result;
        }
        log(skillName, true, `(expected error) ${detail.substring(0, 100)}`);
        result.passed = true;
        return result;
      }
      log(skillName, false, detail);
      result.errors.push(`${skillName} failed: ${detail.substring(0, 500)}`);
      return result;
    }
    if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);

    // Режим совместимости конфигурации выше платформы — она такую не загрузит. Это свойство
    // стенда, а не дефект кейса, поэтому пропускаем с причиной: иначе на машине без нужной
    // платформы кейсы с гейтом по версии формата давали бы ложное падение.
    if (opts.v8ctx && configDir) {
      const compatSkip = compatibilityGap(configDir, opts.v8ctx.v8path);
      if (compatSkip) {
        result.skipped = true;
        result.skipReason = compatSkip;
        log('platform-load', true, `skipped (${compatSkip})`);
        return result;
      }
    }

    // ── Step 5: Determine verification strategy ──
    if (SKD_PLATFORM_VERIFY.has(skillName)) {
      // Wrap produced Template.xml in an external report (ERF) and try to build —
      // platform either accepts the schema or rejects it with an error.
      if (!opts.v8ctx) {
        result.passed = true;
        log('platform-load', true, 'skipped (no v8 context)');
        return result;
      }
      // outputPath у кейса бывает на ВЕРХНЕМ уровне (так его читает runner.mjs) и в params.
      // Порядок должен совпадать с раннером, иначе файл ищется не там, где навык его написал.
      const tplName = caseData.params?.templatePath || caseData.outputPath || caseData.params?.outputPath || 'Template.xml';
      const tplPath = join(workDir, tplName);
      if (!existsSync(tplPath)) {
        result.errors.push(`Output not produced at ${tplPath}`);
        return result;
      }
      const erfDir = join(workDir, 'erf-src');
      const erfOutDir = join(workDir, 'erf-build');
      mkdirSync(erfOutDir, { recursive: true });
      try {
        execSkill(opts.runtime, 'erf-init/scripts/init', ['-Name', 'TestReport', '-SrcDir', erfDir, '-WithSKD']);
        log('erf-init', true);
      } catch (e) {
        const detail = errDetail(e);
        log('erf-init', false, detail);
        result.errors.push(`erf-init failed: ${detail.substring(0, 500)}`);
        return result;
      }
      const dcsTpl = join(erfDir, 'TestReport', 'Templates', 'ОсновнаяСхемаКомпоновкиДанных', 'Ext', 'Template.xml');
      copyFileSync(tplPath, dcsTpl);
      try {
        execSkill(opts.runtime, 'epf-build/scripts/epf-build', [
          '-V8Path', opts.v8ctx.v8path,
          '-SourceFile', join(erfDir, 'TestReport.xml'),
          '-OutputFile', join(erfOutDir, 'TestReport.erf'),
        ], 120_000);
        log('erf-build', true, 'platform accepted schema');
        result.passed = true;
      } catch (e) {
        const detail = errDetail(e);
        log('erf-build', false, detail);
        result.errors.push(`erf-build rejected schema: ${detail.substring(0, 1000)}`);
      }
      return result;
    }

    if (MXL_PLATFORM_VERIFY.has(skillName)) {
      // См. выше: top-level outputPath имеет приоритет — так же, как в runner.mjs.
      const tplName = caseData.outputPath || caseData.params?.outputPath || 'Template.xml';
      const tplPath = join(workDir, tplName);
      if (!existsSync(tplPath)) {
        result.errors.push(`Output not produced at ${tplPath}`);
        return result;
      }
      const epfDir = join(workDir, 'epf-src');
      const epfOutDir = join(workDir, 'epf-build');
      mkdirSync(epfOutDir, { recursive: true });
      try {
        execSkill(opts.runtime, 'epf-init/scripts/init', ['-Name', 'TestProc', '-SrcDir', epfDir]);
        log('epf-init', true);
      } catch (e) {
        const detail = errDetail(e);
        log('epf-init', false, detail);
        result.errors.push(`epf-init failed: ${detail.substring(0, 500)}`);
        return result;
      }
      try {
        execSkill(opts.runtime, 'template-add/scripts/add-template', [
          '-ObjectName', 'TestProc',
          '-TemplateName', 'Макет',
          '-TemplateType', 'SpreadsheetDocument',
          '-SrcDir', epfDir,
        ]);
        log('template-add', true);
      } catch (e) {
        const detail = errDetail(e);
        log('template-add', false, detail);
        result.errors.push(`template-add failed: ${detail.substring(0, 500)}`);
        return result;
      }
      const tplDest = join(epfDir, 'TestProc', 'Templates', 'Макет', 'Ext', 'Template.xml');
      copyFileSync(tplPath, tplDest);
      try {
        execSkill(opts.runtime, 'epf-build/scripts/epf-build', [
          '-V8Path', opts.v8ctx.v8path,
          '-SourceFile', join(epfDir, 'TestProc.xml'),
          '-OutputFile', join(epfOutDir, 'TestProc.epf'),
        ], 180_000);
        log('epf-build', true, 'platform accepted MXL');
        result.passed = true;
      } catch (e) {
        const detail = errDetail(e);
        log('epf-build', false, detail);
        result.errors.push(`epf-build rejected MXL: ${detail.substring(0, 1000)}`);
      }
      return result;
    }

    if (isStandalone) {
      result.passed = true;
      log('platform-load', true, 'skipped (standalone file, not a config)');
      return result;
    }

    // Auto-detect: skills like template-add/help-add can target either an
    // EPF/ERF source or a full configuration. If Configuration.xml is absent
    // but a *.xml source for the named object is, route via epf-build.
    if (!isEpf && EPF_OR_CONFIG_SKILLS.has(skillName)) {
      const hasConfig = existsSync(join(workDir, 'Configuration.xml'));
      if (hasConfig) {
        configDir = workDir;
      } else {
        const epfName = caseData.params?.objectName || caseData.params?.name;
        if (epfName) {
          const xmlPath = join(workDir, `${epfName}.xml`);
          if (existsSync(xmlPath)) {
            const xml = readFileSync(xmlPath, 'utf8');
            if (/<ExternalDataProcessor[\s>]/.test(xml)) epfExt = '.epf';
            else if (/<ExternalReport[\s>]/.test(xml)) epfExt = '.erf';
            isEpf = !!epfExt;
          }
        }
      }
    }

    if (isEpf) {
      const name = caseData.params?.name || caseData.params?.objectName;
      if (!name) {
        result.errors.push(`EPF/ERF verify requires params.name or params.objectName`);
        return result;
      }
      const sourceFile = join(workDir, `${name}.xml`);
      if (!existsSync(sourceFile)) {
        result.errors.push(`EPF/ERF source not found: ${sourceFile}`);
        return result;
      }
      const outDir = join(workDir, '__build');
      mkdirSync(outDir, { recursive: true });
      const outFile = join(outDir, `${name}${epfExt}`);
      try {
        execSkill(opts.runtime, 'epf-build/scripts/epf-build', [
          '-V8Path', opts.v8ctx.v8path,
          '-SourceFile', sourceFile,
          '-OutputFile', outFile,
        ], 180_000);
        log('epf-build', true, `platform built ${epfExt}`);
        result.passed = true;
      } catch (e) {
        const detail = errDetail(e);
        log('epf-build', false, detail);
        result.errors.push(`epf-build failed: ${detail.substring(0, 1000)}`);
      }
      return result;
    }

    if (CFE_SKILLS.has(skillName)) {
      // CFE: two-stage load — base config first, then extension.
      // Каталог расширения берём из кейса, а не хардкодим: при жёстком 'ext' кейс, назвавший
      // каталог иначе, молча терял вторую половину проверки — блок ниже обходился по existsSync,
      // и в отчёте это выглядело как успех.
      const extRel = caseData.params?.extensionPath || caseData.params?.outputDir;
      if (!extRel || extRel === '.') {
        result.errors.push('CFE verify требует params.extensionPath (или params.outputDir) с каталогом расширения');
        return result;
      }
      const extDir = join(workDir, extRel);
      const baseConfigDir = workDir; // preRun puts base config directly in workDir
      const dbDir = join(workDir, 'testdb');

      // Register base config objects
      const baseObjects = scanConfigObjects(baseConfigDir);
      const baseCfEditOps = baseObjects
        .filter(o => TYPE_TO_PREFIX[o.type])
        .map(o => ({ operation: 'add-childObject', value: `${TYPE_TO_PREFIX[o.type]}.${o.name}` }));
      if (baseCfEditOps.length > 0) {
        try {
          const editFile = join(workDir, '__cf-edit-base.json');
          writeFileSync(editFile, JSON.stringify(baseCfEditOps, null, 2), 'utf8');
          execSkill(opts.runtime, 'cf-edit/scripts/cf-edit', ['-ConfigPath', baseConfigDir, '-DefinitionFile', editFile]);
          log('cf-edit (base)', true, `${baseCfEditOps.length} objects`);
        } catch (e) {
          log('cf-edit (base)', false, e.stderr || e.message);
          result.errors.push(`cf-edit base failed: ${(e.stderr || e.message).substring(0, 500)}`);
          return result;
        }
      }

      // Create DB + load base config
      try {
        execSkill(opts.runtime, 'db-create/scripts/db-create', ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir]);
        log('db-create', true);
      } catch (e) {
        log('db-create', false, e.stderr || e.message);
        result.errors.push(`db-create failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }

      try {
        execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
          ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', baseConfigDir, '-StrictLog'], 180_000);
        log('db-load-xml (config)', true);
      } catch (e) {
        const detail = errDetail(e);
        // Формат выгрузки новее платформы — свойство стенда, а не дефект кейса. Платформа
        // говорит об этом прямо, поэтому лестницу «платформа → версия формата» здесь
        // дублировать не нужно: читаем её ответ.
        const fmt = /Неизвестная версия формата ([\d.]+)/.exec(detail);
        if (fmt) {
          result.skipped = true;
          result.skipReason = `формат выгрузки ${fmt[1]} новее платформы — запустите с --v8path`;
          log('db-load-xml (config)', true, `skipped (${result.skipReason})`);
          return result;
        }
        log('db-load-xml (config)', false, detail);
        result.errors.push(`LoadConfig failed: ${detail.substring(0, 1000)}`);
        return result;
      }

      try {
        execSkill(opts.runtime, 'db-update/scripts/db-update',
          ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir], 180_000);
        log('db-update (config)', true);
      } catch (e) {
        const detail = errDetail(e);
        log('db-update (config)', false, detail);
        result.errors.push(`UpdateDBCfg config failed: ${detail.substring(0, 1000)}`);
        return result;
      }

      // Load extension — detect extension name from ext/Configuration.xml
      let extName = 'Extension';
      try {
        const extConfigXml = readFileSync(join(extDir, 'Configuration.xml'), 'utf8');
        const nameMatch = extConfigXml.match(/<Name>([^<]+)<\/Name>/);
        if (nameMatch) extName = nameMatch[1];
      } catch {}

      if (existsSync(extDir)) {
        try {
          execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
            ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', extDir, '-Extension', extName, '-StrictLog'], 180_000);
          log('db-load-xml (ext)', true);
        } catch (e) {
          const detail = errDetail(e);
          log('db-load-xml (ext)', false, detail);
          result.errors.push(`LoadExtension failed: ${detail.substring(0, 1000)}`);
          return result;
        }

        try {
          execSkill(opts.runtime, 'db-update/scripts/db-update',
            ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-Extension', extName], 180_000);
          log('db-update (ext)', true);
        } catch (e) {
          const detail = errDetail(e);
          log('db-update (ext)', false, detail);
          result.errors.push(`UpdateDBCfg ext failed: ${detail.substring(0, 1000)}`);
          return result;
        }
      }

      result.passed = true;
      return result;
    }

    if (CONFIG_INIT_SKILLS.has(skillName)) {
      // cf-init: the script already created the config in workDir,
      // but we called cf-init in Step 1 already. For cf-init tests,
      // the MAIN script IS cf-init, so workDir = the new config.
      // It should be loadable as-is.
    }

    if (!configDir) {
      // No config to load — setup was 'none' and not EPF/standalone
      result.passed = true;
      return result;
    }

    // ── Step 5.5: досоздать формы/макеты, на которые ссылается вход ──
    // meta-compile эмитит ссылки defaultForm/mainDataCompositionSchema/… но сами формы/макеты не создаёт
    // (это территория form-add/template-add). Для загрузки в 1С досоздаём их на уже скомпилированном объекте
    // (основной — из Step 4, внешние — из стабов Step 2). Решение: верификатор достраивает дочерние формы/макеты.
    if (Array.isArray(allInputs) && allInputs.length > 0) {
      // form-add поддерживает не все типы (напр. DocumentJournal — нет); для прочих форму не досоздать.
      const FORM_ADD_TYPES = new Set(['Document', 'Catalog', 'DataProcessor', 'Report',
        'InformationRegister', 'AccumulationRegister', 'ChartOfAccounts', 'ChartOfCharacteristicTypes',
        'ExchangePlan', 'BusinessProcess', 'Task', 'DocumentJournal']);
      const walk = function* (o, key) {
        if (o == null) return;
        if (typeof o === 'string') { yield { key, value: o }; return; }
        if (Array.isArray(o)) { for (const v of o) yield* walk(v, key); return; }
        if (typeof o === 'object') { for (const [k, v] of Object.entries(o)) yield* walk(v, k); }
      };
      const forms = new Map(), tpls = new Map();
      for (const inp of allInputs) {
        for (const { key, value } of walk(inp, null)) {
          const kl = (key || '').toLowerCase();
          const parts = String(value).split('.');
          const objType = TYPE_SYN[parts[0]] || parts[0];
          if (parts.length < 3 || !TYPE_TO_DIR[objType]) continue;
          const objName = parts[1], leaf = parts[parts.length - 1];
          // Форма — по ключу *Form (нотация ссылки любая: .Form./.Форма./короткая)
          if (/form$/.test(kl)) {
            let purpose = 'Object';
            if (kl.includes('list')) purpose = 'List';
            else if (kl.includes('choice')) purpose = 'Choice';
            else if (kl.includes('record')) purpose = 'Record';
            if (objType === 'Report' || objType === 'DataProcessor') purpose = 'Object';
            else if (objType === 'DocumentJournal') purpose = 'List';   // журнал — только списочные формы
            forms.set(`${objType}.${objName}.${leaf}`, { objType, objName, formName: leaf, purpose });
          }
          // Макет — по ключу *schema/*template
          if (kl.includes('datacompositionschema') || kl.includes('template')) {
            const isSKD = kl.includes('datacompositionschema');
            tpls.set(`${objType}.${objName}.${leaf}`, { objName, tplName: leaf, tplType: isSKD ? 'DataCompositionSchema' : 'SpreadsheetDocument', main: isSKD });
          }
        }
      }
      for (const f of forms.values()) {
        if (!FORM_ADD_TYPES.has(f.objType)) continue;   // form-add не умеет этот тип (напр. DocumentJournal)
        const objPath = join(configDir, TYPE_TO_DIR[f.objType], `${f.objName}.xml`);
        const formDir = join(configDir, TYPE_TO_DIR[f.objType], f.objName, 'Forms', f.formName);
        if (!existsSync(objPath) || existsSync(formDir)) continue;
        try {
          execSkill(opts.runtime, 'form-add/scripts/form-add', ['-ObjectPath', objPath, '-FormName', f.formName, '-Purpose', f.purpose]);
          log(`form-add: ${f.objName}.${f.formName}`, true);
        } catch (e) { log(`form-add: ${f.objName}.${f.formName}`, false, (e.stderr || e.message || '').substring(0, 200)); }
      }
      for (const t of tpls.values()) {
        try {
          execSkill(opts.runtime, 'template-add/scripts/add-template', ['-ObjectName', t.objName,
            '-TemplateName', t.tplName, '-TemplateType', t.tplType, '-SrcDir', configDir, ...(t.main ? ['-SetMainSKD'] : [])]);
          log(`template-add: ${t.objName}.${t.tplName}`, true);
        } catch (e) { log(`template-add: ${t.objName}.${t.tplName}`, false, (e.stderr || e.message || '').substring(0, 200)); }
      }
    }

    // ── Step 6: Auto-detect and register objects in ChildObjects ──
    // Skip when config came from external/fixture setup — it's already complete.
    const allObjects = caseProvidedConfig ? [] : scanConfigObjects(configDir);
    const cfEditOps = [];
    for (const obj of allObjects) {
      const prefix = TYPE_TO_PREFIX[obj.type];
      if (prefix) cfEditOps.push({ operation: 'add-childObject', value: `${prefix}.${obj.name}` });
    }

    if (cfEditOps.length > 0) {
      try {
        const editFile = join(workDir, '__cf-edit.json');
        writeFileSync(editFile, JSON.stringify(cfEditOps, null, 2), 'utf8');
        execSkill(opts.runtime, 'cf-edit/scripts/cf-edit', ['-ConfigPath', configDir, '-DefinitionFile', editFile]);
        log('cf-edit', true, `${cfEditOps.length} objects`);
      } catch (e) {
        log('cf-edit', false, e.stderr || e.message);
        result.errors.push(`cf-edit failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }
    }

    // ── Step 7: Platform load ──
    // Skip platform load for external dumps (e.g. real ERP/БП configs):
    // they're huge, version-sensitive, and the point of these test cases is
    // to exercise the skill script against real-world XML, not to validate
    // that an entire vendor config loads into a fresh DB.
    if (caseProvidedConfig && caseData.setup.startsWith('external:')) {
      result.passed = true;
      log('platform-load', true, 'skipped (external setup)');
      return result;
    }

    const dbDir = join(workDir, 'testdb');

    try {
      execSkill(opts.runtime, 'db-create/scripts/db-create', ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir]);
      log('db-create', true);
    } catch (e) {
      log('db-create', false, e.stderr || e.message);
      result.errors.push(`db-create failed: ${(e.stderr || e.message).substring(0, 500)}`);
      return result;
    }

    try {
      execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
        ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', configDir, '-StrictLog'], 180_000);
      log('db-load-xml', true);
    } catch (e) {
      const detail = errDetail(e);
      log('db-load-xml', false, detail);
      result.errors.push(`LoadConfigFromFiles failed: ${detail.substring(0, 1000)}`);
      return result;
    }

    try {
      execSkill(opts.runtime, 'db-update/scripts/db-update',
        ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir], 180_000);
      log('db-update', true);
    } catch (e) {
      const detail = errDetail(e);
      log('db-update', false, detail);
      result.errors.push(`UpdateDBCfg failed: ${detail.substring(0, 1000)}`);
      return result;
    }

    result.passed = true;
  } catch (e) {
    result.errors.push(`Unexpected error: ${e.message}`);
  } finally {
    if (!opts.keep) {
      // При неудаче оставляем в result реальный путь — остаток каталога виден в отчёте
      try { rmrfSync(workDir); result.workDir = '(cleaned)'; } catch {}
    }
  }

  return result;
}

// ─── Discovery ──────────────────────────────────────────────────────────────

// Default skills to verify when no --skill given
const DEFAULT_SKILLS = [
  'meta-compile', 'form-compile', 'form-compile-from-object', 'form-add', 'form-edit',
  'role-compile', 'subsystem-compile', 'subsystem-edit',
  'cf-init', 'cf-edit', 'meta-edit', 'interface-edit',
  'epf-init', 'erf-init', 'template-add', 'help-add',
  'cfe-init', 'cfe-borrow', 'cfe-patch-method',
  'skd-compile', 'skd-edit', 'mxl-compile',
  'xdto-compile', 'xdto-edit',
];

function discoverCases(skillFilter, caseFilter) {
  const results = [];
  const skillDirs = skillFilter ? [skillFilter] : DEFAULT_SKILLS;

  for (const skillDir of skillDirs) {
    const skillPath = join(CASES, skillDir);
    if (!existsSync(skillPath)) continue;

    const skillJsonPath = join(skillPath, '_skill.json');
    if (!existsSync(skillJsonPath)) continue;
    const skillConfig = JSON.parse(readFileSync(skillJsonPath, 'utf8'));

    // Skip skills that don't have snapshots (read-only, info, validate)
    if (!existsSync(join(skillPath, 'snapshots'))) continue;

    for (const file of readdirSync(skillPath)) {
      if (file.startsWith('_') || !file.endsWith('.json')) continue;
      const caseName = file.replace(/\.json$/, '');

      if (caseFilter && caseName !== caseFilter) continue;

      const caseData = JSON.parse(readFileSync(join(skillPath, file), 'utf8'));

      // Skip error cases
      if (caseName.startsWith('error-')) continue;

      // Skip cases without input AND without preRun AND without params (truly read-only).
      // Кейс на `setup: fixture:` тоже не read-only: навык правит скопированную фикстуру, и
      // без этой ветки такие кейсы молча выпадали из платформенной проверки — то есть ровно
      // из той, ради которой этот файл и существует.
      const hasFixtureSetup = typeof caseData.setup === 'string' && caseData.setup.startsWith('fixture:');
      if (caseData.input === undefined && !caseData.preRun && !caseData.params && !hasFixtureSetup) continue;

      results.push({ skill: skillDir, caseName, caseData, skillConfig });
    }
  }
  return results;
}

// ─── Report ─────────────────────────────────────────────────────────────────

function writeReport(results) {
  mkdirSync(REPORT_DIR, { recursive: true });

  const lines = [
    `# Snapshot Verification Report`,
    ``,
    `Date: ${new Date().toISOString().split('T')[0]}`,
    `Total: ${results.length} | Passed: ${results.filter(r => r.passed && !r.skipped).length}`
      + ` | Failed: ${results.filter(r => !r.passed && !r.skipped).length}`
      + ` | Skipped: ${results.filter(r => r.skipped).length}`,
    ``,
  ];

  lines.push('| Skill | Case | Status | Error |');
  lines.push('|-------|------|--------|-------|');
  for (const r of results) {
    // Пропуск — не падение: в консольной сводке они уже различались, а в файле отчёта пропуск
    // выглядел как FAIL и попадал в счётчик падений. Отчёт читают глазами и по нему решают,
    // есть ли проблема, — расхождение с консолью здесь дороже всего.
    const status = r.skipped ? 'SKIP' : (r.passed ? 'OK' : 'FAIL');
    const error = r.errors.length > 0 ? r.errors[0].substring(0, 100).replace(/\|/g, '\\|').replace(/\n/g, ' ') : '';
    lines.push(`| ${r.skill} | ${r.case} | ${status} | ${error} |`);
  }

  const failures = results.filter(r => !r.passed && !r.skipped);
  if (failures.length > 0) {
    lines.push('', '## Findings', '');
    for (const r of failures) {
      lines.push(`### ${r.skill}/${r.case}: ${r.name}`);
      lines.push('');
      lines.push('**Steps:**');
      for (const s of r.steps) {
        lines.push(`- ${s.ok ? '\u2713' : '\u2717'} ${s.step}${s.detail ? ': ' + s.detail.substring(0, 300) : ''}`);
      }
      if (r.warnings.length > 0) {
        lines.push('', '**Warnings:**');
        for (const w of r.warnings) lines.push(`- ${w}`);
      }
      lines.push('', '**Errors:**');
      for (const e of r.errors) lines.push('```', e, '```');
      lines.push('');
      lines.push('**Classification:** <!-- DSL_BUG | SCRIPT_BUG | VALIDATION_GAP | PLATFORM_QUIRK -->');
      lines.push('**Action:** <!-- normalize | warn | error | skip -->');
      lines.push('');
    }
  }

  const withWarnings = results.filter(r => r.passed && r.warnings.length > 0);
  if (withWarnings.length > 0) {
    lines.push('', '## Warnings (passed with notes)', '');
    for (const r of withWarnings) {
      lines.push(`### ${r.skill}/${r.case}`);
      for (const w of r.warnings) lines.push(`- ${w}`);
      lines.push('');
    }
  }

  const reportPath = join(REPORT_DIR, 'REPORT.md');
  writeFileSync(reportPath, lines.join('\n'), 'utf8');
  console.log(`\nReport written to: ${reportPath}`);
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) { printHelp(); return; }

  const v8ctx = loadV8Context(opts.v8path);
  if (!v8ctx) {
    console.error('ERROR: 1C platform not found. Pass --v8path, set .v8-project.json, or install to /opt/1cv8 (Program Files on Windows).');
    process.exit(1);
  }
  opts.v8ctx = v8ctx;
  console.log(`Platform: ${v8ctx.v8exe}`);

  const cases = discoverCases(opts.skill, opts.caseName);
  if (cases.length === 0) {
    console.error('No cases found.');
    process.exit(1);
  }
  console.log(`Found ${cases.length} case(s) to verify.\n`);

  const results = [];
  for (const { skill, caseName, caseData, skillConfig } of cases) {
    const label = `${skill}/${caseName}`;
    if (opts.verbose) console.log(`  ${label}: ${caseData.name || ''}`);
    else process.stdout.write(`  ${label}...`);

    const t0 = performance.now();
    const result = await verifyCase(skill, caseName, skillConfig, caseData, opts);
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);

    if (!opts.verbose) {
      // Скип — своя иконка, а не ✗: скипнутый кейс `passed` не выставляет, и построчный
      // вывод рисовал его падением. Итоговая строка при этом считала его skipped, из-за
      // чего десяток «✗» под «0 failed» читался как сломанный набор.
      const icon = result.skipped ? '\u25cb' : (result.passed ? '\u2713' : '\u2717');
      console.log(` ${icon} (${elapsed}s)${result.errors.length ? ' — ' + result.errors[0].substring(0, 80) : ''}`);
    } else {
      console.log(`    → ${result.skipped ? 'SKIP' : (result.passed ? 'PASS' : 'FAIL')} (${elapsed}s)\n`);
    }

    results.push(result);
  }

  const passed = results.filter(r => r.passed).length;
  const skipped = results.filter(r => r.skipped).length;
  const failed = results.filter(r => !r.passed && !r.skipped).length;
  console.log(`\n${'='.repeat(60)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`
    + (skipped ? `, ${skipped} skipped` : '') + ` out of ${results.length}`);
  for (const r of results.filter(x => x.skipped)) {
    console.log(`  \u25cb ${r.skill}/${r.case} \u2014 ${r.skipReason}`);
  }

  writeReport(results);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
