#!/usr/bin/env node
// Инвариант: НИ ОДНА операция meta-edit не меняет идентификатор существующей сущности —
// ни объекта, ни реквизита/измерения/ресурса/ТЧ, ни GeneratedType (TypeId/ValueId).
// Смена uuid рвёт ссылки/данные/состояние поддержки. Снапшот-тесты это НЕ ловят
// (нормализуют uuid позиционно), поэтому нужен отдельный guard.
//
// Компилирует объект, фиксирует uuid'ы, применяет широкую правку (rename+type+структурные
// свойства+свойства объекта+ТЧ+add+remove), сверяет что uuid существующих сущностей целы.
// Прогоняет оба рантайма. Выход 1 при нарушении. Запуск: node tests/skills/check-uuid-invariant.mjs [--runtime python]
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
// fs.rmSync/fs.cpSync напрямую не зовём: на Windows они молча ничего не делают,
// когда в пути есть не-ASCII символы. Подробности и таблица сборок — в самом модуле.
import { removePathSync } from '../common/fsutil.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const IS_WIN = process.platform === 'win32';
// PowerShell вне Windows не исполняется — это природа платформы, а не пробел в покрытии
// (см. debug/macmini-testing.md). Отсеиваем порт по ОС, иначе гард падал бы на маке с
// «spawnSync powershell.exe ENOENT» и красил весь check-all.
const requested = process.argv.includes('--runtime')
  ? [process.argv[process.argv.indexOf('--runtime') + 1] === 'python' ? 'python' : 'powershell']
  : ['powershell', 'python'];
const runtimes = requested.filter(rt => rt !== 'powershell' || IS_WIN);
if (requested.includes('powershell') && !IS_WIN) {
  console.log(`[powershell] пропущен: PowerShell не исполняется на ${process.platform}`);
}
if (runtimes.length === 0) {
  console.log('Нечего проверять: запрошен только powershell, а он на этой ОС не исполняется.');
  process.exit(1);
}

// На *nix интерпретатор зовётся python3; `python` там обычно отсутствует вовсе.
const PY = process.env.PYTHON || (IS_WIN ? 'python' : 'python3');

function skill(runtime, name, args, cwd) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const p = join(ROOT, '.claude/skills', name, 'scripts', name + ext);
  if (runtime === 'python') {
    execFileSync(PY, [p, ...args], { cwd, stdio: 'pipe' });
  } else {
    execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', p, ...args], { cwd, stdio: 'pipe' });
  }
}

// Множество ВСЕХ идентификаторов объекта: каждый uuid="..." (тип-элемент, реквизиты, ТЧ,
// формы, команды…) + GeneratedType TypeId/ValueId. Надёжнее, чем маппинг по имени
// (ТЧ имеет InternalInfo между uuid и Properties).
function collectUuids(xmlPath) {
  const s = readFileSync(xmlPath, 'utf8');
  const set = new Set([...s.matchAll(/\buuid="([0-9a-f-]{36})"/g)].map(m => m[1]));
  for (const m of s.matchAll(/<xr:(?:TypeId|ValueId)>([0-9a-f-]{36})</g)) set.add(m[1]);
  return set;
}

// uuid реквизита по имени (для исключения намеренно удаляемого; реквизит имеет <Properties> сразу).
function attrUuid(xmlPath, name) {
  const s = readFileSync(xmlPath, 'utf8');
  const m = s.match(new RegExp(`<Attribute uuid="([0-9a-f-]{36})">\\s*<Properties>\\s*<Name>${name}</Name>`));
  return m ? m[1] : null;
}

let failures = 0;   // нарушения инварианта
let runErrors = 0;  // прогон не состоялся: окружение, а не uuid

