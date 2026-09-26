#!/usr/bin/env node
// Инвариант: PS-скрипты навыков не опираются на окружение, которое есть только в Windows, а
// скрипты, запускающие платформу, не могут завершиться с кодом 0 из-за необработанной ошибки.
//
// Issue #106: вне Windows `$env:TEMP` равна $null. `Join-Path $env:TEMP …` внутри
// `try { } finally { }` без catch — ошибка привязки параметра прерывает try, отрабатывает
// finally, и скрипт выходит с кодом 0: платформа не запускалась, постусловие не проверялось.
// db-create/db-dump-*/db-load-xml рапортовали «успех», ничего не сделав.
//
// Два правила:
//   1. `$env:TEMP` / `$env:TMP` в .ps1 навыков запрещены — временный каталог берётся через
//      [IO.Path]::GetTempPath() (на Windows тот же путь, вне Windows — TMPDIR или /tmp).
//   2. .ps1 в db-*/epf-*, запускающий платформу (Invoke-PlatformProcess / Start-Process),
//      держит верхнеуровневый `trap { … exit 1 }`: любая необработанная ошибка — код 1.
//      Рантайм-кейсом это не поймать: после правила 1 штатного способа уронить скрипт нет.
//
// Почему гард, а не кейс с урезанным окружением: libuv на Windows возвращает TEMP в окружение
// дочернего процесса, даже если его убрали (обязательная переменная), — «TEMP нет» из Node на
// Windows не выразить.
//
// Запуск: node tests/skills/check-ps-portability.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

const errors = [];
let checked = 0;
let trapped = 0;

for (const skill of readdirSync(SKILLS)) {
  const dir = join(SKILLS, skill, 'scripts');
  if (!existsSync(dir)) continue;
  for (const file of readdirSync(dir)) {
    if (!file.endsWith('.ps1')) continue;
    checked++;
    const lines = readFileSync(join(dir, file), 'utf8').replace(/^﻿/, '').split(/\r?\n/);
    const code = lines.map((l, i) => ({ l, n: i + 1 })).filter(({ l }) => !l.trimStart().startsWith('#'));

    for (const { l, n } of code) {
      if (/\$env:(TEMP|TMP)\b/i.test(l)) {
        errors.push(`${skill}/${file}:${n}: $env:TEMP/$env:TMP есть только в Windows — `
          + `используйте [IO.Path]::GetTempPath()`);
      }
    }

    if (!/^(db|epf)-/.test(skill)) continue;
    const runsPlatform = code.some(({ l }) => /Invoke-PlatformProcess|Start-Process/.test(l));
    if (!runsPlatform) continue;
    trapped++;
    if (!code.some(({ l }) => /^trap \{.*\bexit 1\b/.test(l))) {
      errors.push(`${skill}/${file}: запускает платформу, но нет верхнеуровневого `
        + '`trap { … exit 1 }` — необработанная ошибка внутри try/finally даст код 0');
    }
  }
}

console.log(`Проверено .ps1: ${checked}; из них запускают платформу (db-*/epf-*): ${trapped}`);
if (errors.length === 0) {
  console.log('OK — без Windows-only окружения, необработанная ошибка даёт код 1.');
  process.exit(0);
}
console.log(`\n${errors.length} НАРУШЕНИЙ:`);
for (const e of errors) console.log(`  [ERROR] ${e}`);
process.exit(1);
