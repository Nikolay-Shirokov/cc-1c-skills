#!/usr/bin/env node
// verify-snapshots v0.2 — Platform verification of skill test snapshots
// Reruns skill scripts from test-case DSL, then loads into 1C platform.
// Usage: node tests/skills/verify-snapshots.mjs [--skill meta-compile] [--case catalog-basic] [--runtime powershell|python] [--keep] [--verbose]
// Supports: meta-compile, form-compile, form-add, form-edit, skd-compile, skd-edit,
//           role-compile, subsystem-compile, subsystem-edit, mxl-compile, template-add,
//           help-add, cf-init, cf-edit, epf-init, meta-edit, interface-edit,
//           cfe-init, cfe-borrow, cfe-patch-method

import { execFileSync } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, readFileSync, writeFileSync,
         readdirSync, statSync, cpSync } from 'fs';
import { join, resolve, dirname, basename } from 'path';
import { tmpdir } from 'os';

// ─── Paths ──────────────────────────────────────────────────────────────────

const ROOT      = resolve(dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Z]:)/i, '$1'));
const REPO_ROOT = resolve(ROOT, '../..');
const SKILLS    = resolve(REPO_ROOT, '.claude/skills');
const CASES     = resolve(ROOT, 'cases');
const REPORT_DIR = resolve(REPO_ROOT, 'debug/snapshot-verify');

// ─── CLI args ───────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { skill: null, caseName: null, runtime: 'powershell', keep: false, verbose: false };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--skill' && rest[i + 1]) { args.skill = rest[++i]; continue; }
    if (a === '--case' && rest[i + 1]) { args.caseName = rest[++i]; continue; }
    if (a === '--runtime' && rest[i + 1]) { args.runtime = rest[++i]; continue; }
    if (a === '--keep') { args.keep = true; continue; }
    if (a === '--verbose' || a === '-v') { args.verbose = true; continue; }
  }
  return args;
}

// ─── Platform context ───────────────────────────────────────────────────────

function loadV8Context() {
  const projectFile = join(REPO_ROOT, '.v8-project.json');
  if (!existsSync(projectFile)) return null;
  try {
    const proj = JSON.parse(readFileSync(projectFile, 'utf8'));
    const v8bin = proj.v8path;
    const v8exe = v8bin ? (existsSync(join(v8bin, '1cv8.exe')) ? join(v8bin, '1cv8.exe') : null) : null;
    if (!v8exe) return null;
    return { v8path: v8bin, v8exe };
  } catch { return null; }
}

// ─── Script execution ───────────────────────────────────────────────────────

function resolveScript(relPath, runtime) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const full = join(SKILLS, relPath + ext);
  if (!existsSync(full)) throw new Error(`Script not found: ${full}`);
  return full;
}

function execSkill(runtime, scriptRelPath, args, timeout = 60_000, cwd = REPO_ROOT) {
  const scriptPath = resolveScript(scriptRelPath, runtime);
  if (runtime === 'python') {
    return execFileSync(process.env.PYTHON || 'python', [scriptPath, ...args], {
      encoding: 'utf8', timeout, stdio: ['pipe', 'pipe', 'pipe'], cwd,
    });
  }
  return execFileSync('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', scriptPath, ...args
  ], { encoding: 'utf8', timeout, stdio: ['pipe', 'pipe', 'pipe'], cwd });
}

// ─── Dependency resolution ──────────────────────────────────────────────────

const ID = '[\\w\\u0400-\\u04FF]+';

