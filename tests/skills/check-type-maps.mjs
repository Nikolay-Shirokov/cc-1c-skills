#!/usr/bin/env node
// Анти-дрейф словарей типов метаданных. Навыки автономны, карты типов продублированы, и раньше
// расхождение накапливалось молча: тип Bot существовал в спецификации и в трёх навыках, а в
// остальных его не было — никто этого не замечал, потому что сверять было не с чем.
//
// Эталон — таблица «Порядок типов в ChildObjects» из docs/1c-configuration-spec.md (45 типов:
// каноническое имя + каталог + позиция). Берём документацию, а не отдельный JSON: тогда спека и
// код не расходятся молча, что и было целью ишью #60.
//
// Модель двухуровневая: общее ядро (имя/каталог/порядок) обязано совпадать у всех, а каждый навык
// объявляет своё подмножество — исключение с ПРИЧИНОЙ. Так проверка отличает намеренное
// ограничение от забытого типа.
//
// Запуск: node tests/skills/check-type-maps.mjs [--list]
// Выход 1 при ERROR, 0 при WARN.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');
const SPEC = join(ROOT, 'docs', '1c-configuration-spec.md');

// ─── Реестр карт ────────────────────────────────────────────────────────────
// kind: 'dir'   — тип → каталог: ключи и значения сверяются с таблицей
//       'order' — список типов: порядок обязан совпадать с порядком таблицы
//       'keys'  — ключи обязаны быть каноническими именами (значения свои)
//       'alias' — значения обязаны быть каноническими именами (ключи — вокабуляр навыка)
//       'gentypes' — тип → набор GeneratedType (префикс+категория), сверка с таблицей §2.5
//       'gencats'  — то же, но карта хранит только категории (префиксов в ней нет)
// exclude: { Тип: 'причина' } — тип, которого в карте нет намеренно. Без причины → WARN.
// extraTargets — не-ChildObjects имена, законные для alias-карты (вложенные сущности и т. п.)

