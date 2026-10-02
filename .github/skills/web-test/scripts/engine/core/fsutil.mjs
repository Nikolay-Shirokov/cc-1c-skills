// web-test core/fsutil v1.0 — удаление и копирование, устойчивые к не-ASCII путям на Windows.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

// ─── fsutil:begin ───────────────────────────────────────────────────────────
// Ниже этого маркера файл побайтно совпадает со второй копией. Расхождение ловит
// tests/skills/check-nonascii-fs.mjs. Правку вносим в обе копии сразу.

import { cpSync, copyFileSync, existsSync, lstatSync, mkdirSync, readdirSync,
         rmSync, rmdirSync, unlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';

// На Windows fs.rmSync и fs.cpSync ломаются, когда не-ASCII символы есть в САМОМ аргументе
// пути (nodejs/node#61067, апстрим открыт). Снято на стенде из восьми сборок:
//
//   сборка                         rmSync   cpSync → приёмник   cpSync ← источник
//   22.15.1                        ок       ок                  ок
//   22.18.0 … 22.23.2 (LTS Jod)    ок       молча ничего        краш 0xC0000409
//   24.12.0, 24.13.0               молча    молча ничего        краш
//   24.14.0                        ок       молча ничего        краш
//   24.15.0, 24.19.0, 25.9.0, 26.7.0   ок   ок                  ок
//
// Это НЕ обход одного старого релиза: ветка 22 LTS сломана до сих пор — фикс приехал в
// fs-слой Node 24.15 и в 22.x не бэкпортирован, а README проекта рекомендует «Node.js 18+».
// Зависимость не монотонна по версиям (24.14 чинит rmSync, но не cpSync), поэтому гард по
// номеру версии невозможен в принципе: решает только сам путь. Снимать гард можно, лишь
// когда исправной станет вся поддерживаемая линейка, а не текущая машина разработчика.
//
// mkdirSync, readdirSync, lstatSync, existsSync, copyFileSync (включая перезапись),
// unlinkSync, rmdirSync с не-ASCII исправны на ВСЕХ сломанных сборках — на них и стоит
// ручной обход. Асинхронные fs.promises.rm/cp не затронуты.

const NON_ASCII = /[^\x00-\x7F]/;
const RETRY_CODES = new Set(['EBUSY', 'EPERM', 'ENOTEMPTY', 'EMFILE']);

// Проверяем РАЗРЕШЁННЫЙ путь, а не строку аргумента: относительный ASCII-аргумент при
// не-ASCII cwd платформа роняет так же молча, а по строке аргумента это не видно.
export function pathIsUnsafe(p) {
  // Тест-шов только для check-nonascii-fs.mjs: без него ручной обход никогда не исполняется
  // на macOS/Linux и остаётся непокрытым. В обычном прогоне переменная не задана.
  if (process.env.CC1C_FSUTIL_FORCE_WALK === "1") return true;
  return process.platform === 'win32' && NON_ASCII.test(resolve(p));
}

function sleepSync(ms) {
  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withRetrySync(fn, maxRetries, retryDelay) {
  for (let attempt = 0; ; attempt++) {
    try { return fn(); }
    catch (e) {
      if (attempt >= maxRetries || !RETRY_CODES.has(e.code)) throw e;
      sleepSync(retryDelay);
    }
  }
}

// Симлинк или junction на каталог: unlinkSync на нём даёт EPERM, снимается rmdirSync.
// Внутрь не заходим — rmSync тоже сносит саму ссылку, а не её цель.
function removeLeafSync(p) {
  try { unlinkSync(p); }
  catch (e) {
    if (e.code !== 'EPERM' && e.code !== 'EISDIR') throw e;
    rmdirSync(p);
  }
}

function removeTreeWalkSync(dir, maxRetries, retryDelay) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const child = join(dir, entry.name);
    if (entry.isDirectory()) removeTreeWalkSync(child, maxRetries, retryDelay);
    else withRetrySync(() => removeLeafSync(child), maxRetries, retryDelay);
  }
  withRetrySync(() => rmdirSync(dir), maxRetries, retryDelay);
}

// Семантика rm -rf: файл, каталог или отсутствующий путь. opts.maxRetries / opts.retryDelay
// работают на обоих путях — на быстром их принимает сам rmSync, на ручном обходе повторяем сами.
export function removePathSync(target, opts = {}) {
  const { maxRetries = 0, retryDelay = 100 } = opts;

  if (!pathIsUnsafe(target)) {
    rmSync(target, { recursive: true, force: true, maxRetries, retryDelay });
    // Тихий отказ ровно здесь и есть болезнь: подтверждаем результат одним existsSync.
    if (!existsSync(target)) return;
  } else if (!existsSync(target)) {
    return;
  }

  if (lstatSync(target).isDirectory()) removeTreeWalkSync(target, maxRetries, retryDelay);
  else withRetrySync(() => removeLeafSync(target), maxRetries, retryDelay);

  if (existsSync(target)) throw new Error(`Не удалось удалить путь: ${target}`);
}

function copyTreeWalkSync(src, dest) {
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(src, { withFileTypes: true })) {
    const from = join(src, entry.name);
    const to = join(dest, entry.name);
    // Перезаписываем безусловно — как cpSync с дефолтным force: true.
    if (entry.isDirectory()) copyTreeWalkSync(from, to);
    else copyFileSync(from, to);
  }
}

// Рекурсивная копия КАТАЛОГА с перезаписью. Для одиночного файла хватает copyFileSync:
// он не затронут и работает с не-ASCII на всех сборках.
export function copyTreeSync(src, dest) {
  if (!pathIsUnsafe(src) && !pathIsUnsafe(dest)) {
    // Ошибки не глотаем: настоящий ENOENT/EACCES должен долететь до вызывающего.
    cpSync(src, dest, { recursive: true });
    return;
  }
  copyTreeWalkSync(src, dest);
}
