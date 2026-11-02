#!/usr/bin/env node
// Анти-дрейф словарей синонимов типов. Навыки автономны, словари продублированы намеренно, поэтому
// нужен гард: если по одному ключу навыки (или порты одного навыка) думают разное, модель получит
// разный XML на один и тот же вход — молча.
//
// Две проверки:
// 1. Пары навыков (эталон → копия). Режим пары:
//    - weak   — копия вправе не знать ключ (её DSL уже), но не вправе понимать известный ключ иначе;
//               отсутствующий ключ печатается справочно (meta-compile → meta-edit);
//    - strict — состав и значения совпадают целиком: DSL у навыков один (form-compile → form-edit).
// 2. Порты одного навыка: словарь .py совпадает со словарём .ps1 (канон) целиком. Так разъехался
//    form-edit: в .ps1 жил короткий словарь, в .py — полный.
//
// Почему не check-inline-drift: тот держит одинаковость ТЕЛА Resolve-TypeStr, а словари у навыков
// разные по составу намеренно (у skd-compile вообще другой канон — decimal/string в нижнем
// регистре). Поэтому skd/mxl сюда не входят: сведение их канона — отдельная задача.
//
// Выход 1 при дрейфе. Запуск: node tests/skills/check-type-synonyms.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Словари под гардом: навык → имя словаря в .ps1 ($script:<имя>["ключ"] = "значение", по записи на
// строку) и в .py (литерал `<имя> = { 'ключ': 'значение', … }`).
const DICTS = {
  'meta-compile': { ps1: 'typeSynonyms', py: 'type_synonyms' },
  'meta-edit': { ps1: 'typeSynonyms', py: 'type_synonyms' },
  'form-compile': { ps1: 'formTypeSynonyms', py: '_FORM_TYPE_SYNONYMS' },
  'form-edit': { ps1: 'formTypeSynonyms', py: '_FORM_TYPE_SYNONYMS' },
};
const PAIRS = [
  { authority: 'meta-compile', copy: 'meta-edit', mode: 'weak' },
  { authority: 'form-compile', copy: 'form-edit', mode: 'strict' },
];

const scriptPath = (skill, ext) => join(ROOT, '.claude', 'skills', skill, 'scripts', `${skill}.${ext}`);
const unescape = (s) => s.replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

function parsePs1(skill) {
  const name = DICTS[skill].ps1;
  const text = readFileSync(scriptPath(skill, 'ps1'), 'utf8');
  const map = new Map();
  const re = new RegExp(`\\$script:${name}\\["([^"]+)"\\]\\s*=\\s*"([^"]*)"`, 'g');
  let m;
  while ((m = re.exec(text)) !== null) map.set(m[1], m[2]);
  if (map.size === 0) throw new Error(`словарь ${name} не найден в ${skill}.ps1 — реестр протух`);
  return map;
}

// Литерал словаря: от `<имя> = {` до закрывающей `}` в начале строки. Литералы — простые строки
// в одинарных или двойных кавычках; кириллица может быть записана \uXXXX-escape.
function parsePy(skill) {
  const name = DICTS[skill].py;
  const text = readFileSync(scriptPath(skill, 'py'), 'utf8').replace(/\r\n/g, '\n');
  const starts = [...text.matchAll(new RegExp(`^${name.replace(/[$]/g, '\\$')} = \\{$`, 'gm'))];
  if (starts.length !== 1) throw new Error(`словарь ${name} в ${skill}.py: литералов ${starts.length}, ждём ровно один`);
  const from = starts[0].index;
  const end = text.indexOf('\n}', from);
  const body = text.slice(from, end);
  const map = new Map();
  const re = /(['"])((?:(?!\1).)*)\1\s*:\s*(['"])((?:(?!\3).)*)\3/g;
  let m;
  while ((m = re.exec(body)) !== null) map.set(unescape(m[2]), unescape(m[4]));
  return map;
}

let drift = 0;

for (const { authority, copy, mode } of PAIRS) {
  const a = parsePs1(authority);
  const c = parsePs1(copy);
  for (const [key, value] of c) {
    if (!a.has(key)) {
      if (mode === 'strict') { console.log(`DRIFT  ${copy}."${key}" нет в ${authority}`); drift++; }
      else console.log(`INFO   ${copy}."${key}" нет в ${authority} (проверьте ключ)`);
      continue;
    }
    if (a.get(key) !== value) {
      console.log(`DRIFT  ${copy}."${key}" = "${value}"  !=  ${authority} "${a.get(key)}"`);
      drift++;
    }
  }
  const missing = [...a.keys()].filter((k) => !c.has(k));
  if (missing.length) {
    const list = `${missing.slice(0, 8).join(', ')}${missing.length > 8 ? ' …' : ''}`;
    if (mode === 'strict') { console.log(`DRIFT  ${copy} не знает ${missing.length} ключ(ей) ${authority}: ${list}`); drift += missing.length; }
    else console.log(`INFO   ${copy} не знает ${missing.length} ключ(ей) авторитета: ${list}`);
  }
  console.log(`${authority} → ${copy} (${mode}): ${a.size} / ${c.size}`);
}

for (const skill of Object.keys(DICTS)) {
  const ps = parsePs1(skill);
  const py = parsePy(skill);
  let own = 0;
  for (const [key, value] of ps) {
    if (!py.has(key)) { console.log(`DRIFT  ${skill}.py не знает "${key}" из .ps1`); own++; }
    else if (py.get(key) !== value) { console.log(`DRIFT  ${skill}.py "${key}" = "${py.get(key)}"  !=  .ps1 "${value}"`); own++; }
  }
  for (const key of py.keys()) {
    if (!ps.has(key)) { console.log(`DRIFT  ${skill}.py знает "${key}", которого нет в .ps1`); own++; }
  }
  drift += own;
  console.log(`${skill}: .ps1 ${ps.size} / .py ${py.size}${own ? ` — расхождений ${own}` : ''}`);
}

console.log(drift === 0
  ? 'OK — словари типов не разошлись'
  : `\n${drift} DRIFT(s) — свести к эталону (пары) и к .ps1 (порты).`);
process.exit(drift ? 1 : 0);
