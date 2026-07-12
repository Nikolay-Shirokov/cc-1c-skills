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
import { readFileSync, writeFileSync, mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const runtimes = process.argv.includes('--runtime')
  ? [process.argv[process.argv.indexOf('--runtime') + 1] === 'python' ? 'python' : 'powershell']
  : ['powershell', 'python'];

function skill(runtime, name, args, cwd) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const p = join(ROOT, '.claude/skills', name, 'scripts', name + ext);
  if (runtime === 'python') {
    execFileSync(process.env.PYTHON || 'python', [p, ...args], { cwd, stdio: 'pipe' });
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

let failures = 0;

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
  } catch (e) {
    console.log(`[${runtime}] ОШИБКА прогона: ${(e.stderr || e.message || '').toString().slice(0, 300)}`);
    failures++;
  } finally {
    if (work) try { rmSync(work, { recursive: true, force: true }); } catch {}
  }
}

console.log(failures === 0
  ? 'OK — инвариант сохранения uuid держится (объект/сущности/GeneratedType)'
  : `\n${failures} НАРУШЕНИЙ инварианта uuid.`);
process.exit(failures ? 1 : 0);
