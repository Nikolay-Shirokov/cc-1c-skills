#!/usr/bin/env node
// Анти-дрейф enum-allowlist-ов: сверяет продублированные списки допустимых значений перечислений
// meta-compile (АВТОРИТЕТ) ↔ meta-validate ↔ meta-edit. Навыки автономны (allowlist-ы копируются
// намеренно), поэтому нужен гард от расхождений значений (напр. HierarchyItemsOnly vs HierarchyOfItems).
// Парсит .ps1 (канонический порт). Выход 1 при дрейфе. Запуск: node tests/skills/check-enum-drift.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Извлечь PS1-хэштейбл по имени переменной, распарсить "Prop" = @("v1","v2", ...)
function parsePs1EnumMap(file, varName) {
  const text = readFileSync(join(ROOT, file), 'utf8');
  const at = text.indexOf(varName);
  if (at < 0) throw new Error(`${varName} not found in ${file}`);
  let i = text.indexOf('@{', at) + 2, depth = 1, end = i;
  while (i < text.length && depth > 0) {
    const c = text[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
    i++;
  }
  const block = text.slice(text.indexOf('@{', at) + 2, end);
  const map = {};
  const re = /"([\wА-Яа-яЁё]+)"\s*=\s*@\(([^)]*)\)/g;
  let m;
  while ((m = re.exec(block)) !== null) {
    map[m[1]] = [...m[2].matchAll(/"([^"]*)"/g)].map(v => v[1]);
  }
  return map;
}

const compile  = parsePs1EnumMap('.claude/skills/meta-compile/scripts/meta-compile.ps1', '$script:validEnumValues');
const validate = parsePs1EnumMap('.claude/skills/meta-validate/scripts/meta-validate.ps1', '$validPropertyValues');
const edit     = parsePs1EnumMap('.claude/skills/meta-edit/scripts/meta-edit.ps1', '$script:validEnumValues');

const eq = (a, b) => a.length === b.length && [...a].sort().join('|') === [...b].sort().join('|');

let drift = 0;
for (const [name, map] of [['meta-validate', validate], ['meta-edit', edit]]) {
  for (const prop of Object.keys(map)) {
    if (compile[prop] && !eq(map[prop], compile[prop])) {
      console.log(`DRIFT  ${name}.${prop}: [${map[prop].join(', ')}]  !=  meta-compile [${compile[prop].join(', ')}]`);
      drift++;
    }
  }
}
// Информационно: свойства в валидаторе/редакторе, которых НЕТ в авторитете (возможен опечатка-ключ или устаревшее)
for (const [name, map] of [['meta-validate', validate], ['meta-edit', edit]]) {
  for (const prop of Object.keys(map)) {
    if (!compile[prop]) console.log(`INFO   ${name}.${prop} нет в meta-compile.validEnumValues (проверьте ключ)`);
  }
}
console.log(drift === 0 ? 'OK — нет дрейфа значений enum-allowlist vs meta-compile' : `\n${drift} DRIFT(s) — свести к meta-compile.`);
process.exit(drift ? 1 : 0);