for (const runtime of runtimes) {
  let work;
  try {
    work = mkdtempSync(join(tmpdir(), 'uuidinv-'));
    // 1. Конфигурация + объект
    skill(runtime, 'cf-init', ['-OutputDir', work, '-Name', 'Т'], work);
    const inp = join(work, 'c.json');
    writeFileSync(inp, JSON.stringify({
      type: 'Catalog', name: 'Спр',
      attributes: ['Комм: String(50)', 'Сумма: Number(15,2)', 'Удаляемый: String(10)'],
      tabularSections: { 'Товары': ['Цена: Number(15,2)', 'Кол: Number(15,3)'] },
    }), 'utf8');
    skill(runtime, 'meta-compile', ['-JsonPath', inp, '-OutputDir', work], work);
    const objXml = join(work, 'Catalogs', 'Спр.xml');

    const before = collectUuids(objXml);
    const removedUuid = attrUuid(objXml, 'Удаляемый');

    // 2. Широкая правка существующих сущностей + add + remove
    const edit = join(work, 'e.json');
    writeFileSync(edit, JSON.stringify({
      modify: {
        properties: { CodeLength: 15, DataLockFields: ['Сумма'] },
        attributes: {
          'Комм': { name: 'Комментарий', type: 'String(200)' },
          'Сумма': { MinValue: 0, Format: 'ЧЦ=15; ЧДЦ=2' },
        },
        tabularSections: { 'Товары': { modify: { 'Цена': { name: 'ЦенаНовая' } } } },
      },
      add: { attributes: ['НовыйРекв: Boolean'], predefined: ['(1) ПервыйПредоп', '(2) ВторойПредоп'] },
      remove: { attributes: ['Удаляемый'] },
    }), 'utf8');
    skill(runtime, 'meta-edit', ['-ObjectPath', objXml, '-DefinitionFile', edit, '-NoValidate'], work);

    const after = collectUuids(objXml);

    // 3b. Инвариант для предопределённых: добавление ещё элементов не меняет id существующих <Item>.
    const predefXml = join(work, 'Catalogs', 'Спр', 'Ext', 'Predefined.xml');
    const predefIds = (p) => new Set([...readFileSync(p, 'utf8').matchAll(/<Item id="([0-9a-f-]{36})"/g)].map(m => m[1]));
    const predefBefore = predefIds(predefXml);
    const edit2 = join(work, 'e2.json');
    writeFileSync(edit2, JSON.stringify({ add: { predefined: ['(3) ТретийПредоп'] } }), 'utf8');
    skill(runtime, 'meta-edit', ['-ObjectPath', objXml, '-DefinitionFile', edit2, '-NoValidate'], work);
    const predefAfter = predefIds(predefXml);

    // 3. Инвариант: каждый uuid, существовавший ДО правки (кроме намеренно удалённого),
    // должен присутствовать ПОСЛЕ (переименование/смена типа/структурные свойства НЕ меняют id).
    const fail = (msg) => { console.log(`[${runtime}] НАРУШЕНИЕ: ${msg}`); failures++; };
    let checked = 0;
    for (const uuid of before) {
      if (uuid === removedUuid) continue;   // Attribute «Удаляемый» намеренно удалён
      checked++;
      if (!after.has(uuid)) fail(`uuid ${uuid} пропал после правки (перегенерирован?)`);
    }
    if (removedUuid && after.has(removedUuid)) fail(`uuid удалённого реквизита ${removedUuid} остался (не удалён?)`);
    for (const id of predefBefore) {
      if (!predefAfter.has(id)) fail(`id предопределённого элемента ${id} пропал после добавления новых (перегенерирован?)`);
    }
    console.log(`[${runtime}] проверено ${checked} uuid объекта + ${predefBefore.size} id предопределённых (сохранены при add)`);

    // 4. Внешний источник данных: правки идут в ДВА файла (источник и таблицу), причём таблицу
    // навык создаёт сам. Уникальный для этого вида риск — пересборка файла источника целиком:
    // она дала бы источнику новый uuid и осиротила бы уже существующие таблицы.
    const edsInp = join(work, 'eds.json');
    writeFileSync(edsInp, JSON.stringify({
      type: 'ExternalDataSource', name: 'PG',
      tables: { products: { keyFields: ['id'], fields: ['id: Number(10,0)', 'name: String(150)'] } },
      functions: { total: { expression: 'public.f_total(&1)', returns: 'Number(15,2)' } },
    }), 'utf8');
    skill(runtime, 'meta-compile', ['-JsonPath', edsInp, '-OutputDir', work], work);
    const srcXml = join(work, 'ExternalDataSources', 'PG.xml');
    const tblXml = join(work, 'ExternalDataSources', 'PG', 'Tables', 'products.xml');
    const edsBefore = new Set([...collectUuids(srcXml), ...collectUuids(tblXml)]);

    const edsEdit1 = join(work, 'eds-e1.json');
    writeFileSync(edsEdit1, JSON.stringify({
      add: {
        tables: { sales: { keyFields: ['id'], fields: ['id: Number(10,0)'] } },
        functions: { nextKey: 'NEXT VALUE FOR public.seq_key' },
      },
    }), 'utf8');
    skill(runtime, 'meta-edit', ['-ObjectPath', srcXml, '-DefinitionFile', edsEdit1, '-NoValidate'], work);

    const edsEdit2 = join(work, 'eds-e2.json');
    writeFileSync(edsEdit2, JSON.stringify({
      add: { fields: ['barcode: String(20) | nullable'] },
      modify: { fields: { name: { name: 'title', type: 'String(200)' } } },
    }), 'utf8');
    skill(runtime, 'meta-edit', ['-ObjectPath', tblXml, '-DefinitionFile', edsEdit2, '-NoValidate'], work);

    const edsAfter = new Set([...collectUuids(srcXml), ...collectUuids(tblXml)]);
    // Правка обязана быть применённой: без этого проверка uuid ничего не значит.
    if (!readFileSync(tblXml, 'utf8').includes('<Name>title</Name>')) {
      fail('поле не переименовано — сценарий внешнего источника проверил бы uuid вхолостую');
    }
    let edsChecked = 0;
    for (const uuid of edsBefore) {
      edsChecked++;
      if (!edsAfter.has(uuid)) fail(`uuid ${uuid} внешнего источника пропал после правки (пересборка файла?)`);
    }
    console.log(`[${runtime}] проверено ${edsChecked} uuid внешнего источника и его таблицы`);
  } catch (e) {
    const detail = (e.stderr || e.message || '').toString();
    console.log(`[${runtime}] ОШИБКА прогона: ${detail.slice(0, 300)}`);
    // Гард запускает НАВЫКИ, а им нужен интерпретатор с lxml. Системный python3 на маке его не
    // имеет, и без подсказки ошибка читается как нарушение инварианта, а не как окружение.
    if (runtime === 'python' && /ModuleNotFoundError|No module named|ENOENT/.test(detail)) {
      console.log(`[python] интерпретатор: ${PY}. Если модулей нет — указать venv: PYTHON=<путь> node ${'tests/skills/check-uuid-invariant.mjs'}`);
    }
    runErrors++;
  } finally {
    if (work) try { removePathSync(work); } catch {}
  }
}

// Ошибку прогона от нарушения инварианта отличаем в выводе: «N НАРУШЕНИЙ инварианта uuid»
// на несобранном окружении отправляет искать баг там, где его нет.
if (failures) console.log(`\n${failures} НАРУШЕНИЙ инварианта uuid.`);
if (runErrors) console.log(`${runErrors} порт(ов) не удалось прогнать — инвариант НЕ проверен (окружение, не uuid).`);
if (!failures && !runErrors) console.log('OK — инвариант сохранения uuid держится (объект/сущности/GeneratedType)');
process.exit(failures || runErrors ? 1 : 0);
