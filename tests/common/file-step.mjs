// Шаги preRun над файлами workDir — общие для runner.mjs и verify-snapshots.mjs.
//   { "editFile": "path", "replace": "было", "with": "стало", "all": true }  — замена подстроки
//     (первое вхождение, с "all" — все); подстроки нет — ошибка: кейс не должен молча
//     проверять неизменённый вход. BOM и переводы строк файла сохраняются.
//   { "movePath": { "from": "a", "to": "b" } } — переименовать файл или каталог
//     (так выражается переименование объекта в источнике).
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';

export function runFileStep(workDir, step) {
  if (step.editFile) {
    const abs = join(workDir, step.editFile);
    const txt = readFileSync(abs, 'utf8');
    if (!txt.includes(step.replace)) throw new Error(`editFile ${step.editFile}: not found: ${step.replace}`);
    const out = step.all ? txt.split(step.replace).join(step.with ?? '') : txt.replace(step.replace, () => step.with ?? '');
    writeFileSync(abs, out, 'utf8');
    return `editFile ${step.editFile}`;
  }
  if (step.movePath) {
    const to = join(workDir, step.movePath.to);
    mkdirSync(dirname(to), { recursive: true });
    renameSync(join(workDir, step.movePath.from), to);
    return `movePath ${step.movePath.from} -> ${step.movePath.to}`;
  }
  return null;
}
