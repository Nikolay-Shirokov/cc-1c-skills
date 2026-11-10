#!/usr/bin/env node
// f-строки, которые разбирает только Python 3.12+ (PEP 701): та же кавычка или обратный слэш
// внутри {…} — f'{x.get('k')}', f"{'\n'.join(a)}". На 3.12+ это валидно, на 3.9–3.11 модуль не
// импортируется вовсе: SyntaxError, и навык мёртв целиком. Локально гоняем 3.13 — регресс такое
// не видит; ловит только запуск на macOS с системным Python 3.9. Так в 2026-11 замена чтений
// булевых флагов на get_dsl_bool(x, ['k'], …) внутри f'…' уронила бы meta-compile, meta-edit,
// form-compile и form-edit на маке.
//
// Что проверяем: каждый .claude/skills/*/scripts/*.py и scripts/*.py. На 3.12+ — по токенам
// (FSTRING_START/FSTRING_END): строковый литерал внутри поля подстановки с той же кавычкой, что у
// самой f-строки, вложенная f-строка с той же кавычкой, обратный слэш в литерале внутри поля.
// На 3.9–3.11 токенов f-строк нет, зато интерпретатор сам отвергает такой код — там compile().
//
// Запуск: node tests/skills/check-py-fstring-compat.mjs
import { readdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');
const IS_WIN = process.platform === 'win32';
const PY = process.env.PYTHON || (IS_WIN ? 'python' : 'python3');

const PY_CHECK = String.raw`
import io, json, sys, tokenize

def quote_of(t):
    s = t.lstrip('rRbBuUfF')
    return s[:3] if s[:3] in ('"""', "'''") else s[:1]

def scan_tokens(src):
    found, stack = [], []
    for t in tokenize.generate_tokens(io.StringIO(src).readline):
        if t.type == tokenize.FSTRING_START:
            if stack and stack[-1][1] > 0 and quote_of(t.string) == stack[-1][0]:
                found.append((t.start[0], 'nested f-string reuses the outer quote'))
            stack.append([quote_of(t.string), 0])
        elif t.type == tokenize.FSTRING_END:
            stack.pop()
        elif stack:
            if t.type == tokenize.OP and t.string == '{':
                stack[-1][1] += 1
            elif t.type == tokenize.OP and t.string == '}':
                stack[-1][1] -= 1
            elif t.type == tokenize.STRING and stack[-1][1] > 0:
                if quote_of(t.string) == stack[-1][0]:
                    found.append((t.start[0], 'string literal reuses the outer f-string quote'))
                if '\\' in t.string:
                    found.append((t.start[0], 'backslash inside an f-string replacement field'))
    return found

out = []
modern = sys.version_info >= (3, 12)
for path in sys.argv[1:]:
    src = open(path, encoding='utf-8-sig').read()
    if modern:
        for line, msg in scan_tokens(src):
            out.append({'file': path, 'line': line, 'msg': msg})
    else:
        try:
            compile(src, path, 'exec')
        except SyntaxError as e:
            out.append({'file': path, 'line': e.lineno or 0, 'msg': 'SyntaxError: ' + str(e.msg)})
print(json.dumps({'modern': modern, 'found': out}))
`;
const files = [];
const ROOT_SCRIPTS = join(ROOT, 'scripts');
if (existsSync(ROOT_SCRIPTS)) {
  for (const file of readdirSync(ROOT_SCRIPTS)) {
    if (file.endsWith('.py')) files.push(join(ROOT_SCRIPTS, file));
  }
}
for (const skill of readdirSync(SKILLS)) {
  const scriptsDir = join(SKILLS, skill, 'scripts');
  if (!existsSync(scriptsDir)) continue;
  for (const file of readdirSync(scriptsDir)) {
    if (file.endsWith('.py')) files.push(join(scriptsDir, file));
  }
}
const r = spawnSync(PY, ['-', ...files], { input: PY_CHECK, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
if (r.error || r.status !== 0) {
  console.log(`[ERROR] не удалось запустить ${PY}: ${r.error?.message || r.stderr}`);
  console.log('Укажите интерпретатор через переменную окружения PYTHON.');
  process.exit(1);
}
const res = JSON.parse(r.stdout);
const rel = p => relative(ROOT, p).replace(/\\/g, '/');
if (res.found.length) {
  console.log(`${res.found.length} РАСХОЖДЕНИЙ:`);
  for (const x of res.found) console.log(`  [ERROR] ${rel(x.file)}:${x.line}: ${x.msg} — на Python 3.9–3.11 SyntaxError`);
  console.log('\nВнутри {…} — другая кавычка, чем у самой f-строки; выражение с \\ — вынести в переменную.');
  process.exit(1);
}
console.log(`Проверено файлов: ${files.length} (${res.modern ? 'по токенам, Python 3.12+' : 'compile(), Python < 3.12'})`);
console.log('OK — f-строки разбираются на Python 3.9+.');