function extractTypeRefs(input) {
  const refs = new Map();
  const json = JSON.stringify(input);

  const refPattern = new RegExp(`(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|ExchangePlan)Ref\\.(${ID})`, 'g');
  let m;
  while ((m = refPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  const directPattern = new RegExp(`(ChartOfAccounts|ChartOfCalculationTypes|ChartOfCharacteristicTypes)\\.(${ID})`, 'g');
  while ((m = directPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  const objPattern = new RegExp(`(Document|Catalog|BusinessProcess|Task|ExchangePlan)Object\\.(${ID})`, 'g');
  while ((m = objPattern.exec(json)) !== null) {
    refs.set(`${m[1]}.${m[2]}`, { type: m[1], name: m[2] });
  }

  const modPattern = new RegExp(`CommonModule\\.(${ID})\\.${ID}`, 'g');
  while ((m = modPattern.exec(json)) !== null) {
    refs.set(`CommonModule.${m[1]}`, { type: 'CommonModule', name: m[1] });
  }

  if (input && input.type === 'ScheduledJob' && input.methodName) {
    const parts = input.methodName.split('.');
    if (parts.length >= 2) {
      refs.set(`CommonModule.${parts[0]}`, { type: 'CommonModule', name: parts[0] });
    }
  }

  return refs;
}

// ─── Structural dependencies ────────────────────────────────────────────────

function getStructuralDeps(input) {
  const deps = [];
  const inputs = Array.isArray(input) ? input : [input];
  if (!inputs[0] || !inputs[0].type) return deps;

  for (const inp of inputs) {
    const regTypePrefix = {
      AccumulationRegister: 'AccumulationRegister',
      AccountingRegister: 'AccountingRegister',
      CalculationRegister: 'CalculationRegister',
    }[inp.type];

    if (regTypePrefix) {
      deps.push({
        type: 'Document', name: 'ТестовыйДокумент',
        dsl: { type: 'Document', name: 'ТестовыйДокумент' },
        postEdit: [{ op: 'add-registerRecord', val: `${regTypePrefix}.${inp.name}` }],
      });
    }

    switch (inp.type) {
      case 'BusinessProcess': {
        const taskRef = inp.task;
        if (taskRef) {
          const taskName = taskRef.split('.').pop();
          deps.push({ type: 'Task', name: taskName, dsl: { type: 'Task', name: taskName, descriptionLength: 100 } });
        }
        break;
      }
      case 'DocumentJournal':
        if (inp.registeredDocuments) {
          for (const docRef of inp.registeredDocuments) {
            const docName = docRef.split('.').pop();
            deps.push({ type: 'Document', name: docName, dsl: { type: 'Document', name: docName } });
          }
        }
        break;
    }
  }
  return deps;
}

// ─── Stub creation ──────────────────────────────────────────────────────────

function makeStubDSL(type, name) {
  switch (type) {
    case 'Catalog': return { type: 'Catalog', name };
    case 'Document': return { type: 'Document', name };
    case 'Enum': return { type: 'Enum', name, values: ['Значение1'] };
    case 'InformationRegister': return { type: 'InformationRegister', name, dimensions: ['Ключ: String(10)'] };
    case 'AccumulationRegister': return { type: 'AccumulationRegister', name, dimensions: ['Ключ: String(10)'], resources: ['Значение: Number(15,2)'] };
    case 'ChartOfAccounts': return { type: 'ChartOfAccounts', name, codeLength: 4, descriptionLength: 100, maxExtDimensionCount: 0 };
    case 'ChartOfCharacteristicTypes': return { type: 'ChartOfCharacteristicTypes', name, codeLength: 9, descriptionLength: 100 };
    case 'ChartOfCalculationTypes': return { type: 'ChartOfCalculationTypes', name, codeLength: 9, descriptionLength: 100 };
    case 'CommonModule': return { type: 'CommonModule', name, server: true };
    case 'BusinessProcess': return { type: 'BusinessProcess', name };
    case 'Task': return { type: 'Task', name };
    case 'ExchangePlan': return { type: 'ExchangePlan', name, codeLength: 9, descriptionLength: 100 };
    case 'Role': return { type: 'Role', name: name };
    case 'Subsystem': return null; // Subsystems need special handling
    default: return null;
  }
}

const TYPE_TO_PREFIX = {
  Catalog: 'Catalog', Document: 'Document', Enum: 'Enum', Constant: 'Constant',
  CommonModule: 'CommonModule', DataProcessor: 'DataProcessor', Report: 'Report',
  InformationRegister: 'InformationRegister', AccumulationRegister: 'AccumulationRegister',
  AccountingRegister: 'AccountingRegister', CalculationRegister: 'CalculationRegister',
  ChartOfAccounts: 'ChartOfAccounts', ChartOfCharacteristicTypes: 'ChartOfCharacteristicTypes',
  ChartOfCalculationTypes: 'ChartOfCalculationTypes', BusinessProcess: 'BusinessProcess',
  Task: 'Task', ExchangePlan: 'ExchangePlan', DocumentJournal: 'DocumentJournal',
  EventSubscription: 'EventSubscription', ScheduledJob: 'ScheduledJob',
  DefinedType: 'DefinedType', HTTPService: 'HTTPService', WebService: 'WebService',
  Subsystem: 'Subsystem', Role: 'Role',
};

const TYPE_TO_DIR = {
  Catalog: 'Catalogs', Document: 'Documents', Enum: 'Enums', Constant: 'Constants',
  CommonModule: 'CommonModules', DataProcessor: 'DataProcessors', Report: 'Reports',
  InformationRegister: 'InformationRegisters', AccumulationRegister: 'AccumulationRegisters',
  AccountingRegister: 'AccountingRegisters', CalculationRegister: 'CalculationRegisters',
  ChartOfAccounts: 'ChartsOfAccounts', ChartOfCharacteristicTypes: 'ChartsOfCharacteristicTypes',
  ChartOfCalculationTypes: 'ChartsOfCalculationTypes', BusinessProcess: 'BusinessProcesses',
  Task: 'Tasks', ExchangePlan: 'ExchangePlans', DocumentJournal: 'DocumentJournals',
  EventSubscription: 'EventSubscriptions', ScheduledJob: 'ScheduledJobs',
  DefinedType: 'DefinedTypes', HTTPService: 'HTTPServices', WebService: 'WebServices',
  Subsystem: 'Subsystems', Role: 'Roles',
};

// ─── Auto-detect objects in config dir for cf-edit ──────────────────────────

function scanConfigObjects(configDir) {
  const objects = [];
  // DIR_TO_TYPE: reverse mapping of TYPE_TO_DIR
  const DIR_TO_TYPE = {};
  for (const [type, dir] of Object.entries(TYPE_TO_DIR)) DIR_TO_TYPE[dir] = type;

  for (const dir of readdirSync(configDir)) {
    const type = DIR_TO_TYPE[dir];
    if (!type) continue;
    const fullDir = join(configDir, dir);
    if (!statSync(fullDir).isDirectory()) continue;
    for (const item of readdirSync(fullDir)) {
      // Object = either dir or .xml file (for flat objects like DefinedTypes)
      if (statSync(join(fullDir, item)).isDirectory()) {
        objects.push({ type, name: item });
      } else if (item.endsWith('.xml')) {
        const name = item.replace('.xml', '');
        // Avoid duplicates: if dir "Foo" exists and "Foo.xml" too, skip the xml
        if (!existsSync(join(fullDir, name))) {
          objects.push({ type, name });
        }
      }
    }
  }
  return objects;
}

// ─── Build skill args from _skill.json mapping ─────────────────────────────

function buildSkillArgs(skillConfig, caseData, workDir, inputFile, runtime) {
  const args = [];
  const scriptPath = resolveScript(skillConfig.script, runtime);

  for (const mapping of skillConfig.args) {
    args.push(mapping.flag);
    switch (mapping.from) {
      case 'inputFile':
        args.push(inputFile || '');
        break;
      case 'workDir':
        args.push(workDir);
        break;
      case 'workPath': {
        const field = mapping.field || 'objectPath';
        const val = caseData.params?.[field] ?? caseData[field];
        if (val === undefined || val === null || val === '') {
          if (mapping.optional) {
            args.pop(); // remove flag pushed above
            break;
          }
          args.push(join(workDir, ''));
        } else {
          args.push(join(workDir, val));
        }
        break;
      }
      case 'switch':
        args.pop();
        if (caseData[mapping.flag.replace(/^-/, '')] !== false) args.push(mapping.flag);
        break;
      default:
        if (mapping.from.startsWith('case.')) {
          const field = mapping.from.slice(5);
          args.push(String(caseData.params?.[field] ?? caseData[field] ?? ''));
        } else if (mapping.from === 'literal') {
          args.push(mapping.value || '');
        }
    }
  }
  if (caseData.args_extra) args.push(...caseData.args_extra);
  return { scriptPath, args };
}

// ─── Execute preRun steps ───────────────────────────────────────────────────

function runPreSteps(preRun, workDir, runtime, log) {
  if (!preRun) return;
  for (const step of preRun) {
    const preArgs = [];
    for (const [flag, value] of Object.entries(step.args || {})) {
      preArgs.push(flag);
      if (value === true || value === '') continue;
      preArgs.push(String(value).replace('{workDir}', workDir).replace('{inputFile}', ''));
    }
    let preInputFile = null;
    if (step.input) {
      preInputFile = join(workDir, '__pre_input.json');
      writeFileSync(preInputFile, JSON.stringify(step.input, null, 2), 'utf8');
      for (let i = 0; i < preArgs.length; i++) {
        if (preArgs[i] === '') preArgs[i] = preInputFile;
      }
    }
    const stepName = step.script.split('/').pop();
    try {
      execSkill(runtime, step.script, preArgs);
      log(`preRun: ${stepName}`, true);
    } catch (e) {
      log(`preRun: ${stepName}`, false, e.stderr || e.message);
      throw new Error(`preRun "${step.script}" failed: ${(e.stderr || e.message).substring(0, 500)}`);
    }
    if (preInputFile && existsSync(preInputFile)) rmSync(preInputFile);
  }
}

// ─── Skills that DON'T produce loadable configs ─────────────────────────────
// These produce standalone files (SKD templates, MXL templates) that can't be
// loaded into platform without wrapping in a container object.

// Standalone file skills — produce files (not configs), platform load = just run script
const STANDALONE_SKILLS = new Set([
  'skd-compile', 'skd-edit', 'skd-info', 'skd-validate',
  'mxl-compile', 'mxl-decompile', 'mxl-info', 'mxl-validate',
]);

// Standalone skills that CAN be platform-verified by wrapping their output in
// an external report (ERF) and running erf-build — the platform parses the
// schema and we know if it's accepted.
const SKD_PLATFORM_VERIFY = new Set(['skd-compile', 'skd-edit']);

// EPF/ERF skills — need epf-build to verify, not LoadConfigFromFiles
const EPF_SKILLS = new Set([
  'epf-init', 'erf-init', 'template-add', 'help-add',
]);

// CFE skills — two-stage load: base config → extension
const CFE_SKILLS = new Set([
  'cfe-init', 'cfe-borrow', 'cfe-patch-method',
]);

// cf-init produces a config dir — verify by loading the created config
const CONFIG_INIT_SKILLS = new Set(['cf-init']);

// ─── Main verification pipeline ────────────────────────────────────────────

async function verifyCase(skillName, caseName, skillConfig, caseData, opts) {
  const result = {
    skill: skillName, case: caseName, name: caseData.name || caseName,
    passed: false, steps: [], errors: [], warnings: [], workDir: null,
  };

  const workDir = mkdtempSync(join(tmpdir(), `verify-${skillName}-${caseName}-`));
  result.workDir = workDir;

  const log = (step, ok, detail) => {
    result.steps.push({ step, ok, detail: detail?.substring(0, 2000) });
    if (opts.verbose) {
      const icon = ok ? '\u2713' : '\u2717';
      console.log(`    ${icon} ${step}${detail ? ': ' + detail.substring(0, 200) : ''}`);
    }
  };

  // Determine config dir
  const setupType = skillConfig.setup || 'empty-config';
  const isStandalone = STANDALONE_SKILLS.has(skillName);
  const isEpf = EPF_SKILLS.has(skillName);
  const isCfInit = CONFIG_INIT_SKILLS.has(skillName);
  // For 'empty-config': workDir is the config (setup creates it)
  // For cf-init: workDir becomes the config after the script runs
  // For 'none' + non-special: no config (standalone/EPF)
  const configDir = (setupType === 'empty-config' || isCfInit) ? workDir : null;

  try {
    // ── Step 0: Case-level fixture copy (runner.mjs compatibility) ──
    // A case may declare `"setup": "fixture:<name>"` pointing to
    // tests/skills/cases/<skill>/fixtures/<name> — copy its contents into workDir
    // so the skill script finds them at the expected relative path.
    if (typeof caseData.setup === 'string' && caseData.setup.startsWith('fixture:')) {
      const fixtureName = caseData.setup.slice('fixture:'.length);
      const fixturePath = join(CASES, skillName, 'fixtures', fixtureName);
      if (!existsSync(fixturePath)) {
        result.errors.push(`Fixture not found: ${fixturePath}`);
        return result;
      }
      cpSync(fixturePath, workDir, { recursive: true });
      log(`fixture: ${fixtureName}`, true);
    }

    // ── Step 1: Setup (cf-init for empty-config, nothing for 'none') ──
    // Skip setup for cf-init skill — the test itself creates the config
    if (configDir && setupType === 'empty-config' && !CONFIG_INIT_SKILLS.has(skillName)) {
      try {
        execSkill(opts.runtime, 'cf-init/scripts/cf-init', ['-Name', 'VerifyTest', '-OutputDir', workDir]);
        log('cf-init', true);
      } catch (e) {
        log('cf-init', false, e.stderr || e.message);
        result.errors.push(`cf-init failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }
    }

    // ── Step 2: Dependency stubs ──
    // Collect all inputs: from caseData.input AND from preRun steps
    const allInputs = [];
    if (caseData.input && (caseData.input.type || Array.isArray(caseData.input))) {
      const inputs = Array.isArray(caseData.input) ? caseData.input : [caseData.input];
      allInputs.push(...inputs.filter(i => i.type));
    }
    // Also scan preRun inputs for type refs (D3 fix)
    if (caseData.preRun) {
      for (const step of caseData.preRun) {
        if (step.input && step.input.type) allInputs.push(step.input);
        if (Array.isArray(step.input)) allInputs.push(...step.input.filter(i => i && i.type));
      }
    }

    if (configDir && allInputs.length > 0) {
      const mainNames = new Set(allInputs.map(i => `${i.type}.${i.name}`));

      // Structural deps
      const structDeps = getStructuralDeps(caseData.input || {});
      const structDSLs = new Map();
      const structPostEdits = new Map();
      for (const dep of structDeps) {
        const key = `${dep.type}.${dep.name}`;
        if (dep.dsl) structDSLs.set(key, dep.dsl);
        if (dep.postEdit) structPostEdits.set(key, dep.postEdit);
      }

      // Type refs from ALL inputs (main + preRun)
      const allRefs = new Map();
      for (const inp of allInputs) {
        for (const [key, ref] of extractTypeRefs(inp)) {
          if (!mainNames.has(key)) allRefs.set(key, ref);
        }
      }
      for (const dep of structDeps) {
        const key = `${dep.type}.${dep.name}`;
        if (!mainNames.has(key) && !allRefs.has(key)) allRefs.set(key, { type: dep.type, name: dep.name });
      }

      // Create stubs
      for (const [key, ref] of allRefs) {
        const stubDSL = structDSLs.get(key) || makeStubDSL(ref.type, ref.name);
        if (!stubDSL) { result.warnings.push(`Cannot create stub for ${key}`); continue; }
        try {
          const stubFile = join(workDir, `__stub.json`);
          writeFileSync(stubFile, JSON.stringify(stubDSL, null, 2), 'utf8');
          execSkill(opts.runtime, 'meta-compile/scripts/meta-compile', ['-JsonPath', stubFile, '-OutputDir', configDir]);
          log(`stub: ${key}`, true);
        } catch (e) {
          log(`stub: ${key}`, false, e.stderr || e.message);
          result.warnings.push(`Stub failed: ${key}`);
        }

        // Post-edit (e.g. add-registerRecord)
        const edits = structPostEdits.get(key);
        if (edits) {
          const dir = TYPE_TO_DIR[ref.type];
          const objPath = dir ? join(configDir, dir, ref.name) : null;
          if (objPath && existsSync(objPath)) {
            for (const edit of edits) {
              try {
                execSkill(opts.runtime, 'meta-edit/scripts/meta-edit',
                  ['-ObjectPath', objPath, '-Operation', edit.op, '-Value', edit.val]);
                log(`postEdit: ${key}`, true, `${edit.op} ${edit.val}`);
              } catch (e) {
                log(`postEdit: ${key}`, false, e.stderr || e.message);
                result.warnings.push(`PostEdit failed: ${key}`);
              }
            }
          }
        }
      }
    }

    // ── Step 3: preRun steps ──
    try {
      runPreSteps(caseData.preRun, workDir, opts.runtime, log);
    } catch (e) {
      result.errors.push(e.message);
      return result;
    }

    // ── Step 4: Main skill script ──
    let inputFile = null;
    if (caseData.input !== undefined) {
      inputFile = join(workDir, '__input.json');
      writeFileSync(inputFile, JSON.stringify(caseData.input, null, 2), 'utf8');
    }

    try {
      const { args } = buildSkillArgs(skillConfig, caseData, workDir, inputFile, opts.runtime);
      const mainCwd = skillConfig.cwd === 'workDir' ? workDir : REPO_ROOT;
      const output = execSkill(opts.runtime, skillConfig.script, args, 60_000, mainCwd);
      const lastLine = output.trim().split('\n').pop();
      if (caseData.expectError) {
        log(skillName, false, 'expected non-zero exit but got success');
        result.errors.push(`${skillName}: expected error but got success`);
        return result;
      }
      log(skillName, true, lastLine);
    } catch (e) {
      const detail = (e.stderr || e.stdout || e.message).trim();
      if (caseData.expectError) {
        if (typeof caseData.expectError === 'string' && !detail.includes(caseData.expectError)) {
          log(skillName, false, `expected "${caseData.expectError}" in stderr, got: ${detail.substring(0, 200)}`);
          result.errors.push(`${skillName}: stderr does not contain "${caseData.expectError}"`);
          return result;
        }
        log(skillName, true, `(expected error) ${detail.substring(0, 100)}`);
        result.passed = true;
        return result;
      }
      log(skillName, false, detail);
      result.errors.push(`${skillName} failed: ${detail.substring(0, 500)}`);
      return result;
    }
    if (inputFile && existsSync(inputFile)) rmSync(inputFile);

    // ── Step 5: Determine verification strategy ──
    if (SKD_PLATFORM_VERIFY.has(skillName)) {
      // Wrap produced Template.xml in an external report (ERF) and try to build —
      // platform either accepts the schema or rejects it with an error.
      if (!opts.v8ctx) {
        result.passed = true;
        log('platform-load', true, 'skipped (no v8 context)');
        return result;
      }
      const tplName = caseData.params?.templatePath || caseData.params?.outputPath || 'Template.xml';
      const tplPath = join(workDir, tplName);
      if (!existsSync(tplPath)) {
        result.errors.push(`Output not produced at ${tplPath}`);
        return result;
      }
      const erfDir = join(workDir, 'erf-src');
      const erfOutDir = join(workDir, 'erf-build');
      mkdirSync(erfOutDir, { recursive: true });
      try {
        execSkill(opts.runtime, 'erf-init/scripts/init', ['-Name', 'TestReport', '-SrcDir', erfDir, '-WithSKD']);
        log('erf-init', true);
      } catch (e) {
        const detail = (e.stderr || e.stdout || e.message).trim();
        log('erf-init', false, detail);
        result.errors.push(`erf-init failed: ${detail.substring(0, 500)}`);
        return result;
      }
      const dcsTpl = join(erfDir, 'TestReport', 'Templates', 'ОсновнаяСхемаКомпоновкиДанных', 'Ext', 'Template.xml');
      cpSync(tplPath, dcsTpl, { force: true });
      try {
        execSkill(opts.runtime, 'epf-build/scripts/epf-build', [
          '-V8Path', opts.v8ctx.v8path,
          '-SourceFile', join(erfDir, 'TestReport.xml'),
          '-OutputFile', join(erfOutDir, 'TestReport.erf'),
        ], 120_000);
        log('erf-build', true, 'platform accepted schema');
        result.passed = true;
      } catch (e) {
        const detail = (e.stderr || e.stdout || e.message).trim();
        log('erf-build', false, detail);
        result.errors.push(`erf-build rejected schema: ${detail.substring(0, 1000)}`);
      }
      return result;
    }

    if (isStandalone) {
      result.passed = true;
      log('platform-load', true, 'skipped (standalone file, not a config)');
      return result;
    }

    if (isEpf) {
      result.passed = true;
      log('platform-load', true, 'skipped (EPF — verified by integration/platform-epf)');
      return result;
    }

    if (CFE_SKILLS.has(skillName)) {
      // CFE: two-stage load — base config first, then extension
      const extDir = join(workDir, 'ext');
      const baseConfigDir = workDir; // preRun puts base config directly in workDir
      const dbDir = join(workDir, 'testdb');

      // Register base config objects
      const baseObjects = scanConfigObjects(baseConfigDir);
      const baseCfEditOps = baseObjects
        .filter(o => TYPE_TO_PREFIX[o.type])
        .map(o => ({ operation: 'add-childObject', value: `${TYPE_TO_PREFIX[o.type]}.${o.name}` }));
      if (baseCfEditOps.length > 0) {
        try {
          const editFile = join(workDir, '__cf-edit-base.json');
          writeFileSync(editFile, JSON.stringify(baseCfEditOps, null, 2), 'utf8');
          execSkill(opts.runtime, 'cf-edit/scripts/cf-edit', ['-ConfigPath', baseConfigDir, '-DefinitionFile', editFile]);
          log('cf-edit (base)', true, `${baseCfEditOps.length} objects`);
        } catch (e) {
          log('cf-edit (base)', false, e.stderr || e.message);
          result.errors.push(`cf-edit base failed: ${(e.stderr || e.message).substring(0, 500)}`);
          return result;
        }
      }

      // Create DB + load base config
      try {
        execSkill(opts.runtime, 'db-create/scripts/db-create', ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir]);
        log('db-create', true);
      } catch (e) {
        log('db-create', false, e.stderr || e.message);
        result.errors.push(`db-create failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }

      try {
        execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
          ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', baseConfigDir, '-StrictLog'], 180_000);
        log('db-load-xml (config)', true);
      } catch (e) {
        const detail = (e.stderr || e.stdout || e.message).trim();
        log('db-load-xml (config)', false, detail);
        result.errors.push(`LoadConfig failed: ${detail.substring(0, 1000)}`);
        return result;
      }

      try {
        execSkill(opts.runtime, 'db-update/scripts/db-update',
          ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir], 180_000);
        log('db-update (config)', true);
      } catch (e) {
        const detail = (e.stderr || e.stdout || e.message).trim();
        log('db-update (config)', false, detail);
        result.errors.push(`UpdateDBCfg config failed: ${detail.substring(0, 1000)}`);
        return result;
      }

      // Load extension — detect extension name from ext/Configuration.xml
      let extName = 'Extension';
      try {
        const extConfigXml = readFileSync(join(extDir, 'Configuration.xml'), 'utf8');
        const nameMatch = extConfigXml.match(/<Name>([^<]+)<\/Name>/);
        if (nameMatch) extName = nameMatch[1];
      } catch {}

      if (existsSync(extDir)) {
        try {
          execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
            ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', extDir, '-Extension', extName, '-StrictLog'], 180_000);
          log('db-load-xml (ext)', true);
        } catch (e) {
          const detail = (e.stderr || e.stdout || e.message).trim();
          log('db-load-xml (ext)', false, detail);
          result.errors.push(`LoadExtension failed: ${detail.substring(0, 1000)}`);
          return result;
        }

        try {
          execSkill(opts.runtime, 'db-update/scripts/db-update',
            ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-Extension', extName], 180_000);
          log('db-update (ext)', true);
        } catch (e) {
          const detail = (e.stderr || e.stdout || e.message).trim();
          log('db-update (ext)', false, detail);
          result.errors.push(`UpdateDBCfg ext failed: ${detail.substring(0, 1000)}`);
          return result;
        }
      }

      result.passed = true;
      return result;
    }

    if (CONFIG_INIT_SKILLS.has(skillName)) {
      // cf-init: the script already created the config in workDir,
      // but we called cf-init in Step 1 already. For cf-init tests,
      // the MAIN script IS cf-init, so workDir = the new config.
      // It should be loadable as-is.
    }

    if (!configDir) {
      // No config to load — setup was 'none' and not EPF/standalone
      result.passed = true;
      return result;
    }

    // ── Step 6: Auto-detect and register objects in ChildObjects ──
    const allObjects = scanConfigObjects(configDir);
    const cfEditOps = [];
    for (const obj of allObjects) {
      const prefix = TYPE_TO_PREFIX[obj.type];
      if (prefix) cfEditOps.push({ operation: 'add-childObject', value: `${prefix}.${obj.name}` });
    }

    if (cfEditOps.length > 0) {
      try {
        const editFile = join(workDir, '__cf-edit.json');
        writeFileSync(editFile, JSON.stringify(cfEditOps, null, 2), 'utf8');
        execSkill(opts.runtime, 'cf-edit/scripts/cf-edit', ['-ConfigPath', configDir, '-DefinitionFile', editFile]);
        log('cf-edit', true, `${cfEditOps.length} objects`);
      } catch (e) {
        log('cf-edit', false, e.stderr || e.message);
        result.errors.push(`cf-edit failed: ${(e.stderr || e.message).substring(0, 500)}`);
        return result;
      }
    }

    // ── Step 7: Platform load ──
    const dbDir = join(workDir, 'testdb');

    try {
      execSkill(opts.runtime, 'db-create/scripts/db-create', ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir]);
      log('db-create', true);
    } catch (e) {
      log('db-create', false, e.stderr || e.message);
      result.errors.push(`db-create failed: ${(e.stderr || e.message).substring(0, 500)}`);
      return result;
    }

    try {
      execSkill(opts.runtime, 'db-load-xml/scripts/db-load-xml',
        ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir, '-ConfigDir', configDir, '-StrictLog'], 180_000);
      log('db-load-xml', true);
    } catch (e) {
      const detail = (e.stderr || e.stdout || e.message).trim();
      log('db-load-xml', false, detail);
      result.errors.push(`LoadConfigFromFiles failed: ${detail.substring(0, 1000)}`);
      return result;
    }

    try {
      execSkill(opts.runtime, 'db-update/scripts/db-update',
        ['-V8Path', opts.v8ctx.v8path, '-InfoBasePath', dbDir], 180_000);
      log('db-update', true);
    } catch (e) {
      const detail = (e.stderr || e.stdout || e.message).trim();
      log('db-update', false, detail);
      result.errors.push(`UpdateDBCfg failed: ${detail.substring(0, 1000)}`);
      return result;
    }

    result.passed = true;
  } catch (e) {
    result.errors.push(`Unexpected error: ${e.message}`);
  } finally {
    if (!opts.keep) {
      try { rmSync(workDir, { recursive: true, force: true }); } catch {}
      result.workDir = '(cleaned)';
    }
  }

  return result;
}

// ─── Discovery ──────────────────────────────────────────────────────────────

// Default skills to verify when no --skill given
const DEFAULT_SKILLS = [
  'meta-compile', 'form-compile', 'form-compile-from-object', 'form-add', 'form-edit',
  'role-compile', 'subsystem-compile', 'subsystem-edit',
  'cf-init', 'cf-edit', 'meta-edit', 'interface-edit',
  'epf-init', 'template-add', 'help-add',
  'cfe-init', 'cfe-borrow', 'cfe-patch-method',
  'skd-compile', 'skd-edit', 'mxl-compile',
];

function discoverCases(skillFilter, caseFilter) {
  const results = [];
  const skillDirs = skillFilter ? [skillFilter] : DEFAULT_SKILLS;

  for (const skillDir of skillDirs) {
    const skillPath = join(CASES, skillDir);
    if (!existsSync(skillPath)) continue;

    const skillJsonPath = join(skillPath, '_skill.json');
    if (!existsSync(skillJsonPath)) continue;
    const skillConfig = JSON.parse(readFileSync(skillJsonPath, 'utf8'));

    // Skip skills that don't have snapshots (read-only, info, validate)
    if (!existsSync(join(skillPath, 'snapshots'))) continue;

    for (const file of readdirSync(skillPath)) {
      if (file.startsWith('_') || !file.endsWith('.json')) continue;
      const caseName = file.replace(/\.json$/, '');

      if (caseFilter && caseName !== caseFilter) continue;

      const caseData = JSON.parse(readFileSync(join(skillPath, file), 'utf8'));

      // Skip error cases
      if (caseName.startsWith('error-')) continue;

      // Skip cases without input AND without preRun AND without params (truly read-only)
      if (caseData.input === undefined && !caseData.preRun && !caseData.params) continue;

      results.push({ skill: skillDir, caseName, caseData, skillConfig });
    }
  }
  return results;
}

// ─── Report ─────────────────────────────────────────────────────────────────

function writeReport(results) {
  mkdirSync(REPORT_DIR, { recursive: true });

  const lines = [
    `# Snapshot Verification Report`,
    ``,
    `Date: ${new Date().toISOString().split('T')[0]}`,
    `Total: ${results.length} | Passed: ${results.filter(r => r.passed).length} | Failed: ${results.filter(r => !r.passed).length}`,
    ``,
  ];

  lines.push('| Skill | Case | Status | Error |');
  lines.push('|-------|------|--------|-------|');
  for (const r of results) {
    const status = r.passed ? 'OK' : 'FAIL';
    const error = r.errors.length > 0 ? r.errors[0].substring(0, 100).replace(/\|/g, '\\|').replace(/\n/g, ' ') : '';
    lines.push(`| ${r.skill} | ${r.case} | ${status} | ${error} |`);
  }

  const failures = results.filter(r => !r.passed);
  if (failures.length > 0) {
    lines.push('', '## Findings', '');
    for (const r of failures) {
      lines.push(`### ${r.skill}/${r.case}: ${r.name}`);
      lines.push('');
      lines.push('**Steps:**');
      for (const s of r.steps) {
        lines.push(`- ${s.ok ? '\u2713' : '\u2717'} ${s.step}${s.detail ? ': ' + s.detail.substring(0, 300) : ''}`);
      }
      if (r.warnings.length > 0) {
        lines.push('', '**Warnings:**');
        for (const w of r.warnings) lines.push(`- ${w}`);
      }
      lines.push('', '**Errors:**');
      for (const e of r.errors) lines.push('```', e, '```');
      lines.push('');
      lines.push('**Classification:** <!-- DSL_BUG | SCRIPT_BUG | VALIDATION_GAP | PLATFORM_QUIRK -->');
      lines.push('**Action:** <!-- normalize | warn | error | skip -->');
      lines.push('');
    }
  }

  const withWarnings = results.filter(r => r.passed && r.warnings.length > 0);
  if (withWarnings.length > 0) {
    lines.push('', '## Warnings (passed with notes)', '');
    for (const r of withWarnings) {
      lines.push(`### ${r.skill}/${r.case}`);
      for (const w of r.warnings) lines.push(`- ${w}`);
      lines.push('');
    }
  }

  const reportPath = join(REPORT_DIR, 'REPORT.md');
  writeFileSync(reportPath, lines.join('\n'), 'utf8');
  console.log(`\nReport written to: ${reportPath}`);
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  const v8ctx = loadV8Context();
  if (!v8ctx) {
    console.error('ERROR: 1C platform not found. Check .v8-project.json');
    process.exit(1);
  }
  opts.v8ctx = v8ctx;
  console.log(`Platform: ${v8ctx.v8exe}`);

  const cases = discoverCases(opts.skill, opts.caseName);
  if (cases.length === 0) {
    console.error('No cases found.');
    process.exit(1);
  }
  console.log(`Found ${cases.length} case(s) to verify.\n`);

  const results = [];
  for (const { skill, caseName, caseData, skillConfig } of cases) {
    const label = `${skill}/${caseName}`;
    if (opts.verbose) console.log(`  ${label}: ${caseData.name || ''}`);
    else process.stdout.write(`  ${label}...`);

    const t0 = performance.now();
    const result = await verifyCase(skill, caseName, skillConfig, caseData, opts);
    const elapsed = ((performance.now() - t0) / 1000).toFixed(1);

    if (!opts.verbose) {
      const icon = result.passed ? '\u2713' : '\u2717';
      console.log(` ${icon} (${elapsed}s)${result.errors.length ? ' — ' + result.errors[0].substring(0, 80) : ''}`);
    } else {
      console.log(`    → ${result.passed ? 'PASS' : 'FAIL'} (${elapsed}s)\n`);
    }

    results.push(result);
  }

  const passed = results.filter(r => r.passed).length;
  const failed = results.filter(r => !r.passed).length;
  console.log(`\n${'='.repeat(60)}`);
  console.log(`Results: ${passed} passed, ${failed} failed out of ${results.length}`);

  writeReport(results);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