const MAPS = [
  // тип → каталог
  { skill: 'cf-edit', file: 'cf-edit', kind: 'dir', py: 'TYPE_TO_DIR', ps1: '$script:typeToDir' },
  { skill: 'cf-validate', file: 'cf-validate', kind: 'dir', py: 'CHILD_TYPE_DIR_MAP', ps1: '$childTypeDirMap' },
  {
    skill: 'cfe-validate', file: 'cfe-validate', kind: 'dir',
    py: 'CHILD_TYPE_DIR_MAP', ps1: '$childTypeDirMap',
  },
  { skill: 'cfe-borrow', file: 'cfe-borrow', kind: 'dir', py: 'CHILD_TYPE_DIR_MAP', ps1: '$childTypeDirMap' },
  {
    skill: 'cfe-diff', file: 'cfe-diff', kind: 'dir', py: 'CHILD_TYPE_DIR_MAP', ps1: '$childTypeDirMap',
    exclude: {
      Language: 'навык пропускает языки при сборе объектов (cfe-diff.py:530) — запись в карте была бы недостижима',
    },
  },

  // порядок типов
  { skill: 'cf-edit', file: 'cf-edit', kind: 'order', py: 'TYPE_ORDER', ps1: '$script:typeOrder' },
  { skill: 'cf-info', file: 'cf-info', kind: 'order', py: 'type_order', ps1: '$typeOrder' },
  { skill: 'cf-validate', file: 'cf-validate', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },
  { skill: 'cfe-validate', file: 'cfe-validate', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },
  { skill: 'cfe-borrow', file: 'cfe-borrow', kind: 'order', py: 'TYPE_ORDER', ps1: '$script:typeOrder' },
  // Навыки-создатели: список нужен, чтобы новая группа вида встала на своё место, а не в конец
  // блока — иначе платформа переставит её при первой же выгрузке.
  { skill: 'meta-compile', file: 'meta-compile', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },
  { skill: 'role-compile', file: 'role-compile', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },
  { skill: 'xdto-compile', file: 'xdto-compile', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },
  { skill: 'subsystem-compile', file: 'subsystem-compile', kind: 'order', py: 'CHILD_OBJECT_TYPES', ps1: '$childObjectTypes' },

  // ключи — канонические имена
  { skill: 'cf-info', file: 'cf-info', kind: 'keys', py: 'type_ru_names', ps1: '$typeRuNames' },

  // вокабуляры: значения — канонические имена, полнота не требуется
  {
    skill: 'role-compile', file: 'role-compile', kind: 'alias', py: 'TYPE_ALIASES', ps1: null,
    extraTargets: ['Configuration', 'Attribute', 'StandardAttribute',
      'TabularSection', 'Dimension', 'Resource', 'Command', 'AddressingAttribute'],
  },
  { skill: 'interface-edit', file: 'interface-edit', kind: 'alias', py: 'TYPE_NORM_MAP', ps1: null },
  { skill: 'subsystem-edit', file: 'subsystem-edit', kind: 'alias', py: 'CONTENT_TYPE_MAP', ps1: null },
  { skill: 'subsystem-compile', file: 'subsystem-compile', kind: 'alias', py: 'CONTENT_TYPE_MAP', ps1: null },
  { skill: 'meta-remove', file: 'meta-remove', kind: 'keys', py: 'TYPE_PLURAL_MAP', ps1: '$typePluralMap' },
  { skill: 'cf-edit', file: 'cf-edit', kind: 'alias', py: 'RU_TYPE_MAP', ps1: '$script:ruTypeMap' },
  { skill: 'cfe-borrow', file: 'cfe-borrow', kind: 'alias', py: 'SYNONYM_MAP', ps1: '$synonymMap' },
  { skill: 'cfe-patch-method', file: 'cfe-patch-method', kind: 'alias',
    py: 'DIR_TO_TYPE', ps1: '$script:dirToType' },
  // наборы GeneratedType (эталон — таблица §2.5). Ишью 64: у cfe-borrow молча не хватало
  // категории Characteristic у ПВХ — платформа отвергала заимствованную оболочку, а сверять
  // было не с чем: карта категорий живёт в трёх навыках, и две из них были правы.
  {
    skill: 'cfe-borrow', file: 'cfe-borrow', kind: 'gentypes',
    py: 'GENERATED_TYPES', ps1: '$script:generatedTypes',
    exclude: { Table: 'навык не работает с таблицами внешних источников' },
  },
  {
    skill: 'meta-compile', file: 'meta-compile', kind: 'gentypes',
    py: 'generated_types', ps1: '$script:generatedTypes',
    exclude: {
      IntegrationService: 'навык не создаёт объекты этого вида — генерируемых типов для него нет',
      Table: 'InternalInfo таблицы строится инлайном: имя элемента трёхчастное (префикс.Источник.Таблица), карта «вид → набор» такой формы не выражает',
    },
  },
  {
    skill: 'cfe-validate', file: 'cfe-validate', kind: 'gencats',
    py: 'GENERATED_TYPE_CATEGORIES', ps1: '$generatedTypeCategories',
    exclude: { Table: 'навык не работает с таблицами внешних источников' },
  },
  {
    skill: 'meta-validate', file: 'meta-validate', kind: 'gencats',
    py: 'generated_type_categories', ps1: '$generatedTypeCategories',
    exclude: {
      IntegrationService: 'в $structuralOnlyTypes — только структурная проверка',
      Sequence: 'в $structuralOnlyTypes — навык проверяет такие объекты только структурно (root/uuid/Name)',
      FilterCriterion: 'в $structuralOnlyTypes — только структурная проверка',
      SettingsStorage: 'в $structuralOnlyTypes — только структурная проверка',
      WSReference: 'в $structuralOnlyTypes — только структурная проверка',
    },
  },
  {
    // Частичная карта тип→каталог: перехватывать метод можно только у объектов с модулями,
    // поэтому полнота не требуется. Плюс прощающий ввод — ключом принимается и имя каталога
    // (Catalogs.X ≡ Catalog.X), поэтому ключи сверяем как «тип ИЛИ каталог типа».
    skill: 'cfe-patch-method', file: 'cfe-patch-method', kind: 'dir', partial: true, keyMayBeDir: true,
    py: 'TYPE_DIR_MAP', ps1: '$script:typeDirMap',
  },
];

// ─── Эталон из спецификации ─────────────────────────────────────────────────

function readSpec() {
  const text = readFileSync(SPEC, 'utf8');
  const rows = [...text.matchAll(/^\|\s*(\d+)\s*\|\s*`(\w+)`\s*\|\s*`([\w/]+)`\s*\|/gm)];
  if (rows.length < 40) throw new Error(`Таблица типов не распознана в ${SPEC} (строк: ${rows.length})`);
  const order = [];
  const dirOf = new Map();
  for (const r of rows) {
    const type = r[2];
    order.push(type);
    dirOf.set(type, r[3].replace(/\/$/, ''));
  }
  return { order, dirOf, genTypes: readGenTypes(text) };
}

