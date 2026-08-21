// web-test core/fsutil v1.0 — надёжное удаление каталогов для движка.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { rmSync, unlinkSync, rmdirSync, readdirSync, existsSync } from 'fs';
import { join } from 'path';

// Node 24.x на Windows: fs.rmSync молча не делает ничего, если путь в аргументе
// содержит не-ASCII символы — например кириллическое имя пользователя в %TEMP%
// (nodejs/node#61067, проверено на v24.12.0). Ни исключения, ни удаления:
// временные профили Chrome и каталоги TTS копятся с каждым запуском.
// unlinkSync/rmdirSync не затронуты, поэтому такие пути вообще не отдаём rmSync,
// а удаляем ручным обходом; после быстрого пути дополнительно проверяем результат.
const nonAsciiPathUnsafe = (p) => process.platform === 'win32' && /[^\x00-\x7F]/.test(p);

function rmTreeWalkSync(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) rmTreeWalkSync(p);
    else unlinkSync(p);
  }
  rmdirSync(dir);
}

export function rmrfSync(dir) {
  if (!nonAsciiPathUnsafe(dir)) rmSync(dir, { recursive: true, force: true });
  if (!existsSync(dir)) return;
  rmTreeWalkSync(dir);
  if (existsSync(dir)) throw new Error(`Failed to remove directory: ${dir}`);
}
