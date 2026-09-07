#!/usr/bin/env node
// Анти-дрейф словарей типов: meta-compile (АВТОРИТЕТ) ↔ meta-edit. Навыки автономны, словари
// продублированы намеренно, поэтому нужен гард от расхождения значений: если по одному ключу
// навыки думают разное, модель получит разный XML на один и тот же вход — молча.
//
// Инвариант СЛАБЫЙ по составу и СТРОГИЙ по значению: meta-edit вправе не знать ключ (его DSL уже),
// но не вправе понимать известный ключ иначе. Отсутствующий ключ печатается справочно.
//
// Почему не check-inline-drift: тот держит одинаковость ТЕЛА Resolve-TypeStr, а словари у навыков
// разные по составу намеренно (у skd-compile вообще другой канон — decimal/string в нижнем
// регистре). Поэтому skd/form/mxl сюда не входят: сведение их канона — отдельная задача.
//
// Парсит .ps1 (канонический порт). Выход 1 при дрейфе. Запуск: node tests/skills/check-type-synonyms.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// $script:typeSynonyms["ключ"] = "значение" — по одной записи на строку в обоих навыках.
function parsePs1TypeSynonyms(file) {
  const text = readFileSync(join(ROOT, file), 'utf8');
  const map = new Map();
  const re = /\$script:typeSynonyms\["([^"]+)"\]\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(text)) !== null) map.set(m[1], m[2]);
  if (map.size === 0) throw new Error(`словарь typeSynonyms не найден в ${file} — реестр протух`);
  return map;
}

const compile = parsePs1TypeSynonyms('.claude/skills/meta-compile/scripts/meta-compile.ps1');
const edit = parsePs1TypeSynonyms('.claude/skills/meta-edit/scripts/meta-edit.ps1');

let drift = 0;
for (const [key, value] of edit) {
  if (!compile.has(key)) {
    console.log(`INFO   meta-edit."${key}" нет в meta-compile (проверьте ключ)`);
    continue;
  }
  if (compile.get(key) !== value) {
    console.log(`DRIFT  meta-edit."${key}" = "${value}"  !=  meta-compile "${compile.get(key)}"`);
    drift++;
  }
}

const missing = [...compile.keys()].filter(k => !edit.has(k));
if (missing.length) {
  console.log(`INFO   meta-edit не знает ${missing.length} ключ(ей) авторитета: ${missing.slice(0, 8).join(', ')}${missing.length > 8 ? ' …' : ''}`);
}

console.log(drift === 0
  ? `OK — словари типов не разошлись (meta-compile ${compile.size}, meta-edit ${edit.size})`
  : `\n${drift} DRIFT(s) — свести к meta-compile.`);
process.exit(drift ? 1 : 0);