// Таблица §2.5 «InternalInfo объектов — наборы GeneratedType»: строка вида
//   | `Catalog` | `CatalogObject`/Object, `CatalogRef`/Ref, … |
// Сокращение `…X` в префиксе разворачивается в `<Тип>X` (так записано в самой таблице).
function readGenTypes(text) {
  const section = text.slice(text.indexOf('### 2.5.'), text.indexOf('## 3. ConfigDumpInfo'));
  const genTypes = new Map();
  for (const row of section.matchAll(/^\|\s*`(\w+)`\s*\|\s*(`[^|]+)\|/gm)) {
    const type = row[1];
    const pairs = [...row[2].matchAll(/`([\w…]+)`\/(\w+)/g)]
      .map(([, prefix, category]) => [prefix.replace('…', type), category]);
    if (pairs.length) genTypes.set(type, pairs);
  }
  if (genTypes.size < 20) throw new Error(`Таблица GeneratedType не распознана в ${SPEC} (типов: ${genTypes.size})`);
  return genTypes;
}

// ─── Извлечение карт ────────────────────────────────────────────────────────
// Определение может быть вложенным (subsystem-compile объявляет CONTENT_TYPE_MAP внутри функции),
// поэтому конец блока ищем по закрывающей скобке на отступе самого объявления.

function sliceBlock(text, startIdx, open, close) {
  const lineStart = text.lastIndexOf('\n', startIdx) + 1;
  const indent = text.slice(lineStart, startIdx).match(/^\s*/)[0];
  const from = text.indexOf(open, startIdx);
  if (from < 0) return null;
  const closer = `\n${indent}${close}`;
  const to = text.indexOf(closer, from);
  // Закрывашки нет — значит это не блок, а выражение в одну строку. Возвращать «до конца файла»
  // нельзя: обнаружение тогда видит в таком «блоке» все канонические имена сразу.
  if (to < 0) return null;
  return text.slice(from + open.length, to);
}

function extractPy(text, name, kind) {
  const re = new RegExp(`^\\s*${name.replace(/\$/g, '\\$')}\\s*=\\s*[{[]`, 'm');
  const m = re.exec(text);
  if (!m) return null;
  const isList = kind === 'order';
  const body = sliceBlock(text, m.index + m[0].length - 1, isList ? '[' : '{', isList ? ']' : '}');
  if (body === null) return null;
  if (isList) return [...body.matchAll(/['"]([\w]+)['"]/g)].map((x) => x[1]);
  return [...body.matchAll(/['"]([^'"]+)['"]\s*:\s*['"]([^'"]*)['"]/g)].map((x) => [x[1], x[2]]);
}

function extractPs1(text, name, kind) {
  const re = new RegExp(`^\\s*${name.replace(/[$]/g, '\\$')}\\s*=\\s*@[({]`, 'm');
  const m = re.exec(text);
  if (!m) return null;
  const isList = kind === 'order';
  const body = sliceBlock(text, m.index + m[0].length - 1, isList ? '(' : '{', isList ? ')' : '}');
  if (body === null) return null;
  if (isList) return [...body.matchAll(/"([\w]+)"/g)].map((x) => x[1]);
  return [...body.matchAll(/"([^"]+)"\s*=\s*"([^"]*)"/g)].map((x) => [x[1], x[2]]);
}

// Карты GeneratedType вложены на два уровня (тип → список пар), поэтому плоские extractPy/extractPs1
// к ним не применимы: нужен разбор по блокам типа. Возвращаем Map<тип, [[префикс, категория], …]>;
// для 'gencats' префикс неизвестен и остаётся null.
function extractGen(text, name, kind, lang) {
  const isPs1 = lang === 'ps1';
  const head = isPs1
    ? new RegExp(`^\\s*${name.replace(/[$]/g, '\\$')}\\s*=\\s*@\\{`, 'm')
    : new RegExp(`^\\s*${name}\\s*=\\s*\\{`, 'm');
  const m = head.exec(text);
  if (!m) return null;
  const body = sliceBlock(text, m.index + m[0].length - 1, isPs1 ? '{' : '{', '}');
  if (body === null) return null;

  // .py-порты навыков расходятся стилем кавычек (meta-compile — одинарные, cfe-borrow — двойные),
  // поэтому в py-ветке принимаем оба.
  const typeHead = isPs1 ? /^\s*"(\w+)"\s*=\s*@\(/ : /^\s*['"](\w+)['"]\s*:\s*\[/;
  const pairRe = isPs1
    ? /prefix\s*=\s*"(\w+)";\s*category\s*=\s*"(\w+)"/
    : /['"]prefix['"]:\s*['"](\w+)['"],\s*['"]category['"]:\s*['"](\w+)['"]/;

  const out = new Map();
  let cur = null;
  for (const line of body.split('\n')) {
    const h = typeHead.exec(line);
    if (h) {
      cur = h[1];
      out.set(cur, []);
      if (kind === 'gencats') {
        // категории лежат в той же строке: "Catalog" = @("Object","Ref",…) / 'Catalog': ['Object', …]
        for (const c of line.slice(h[0].length).matchAll(/['"](\w+)['"]/g)) out.get(cur).push([null, c[1]]);
      }
      continue;
    }
    if (!cur || kind === 'gencats') continue;
    const p = pairRe.exec(line);
    if (p) out.get(cur).push([p[1], p[2]]);
  }
  return out;
}

function readSkill(skill, file, ext) {
  const p = join(SKILLS, skill, 'scripts', `${file}.${ext}`);
  if (!existsSync(p)) return null;
  return readFileSync(p, 'utf8').replace(/^﻿/, '');
}

// ─── Проверка ───────────────────────────────────────────────────────────────

const spec = readSpec();
const canonical = new Set(spec.order);
const errors = [];
const warns = [];
const seen = [];

for (const entry of MAPS) {
  for (const lang of ['py', 'ps1']) {
    const name = entry[lang];
    if (!name) continue;
    const text = readSkill(entry.skill, entry.file, lang === 'py' ? 'py' : 'ps1');
    if (text === null) continue;

    if (entry.kind === 'gentypes' || entry.kind === 'gencats') {
      checkGenTypes(entry, lang, text, name);
      continue;
    }

    const data = lang === 'py' ? extractPy(text, name, entry.kind) : extractPs1(text, name, entry.kind);
    if (data === null) {
      errors.push(`${entry.skill}.${name} [${lang}]: карта не найдена — реестр протух`);
      continue;
    }
    // Пустое извлечение = парсер не понял формат. Для alias/keys это прошло бы вхолостую,
    // поэтому проверяем явно, а не полагаемся на «нет записей — нет расхождений».
    if (data.length === 0) {
      errors.push(`${entry.skill}.${name} [${lang}]: карта извлеклась пустой — сломан разбор формата`);
      continue;
    }

    const tag = `${entry.skill}.${name} [${lang}]`;
    const exclude = entry.exclude || {};

    if (entry.kind === 'order') {
      seen.push({ tag, count: data.length });
      for (const t of data) {
        if (!canonical.has(t)) errors.push(`${tag}: тип '${t}' отсутствует в таблице спецификации`);
      }
      // порядок — подпоследовательность канонического
      const known = data.filter((t) => canonical.has(t));
      const positions = known.map((t) => spec.order.indexOf(t));
      for (let i = 1; i < positions.length; i++) {
        if (positions[i] < positions[i - 1]) {
          errors.push(`${tag}: '${known[i]}' стоит после '${known[i - 1]}', в таблице — наоборот`);
          break;
        }
      }
      checkMissing(tag, new Set(known), exclude);
      continue;
    }

    if (entry.kind === 'dir') {
      seen.push({ tag, count: data.length });
      const dirNames = new Set(spec.dirOf.values());
      for (const [type, dir] of data) {
        const asDir = entry.keyMayBeDir && dirNames.has(type);
        if (!canonical.has(type) && !asDir) {
          errors.push(`${tag}: тип '${type}' отсутствует в таблице спецификации`);
          continue;
        }
        const want = asDir ? type : spec.dirOf.get(type);
        if (dir !== want) errors.push(`${tag}: '${type}' → '${dir}', в таблице '${want}'`);
      }
      if (!entry.partial) checkMissing(tag, new Set(data.map((d) => d[0])), exclude);
      continue;
    }

    if (entry.kind === 'keys') {
      seen.push({ tag, count: data.length });
      for (const [type] of data) {
        if (!canonical.has(type)) errors.push(`${tag}: ключ '${type}' не является каноническим именем типа`);
      }
      continue;
    }

    // alias: значения обязаны быть каноническими, полнота не требуется
    seen.push({ tag, count: data.length });
    const extra = new Set(entry.extraTargets || []);
    for (const [alias, target] of data) {
      if (!canonical.has(target) && !extra.has(target)) {
        errors.push(`${tag}: алиас '${alias}' ведёт на '${target}', которого нет в таблице`);
      }
    }
  }
}

// Сверка набора GeneratedType с таблицей §2.5. Сравниваем СОСТАВ, не порядок: порядок в типовых
// выгрузках стабилен, но на загрузку не влияет (ишью 64: вставка Characteristic в середину набора
// заимствованной оболочки принята платформой), а карты навыков исторически расходятся порядком.
function checkGenTypes(entry, lang, text, name) {
  const tag = `${entry.skill}.${name} [${lang}]`;
  const data = extractGen(text, name, entry.kind, lang);
  if (data === null) {
    errors.push(`${tag}: карта не найдена — реестр протух`);
    return;
  }
  if (data.size === 0) {
    errors.push(`${tag}: карта извлеклась пустой — сломан разбор формата`);
    return;
  }
  seen.push({ tag, count: data.size });

  const withPrefix = entry.kind === 'gentypes';
  const key = ([prefix, category]) => (withPrefix ? `${prefix}/${category}` : category);

  for (const [type, pairs] of data) {
    const want = spec.genTypes.get(type);
    if (!want) {
      errors.push(`${tag}: тип '${type}' отсутствует в таблице GeneratedType спецификации`);
      continue;
    }
    const have = new Set(pairs.map(key));
    for (const w of want.map(key)) {
      if (!have.has(w)) errors.push(`${tag}: у '${type}' нет '${w}' — в таблице он есть`);
    }
    for (const h of have) {
      if (!want.map(key).includes(h)) errors.push(`${tag}: у '${type}' лишний '${h}' — в таблице его нет`);
    }
  }

  const exclude = entry.exclude || {};
  for (const type of spec.genTypes.keys()) {
    if (data.has(type)) continue;
    if (Object.prototype.hasOwnProperty.call(exclude, type)) {
      if (!exclude[type]) warns.push(`${tag}: тип '${type}' исключён без причины`);
      continue;
    }
    errors.push(`${tag}: тип '${type}' есть в таблице GeneratedType, но отсутствует в карте`);
  }
}

function checkMissing(tag, present, exclude) {
  for (const type of spec.order) {
    if (present.has(type)) continue;
    if (Object.prototype.hasOwnProperty.call(exclude, type)) {
      if (!exclude[type]) warns.push(`${tag}: тип '${type}' исключён без причины`);
      continue;
    }
    errors.push(`${tag}: тип '${type}' есть в таблице, но отсутствует в карте и не объявлен исключением`);
  }
}

// ─── Вывод ──────────────────────────────────────────────────────────────────

if (process.argv.includes('--list')) {
  console.log(`Эталон: ${spec.order.length} типов из docs/1c-configuration-spec.md\n`);
  for (const entry of MAPS) {
    const ports = [entry.py && `py:${entry.py}`, entry.ps1 && `ps1:${entry.ps1}`].filter(Boolean).join('  ');
    console.log(`${entry.skill}  [${entry.kind}]  ${ports}`);
    for (const [type, why] of Object.entries(entry.exclude || {})) {
      console.log(`    исключён ${type} — ${why || 'БЕЗ ПРИЧИНЫ'}`);
    }
  }
  process.exit(0);
}

console.log(`Эталон: ${spec.order.length} типов. Проверено карт: ${seen.length}`);

if (warns.length) {
  console.log(`\nДолг — исключения без причины (${warns.length}):`);
  for (const w of warns) console.log(`  [WARN] ${w}`);
}

if (errors.length) {
  console.log(`\n${errors.length} РАСХОЖДЕНИЙ со спецификацией:`);
  for (const e of errors) console.log(`  [ERROR] ${e}`);
  console.log('\nЭталон типов — таблица «Порядок типов в ChildObjects» в docs/1c-configuration-spec.md.');
  process.exit(1);
}

console.log('\nOK — карты типов согласованы со спецификацией.');
