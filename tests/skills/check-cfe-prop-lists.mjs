#!/usr/bin/env node
// Анти-дрейф групп свойств заимствованного объекта: cfe-borrow (актуализация) и cfe-validate
// (проверка 18) делят их на контролируемые (приводятся к источнику / сверяются по режимам) и
// дополнения (список расширения сливается со списком источника — не трогаются / не сверяются).
// Списки продублированы в четырёх файлах (два навыка × два порта). Разойдутся — навык освежит
// свойство, о котором валидатор только предупредит, или наоборот.
//
// Запуск: node tests/skills/check-cfe-prop-lists.mjs
// Выход 1 при расхождении.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const SKILLS = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '.claude', 'skills');
const FILES = [
  ['cfe-borrow', 'cfe-borrow.ps1'], ['cfe-borrow', 'cfe-borrow.py'],
  ['cfe-validate', 'cfe-validate.ps1'], ['cfe-validate', 'cfe-validate.py'],
];
const LISTS = [['controlledProps', 'controlled_props'], ['additiveProps', 'additive_props']];

function extract(text, file, psName, pyName) {
  const re = file.endsWith('.ps1')
    ? new RegExp(`\\$script:${psName}\\s*=\\s*@\\(([^)]*)\\)`)
    : new RegExp(`\\b${pyName}\\s*=\\s*\\[([^\\]]*)\\]`);
  const m = text.match(re);
  if (!m) return null;
  return [...m[1].matchAll(/'([^']*)'/g)].map(x => x[1]);
}

const errors = [];
for (const [psName, pyName] of LISTS) {
  let ref = null, refFile = null;
  for (const [skill, file] of FILES) {
    const text = readFileSync(join(SKILLS, skill, 'scripts', file), 'utf8');
    const list = extract(text, file, psName, pyName);
    if (!list) { errors.push(`${file}: список ${file.endsWith('.ps1') ? psName : pyName} не найден`); continue; }
    if (!ref) { ref = list; refFile = file; continue; }
    if (list.join(',') !== ref.join(',')) {
      errors.push(`${psName}: ${file} расходится с ${refFile}\n    ${refFile}: ${ref.join(', ')}\n    ${file}: ${list.join(', ')}`);
    }
  }
  if (ref) console.log(`  ${psName}: ${ref.length} свойств — совпадает в ${FILES.length} файлах`);
}
if (errors.length) {
  for (const e of errors) console.log(`[ERROR] ${e}`);
  process.exit(1);
}
console.log('OK — группы свойств заимствованного совпадают в cfe-borrow и cfe-validate (оба порта).');
