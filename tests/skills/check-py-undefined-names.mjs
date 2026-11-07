#!/usr/bin/env node
// Python не проверяет имена до выполнения: ссылка на необъявленную переменную, потерянный import
// или константу падает NameError только когда до неё дойдёт управление. В редкой ветке это годами
// выглядит как рабочий код. А под `except Exception: pass` не падает вообще — ветка молча
// становится no-op. Так set-property в subsystem-edit падал на Comment/Picture (#140, prop_key),
// form-edit — на userSettingID "auto" (потерян import uuid), а stub-db-create молча игнорировал
// v8args/ibcmdargs проекта (потерян import json, ошибку глотал except).
//
// В .ps1 у этого класса свой гард (check-ps-define-before-call): там другая природа ошибки.
//
// Что проверяем: в каждом .claude/skills/*/scripts/*.py и scripts/*.py каждая ссылка на глобальное имя (из
// модуля, функции, класса, лямбды, comprehension) должна разрешаться в имя, связанное на уровне
// модуля (присваивание, import, def, class, `global` + присваивание в функции), или в builtins.
// Разбор — stdlib symtable, без сторонних пакетов: гард работает на любом Python 3.9+.
//
// Запуск: node tests/skills/check-py-undefined-names.mjs
import { readdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');
const IS_WIN = process.platform === 'win32';
const PY = process.env.PYTHON || (IS_WIN ? 'python' : 'python3');

const PY_CHECK = String.raw`
import ast, builtins, json, symtable, sys

# Builtins of the running interpreter minus those added after 3.9 - the oldest
# supported runtime (macOS system Python). Otherwise a guard run on 3.13 would
# accept anext()/ExceptionGroup, and the skill would fail with NameError on 3.9.
POST_39 = {
    'aiter', 'anext', 'EncodingWarning',                      # 3.10
    'BaseExceptionGroup', 'ExceptionGroup',                   # 3.11
    'PythonFinalizationError', '_IncompleteInputError',       # 3.13
}
KNOWN = (set(dir(builtins)) - POST_39) | {
    '__file__', '__name__', '__doc__', '__spec__', '__loader__', '__package__',
    '__builtins__', '__path__', '__cached__', '__annotations__',
}

def walk(table):
    yield table
    for child in table.get_children():
        yield from walk(child)

out = []
for path in sys.argv[1:]:
    with open(path, encoding='utf-8-sig') as f:
        src = f.read()
    try:
        top = symtable.symtable(src, path, 'exec')
        tree = ast.parse(src, path)
    except SyntaxError as e:
        out.append({'file': path, 'error': 'SyntaxError: %s (line %s)' % (e.msg, e.lineno)})
        continue
    if any(isinstance(n, ast.ImportFrom) and any(a.name == '*' for a in n.names)
           for n in ast.walk(tree)):
        out.append({'file': path, 'skip': 'from ... import * - names cannot be resolved statically'})
        continue

    bound = set()
    for t in walk(top):
        for s in t.get_symbols():
            is_module = t is top
            if (is_module or s.is_declared_global()) and (
                    s.is_assigned() or s.is_imported() or s.is_namespace() or s.is_parameter()):
                bound.add(s.get_name())

    missing = {}
    for t in walk(top):
        for s in t.get_symbols():
            name = s.get_name()
            if not s.is_referenced() or name in bound or name in KNOWN:
                continue
            if t is top or s.is_global():
                missing.setdefault(name, set()).add(t.get_name())

    if not missing:
        continue
    # Lines only from the scopes where the name is unresolved (symtable names scopes like
    # the def/class itself, 'top' for the module, 'lambda'/'listcomp'... for anonymous ones).
    # Decorators, defaults, annotations and class bases are evaluated in the
    # enclosing scope, only the body belongs to the def/class/lambda itself.
    lines = {}
    def visit(node, scope):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            a = node.args
            outer = list(a.defaults) + [d for d in a.kw_defaults if d is not None]
            if not isinstance(node, ast.Lambda):
                outer += list(node.decorator_list)
                params = a.posonlyargs + a.args + a.kwonlyargs + [x for x in (a.vararg, a.kwarg) if x]
                outer += [x.annotation for x in params if x.annotation is not None]
                if node.returns is not None:
                    outer.append(node.returns)
            for n in outer:
                visit(n, scope)
            inner = 'lambda' if isinstance(node, ast.Lambda) else node.name
            for n in (node.body if isinstance(node.body, list) else [node.body]):
                visit(n, inner)
            return
        if isinstance(node, ast.ClassDef):
            for n in node.decorator_list + node.bases + [k.value for k in node.keywords]:
                visit(n, scope)
            for n in node.body:
                visit(n, node.name)
            return
        if (isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
                and node.id in missing and scope in missing[node.id]):
            lines.setdefault(node.id, set()).add(node.lineno)
        for child in ast.iter_child_nodes(node):
            visit(child, scope)
    for n in tree.body:
        visit(n, top.get_name())
    unplaced = {name for name in missing if name not in lines}
    if unplaced:
        # Fallback (e.g. comprehension scopes): any Load of the name.
        for n in ast.walk(tree):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id in unplaced:
                lines.setdefault(n.id, set()).add(n.lineno)
    for name in sorted(missing):
        out.append({'file': path, 'name': name,
                    'scopes': sorted(missing[name]),
                    'lines': sorted(lines.get(name, []))})

print(json.dumps(out))
`;

// Навыки и корневые scripts/*.py (switch*.py — установка и переключение рантайма).
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

const results = JSON.parse(r.stdout);
const rel = p => relative(ROOT, p).replace(/\\/g, '/');
const errors = [];
for (const x of results) {
  if (x.skip) { console.log(`  [SKIP] ${rel(x.file)}: ${x.skip}`); continue; }
  if (x.error) { errors.push(`${rel(x.file)}: ${x.error}`); continue; }
  const where = x.lines.length ? `:${x.lines.join(',')}` : '';
  errors.push(`${rel(x.file)}${where}: имя '${x.name}' не определено (в ${x.scopes.join(', ')}) — NameError при выполнении`);
}

if (errors.length) {
  console.log(`${errors.length} РАСХОЖДЕНИЙ:`);
  for (const e of errors) console.log(`  [ERROR] ${e}`);
  console.log('\nОбъявите имя (import, константа, присваивание) или уберите мёртвый код.');
  process.exit(1);
}

console.log(`Проверено файлов: ${files.length}`);
console.log('OK — все имена в .py разрешаются.');
