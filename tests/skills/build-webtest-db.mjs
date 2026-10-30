#!/usr/bin/env node
// build-webtest-db v0.3 — Собирает синтетическую web-test конфигурацию в постоянные пути
// и накатывает её в зарегистрированную базу `webtest` (см. .v8-project.json).
//
// Двойной режим:
//   - CLI: node tests/skills/build-webtest-db.mjs [--runtime ...] [--skip-platform]
//   - Module: import { runSteps, execSkill, getProjectInfo, ... } from './build-webtest-db.mjs'
//
// CLI:
//   node tests/skills/build-webtest-db.mjs                 # пересобрать с нуля
//   node tests/skills/build-webtest-db.mjs --runtime python
//   node tests/skills/build-webtest-db.mjs --skip-platform # только XML, без db-create/load/update
//
// После завершения база готова к /web-publish + web-test сессии.

import { execFile } from 'child_process';
import { existsSync, mkdirSync, unlinkSync, readFileSync, writeFileSync } from 'fs';
import { join, resolve, dirname } from 'path';
// fs.rmSync/fs.cpSync напрямую не зовём: на Windows они молча ничего не делают,
// когда в пути есть не-ASCII символы. Подробности и таблица сборок — в самом модуле.
import { removePathSync } from '../common/fsutil.mjs';
import { fileURLToPath, pathToFileURL } from 'url';

const __filename = fileURLToPath(import.meta.url);
const ROOT      = dirname(__filename);
const REPO_ROOT = resolve(ROOT, '../..');
const SKILLS    = resolve(REPO_ROOT, '.claude/skills');

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Reads .v8-project.json and locates webtest registration.
 * @returns {{ v8path: string, v8exe: string, webtestDb: object, configSrc: string, dbPath: string }}
 */
export function getProjectInfo() {
  const projectFile = join(REPO_ROOT, '.v8-project.json');
  if (!existsSync(projectFile)) throw new Error('.v8-project.json not found');
  const proj = JSON.parse(readFileSync(projectFile, 'utf8'));
  const webtestDb = proj.databases?.find(d => d.id === 'webtest');
  if (!webtestDb) throw new Error('Database "webtest" not registered in .v8-project.json');
  const v8path  = proj.v8path;
  const v8exe   = join(v8path, '1cv8.exe');
  const dbPath  = webtestDb.path;
  const configSrc = resolve(REPO_ROOT, webtestDb.configSrc);
  return { v8path, v8exe, webtestDb, configSrc, dbPath };
}

/**
 * Resolves a skill script path to an absolute file (chooses .ps1 or .py based on runtime).
 */
export function resolveScript(scriptRelPath, runtime = 'powershell') {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const full = join(SKILLS, scriptRelPath + ext);
  if (!existsSync(full)) throw new Error(`Script not found: ${full}`);
  return full;
}

/**
 * Executes a single skill script with provided arguments.
 * @returns {Promise<string>} stdout
 */
export function execSkill(scriptPath, args, runtime = 'powershell') {
  return new Promise((res, rej) => {
    const cmd = runtime === 'python'
      ? [process.env.PYTHON || 'python', [scriptPath, ...args]]
      : ['powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args]];
    execFile(cmd[0], cmd[1], { encoding: 'utf8', timeout: 120_000, cwd: REPO_ROOT }, (err, stdout, stderr) => {
      if (err) {
        rej(new Error(stderr?.trim() || stdout?.trim() || err.message));
      } else {
        res(stdout);
      }
    });
  });
}

/**
 * Replaces {workDir}/{v8path}/{dbPath} placeholders in a string value.
 */
export function replacePlaceholders(s, paths) {
  return String(s)
    .replace('{workDir}', paths.workDir ?? '')
    .replace('{v8path}',  paths.v8path  ?? '')
    .replace('{dbPath}',  paths.dbPath  ?? '');
}

/**
 * Executes an array of build steps.
 *
 * Each step: { name, script?, args?, input?, writeFile?, content? }
 *   - writeFile: write content to a file (relative to workDir or absolute), skip script call
 *   - script: relative path under .claude/skills (without extension)
 *   - args: { '-Flag': value | true }, value may contain {workDir}/{v8path}/{dbPath}/{inputFile}
 *   - input: JSON object written to __input.json (referenced by {inputFile} in args)
 *
 * @param {Array} steps
 * @param {{ workDir: string, v8path: string, dbPath: string }} paths
 * @param {string} runtime  'powershell' | 'python'
 * @param {(line: string) => void} log
 * @returns {Promise<{ ok: boolean, elapsed: number, failedAt?: number }>}
 */
export async function runSteps(steps, paths, runtime, log = console.log) {
  const t0 = Date.now();
  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    const stepT0 = Date.now();

    if (step.writeFile) {
      try {
        const target = replacePlaceholders(step.writeFile, paths);
        const abs = target.includes(':') || target.startsWith('/') ? target : join(paths.workDir, target);
        mkdirSync(dirname(abs), { recursive: true });
        writeFileSync(abs, step.content ?? '', 'utf8');
        const ms = Date.now() - stepT0;
        log(`  [${i + 1}/${steps.length}] OK  ${step.name}  (${(ms / 1000).toFixed(1)}s)`);
      } catch (e) {
        log(`  [${i + 1}/${steps.length}] FAIL ${step.name}: ${e.message}`);
        return { ok: false, elapsed: (Date.now() - t0) / 1000, failedAt: i };
      }
      continue;
    }

    let inputFile = null;
    if (step.input) {
      inputFile = join(paths.workDir, '__input.json');
      writeFileSync(inputFile, JSON.stringify(step.input, null, 2), 'utf8');
    }

    const script = resolveScript(step.script, runtime);
    const args = [];
    for (const [flag, value] of Object.entries(step.args || {})) {
      args.push(flag);
      if (value === true) continue;
      let v = String(value).replace('{inputFile}', inputFile || '');
      v = replacePlaceholders(v, paths);
      args.push(v);
    }

    try {
      await execSkill(script, args, runtime);
      if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);
      const ms = Date.now() - stepT0;
      log(`  [${i + 1}/${steps.length}] OK  ${step.name}  (${(ms / 1000).toFixed(1)}s)`);
    } catch (e) {
      if (inputFile && existsSync(inputFile)) unlinkSync(inputFile);
      log(`  [${i + 1}/${steps.length}] FAIL ${step.name}`);
      log(`    ${e.message.split('\n').join('\n    ').substring(0, 1500)}`);
      return { ok: false, elapsed: (Date.now() - t0) / 1000, failedAt: i };
    }
  }
  return { ok: true, elapsed: (Date.now() - t0) / 1000 };
}

/**
 * Returns the standard platform load steps (db-create + db-load-xml + db-update).
 */
export function platformLoadSteps() {
  return [
    {
      name: 'db-create: создание файловой ИБ',
      script: 'db-create/scripts/db-create',
      args: { '-V8Path': '{v8path}', '-InfoBasePath': '{dbPath}' },
    },
    {
      name: 'db-load-xml: загрузка конфигурации',
      script: 'db-load-xml/scripts/db-load-xml',
      args: { '-V8Path': '{v8path}', '-InfoBasePath': '{dbPath}', '-ConfigDir': '{workDir}' },
    },
    {
      name: 'db-update: обновление БД',
      script: 'db-update/scripts/db-update',
      args: { '-V8Path': '{v8path}', '-InfoBasePath': '{dbPath}' },
    },
  ];
}

/**
 * Imports the build-webtest-config.test.mjs steps array.
 */
export async function loadBuildSteps() {
  const buildModule = await import(pathToFileURL(join(ROOT, 'integration/build-webtest-config.test.mjs')).href);
  return buildModule.steps;
}

// ── CLI ────────────────────────────────────────────────────────────────────────

async function runCli() {
  const argv = process.argv.slice(2);
  const opts = { runtime: 'powershell', skipPlatform: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--runtime' && argv[i + 1]) { opts.runtime = argv[++i]; continue; }
    if (a === '--skip-platform') { opts.skipPlatform = true; continue; }
    if (a === '-h' || a === '--help') {
      console.log('Usage: build-webtest-db.mjs [--runtime powershell|python] [--skip-platform]');
      process.exit(0);
    }
  }

  const { v8path, v8exe, configSrc, dbPath } = getProjectInfo();

  if (!opts.skipPlatform && !existsSync(v8exe)) {
    console.error(`1cv8.exe not found at ${v8exe}`);
    process.exit(1);
  }

  console.log(`[build-webtest-db] configSrc: ${configSrc}`);
  console.log(`[build-webtest-db] dbPath:    ${dbPath}`);
  console.log(`[build-webtest-db] runtime:   ${opts.runtime}`);
  console.log('');

  if (existsSync(configSrc)) {
    console.log(`Removing existing configSrc...`);
    removePathSync(configSrc, { maxRetries: 5, retryDelay: 200 });
  }
  mkdirSync(configSrc, { recursive: true });

  if (!opts.skipPlatform && existsSync(dbPath)) {
    console.log(`Removing existing IB...`);
    removePathSync(dbPath, { maxRetries: 5, retryDelay: 200 });
  }

  const buildSteps = await loadBuildSteps();
  const platformSteps = opts.skipPlatform ? [] : platformLoadSteps();
  const allSteps = [...buildSteps, ...platformSteps];

  const paths = { workDir: configSrc, v8path, dbPath };
  const result = await runSteps(allSteps, paths, opts.runtime, console.log);

  console.log('');
  if (!result.ok) {
    console.error(`Build FAILED after ${result.elapsed.toFixed(1)}s`);
    process.exit(1);
  }
  console.log(`Build OK (${result.elapsed.toFixed(1)}s)`);
  console.log('');
  console.log(`  configSrc: ${configSrc}`);
  if (!opts.skipPlatform) {
    console.log(`  IB:        ${dbPath}`);
    console.log('');
    console.log(`  Next: /web-publish webtest  →  open in browser`);
  }
}

// CLI guard: run only when invoked directly, not when imported.
const invokedDirectly = process.argv[1]
  ? fileURLToPath(import.meta.url) === resolve(process.argv[1])
  : false;
if (invokedDirectly) {
  runCli().catch(e => {
    console.error(e.message);
    process.exit(1);
  });
}
