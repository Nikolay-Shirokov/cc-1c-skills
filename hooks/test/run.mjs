// run.mjs v1.1 — standalone tests for hook common/ modules against the cfsrc corpus
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// No live hook registration needed: exercises decideSupport / getEditMode / findConfigRoot
// directly. Run: node hooks/test/run.mjs

import { decideSupport, findConfigRoot, rootUuid, isExternalObjectRoot } from '../common/support-state.mjs';
import { getEditMode, getSuggesterMode } from '../common/project.mjs';
import { processInput as guard } from '../support-guard.mjs';
import { processInput as suggest } from '../skill-suggester.mjs';
import { execFileSync } from 'node:child_process';
import { rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';

// Repo root derived from this file's own location (<repo>/hooks/test/run.mjs) so the
// suite is portable — hardcoding 'C:/WS/tasks/skills' broke on POSIX, where a 'C:/…'
// string is not absolute and resolve(cwd, path) doubled it into a non-existent path.
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
// External vendor corpus (acc/erp): Windows-only by default, env-overridable. The
// acc/erp cases below are existsSync-guarded → they SKIP when the corpus is absent.
const CORPUS = process.env.CC_1C_CFSRC || 'C:/WS/tasks/cfsrc';
const ACC = join(CORPUS, 'acc_8.3.24'); // G=1 — whole config locked
const ERP = join(CORPUS, 'erp_8.3.24'); // K=0 — support removed

let pass = 0, fail = 0;
function check(name, cond, detail = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  — ' + detail : ''}`); }
}

console.log('=== support-state: decideSupport ===');

if (existsSync(join(ACC, 'Configuration.xml'))) {
  const r = decideSupport(join(ACC, 'Configuration.xml'), 'editable');
  check('acc_8.3.24 (G=1) → blocked', r.blocked === true, JSON.stringify(r));
  check('acc_8.3.24 reason mentions read-only', /read-only/.test(r.reason));
} else { console.log('  SKIP  acc_8.3.24 corpus missing'); }

if (existsSync(join(ERP, 'Configuration.xml'))) {
  const r = decideSupport(join(ERP, 'Configuration.xml'), 'editable');
  check('erp_8.3.24 (K=0) → NOT blocked', r.blocked === false, JSON.stringify(r));
  check('erp_8.3.24 cfgDir resolved', !!r.cfgDir);
} else { console.log('  SKIP  erp_8.3.24 corpus missing'); }

{
  const r = decideSupport(join(REPO, 'README.md'), 'editable');
  check('repo README (no bin) → NOT blocked', r.blocked === false, JSON.stringify(r));
}

console.log('=== support-state: findConfigRoot / rootUuid ===');
if (existsSync(join(ACC, 'Configuration.xml'))) {
  const cr = findConfigRoot(join(ACC, 'Ext', 'ParentConfigurations.bin'));
  check('findConfigRoot locates cfgDir', !!cr.cfgDir);
  check('findConfigRoot base config isExtension=false', cr.isExtension === false);
  const u = rootUuid(join(ACC, 'Configuration.xml'));
  check('rootUuid(Configuration.xml) is a guid', !!u && /^[0-9a-fA-F-]{36}$/.test(u), String(u));
}

console.log('=== support-state: synthetic per-object f1 (G=0) ===');
{
  // Corpus only has G=1 / K=0; synthesize a G=0 single-vendor config with a locked
  // (f1=0), an editable (f1=1) and a removed-from-support (f1=2) object to exercise
  // the uuid rule + min-f1 fold. Fixtures go to test-tmp (gitignored), never cfsrc.
  const ROOT = join(REPO, 'test-tmp', 'hooks-synth');
  const U = {
    root: '11111111-1111-1111-1111-111111111111',
    locked: '22222222-2222-2222-2222-222222222222',
    edit: '33333333-3333-3333-3333-333333333333',
    removed: '44444444-4444-4444-4444-444444444444',
    free: '55555555-5555-5555-5555-555555555555', // not in bin → not on support
  };
  mkdirSync(join(ROOT, 'Ext'), { recursive: true });
  mkdirSync(join(ROOT, 'Catalogs'), { recursive: true });
  const rec = (f1, u) => `${f1},0,${u},${u},`;
  const binText =
    `{6,0,1,aaaaaaaa-0000-0000-0000-000000000000,0,bbbbbbbb-0000-0000-0000-000000000000,` +
    `"1.0","Vendor","Name",4,` +
    rec(0, U.root) + rec(0, U.locked) + rec(1, U.edit) + rec(2, U.removed).replace(/,$/, '') + `}`;
  writeFileSync(join(ROOT, 'Ext', 'ParentConfigurations.bin'),
    Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(binText, 'utf8')]));
  const objXml = (u) => `<?xml version="1.0" encoding="UTF-8"?>\n<MetaDataObject><Catalog uuid="${u}"></Catalog></MetaDataObject>`;
  writeFileSync(join(ROOT, 'Configuration.xml'), objXml(U.root));
  for (const [k, u] of [['Locked', U.locked], ['Editable', U.edit], ['Removed', U.removed], ['Free', U.free]]) {
    writeFileSync(join(ROOT, 'Catalogs', k + '.xml'), objXml(u));
  }

  const rLocked = decideSupport(join(ROOT, 'Catalogs', 'Locked.xml'), 'editable');
  check('synth locked (f1=0) → blocked', rLocked.blocked === true, JSON.stringify(rLocked));
  check('synth locked reason mentions замке', /замке/.test(rLocked.reason));
  const rEdit = decideSupport(join(ROOT, 'Catalogs', 'Editable.xml'), 'editable');
  check('synth editable (f1=1) → NOT blocked', rEdit.blocked === false, JSON.stringify(rEdit));
  const rRemoved = decideSupport(join(ROOT, 'Catalogs', 'Removed.xml'), 'editable');
  check('synth removed (f1=2) → NOT blocked', rRemoved.blocked === false, JSON.stringify(rRemoved));
  const rFree = decideSupport(join(ROOT, 'Catalogs', 'Free.xml'), 'editable');
  check('synth free (not in bin) → NOT blocked', rFree.blocked === false, JSON.stringify(rFree));
  // meta-remove semantics: deletion needs f1=2 (removed from support).
  const rmLocked = decideSupport(join(ROOT, 'Catalogs', 'Locked.xml'), 'removed');
  check('synth remove locked (f1=0) → blocked', rmLocked.blocked === true, JSON.stringify(rmLocked));
  const rmRemoved = decideSupport(join(ROOT, 'Catalogs', 'Removed.xml'), 'removed');
  check('synth remove removed (f1=2) → NOT blocked', rmRemoved.blocked === false, JSON.stringify(rmRemoved));
}

console.log('=== support-state: external object boundary (issue #39) ===');
{
  // Autonomous EPF/ERF parked INSIDE a config tree whose capability is off (G=1). The
  // climb must stop at the external object's root and NOT attribute it to the config.
  const ROOT = join(REPO, 'test-tmp', 'hooks-ext');
  const cat = '66666666-6666-6666-6666-666666666666';
  mkdirSync(join(ROOT, 'Ext'), { recursive: true });
  mkdirSync(join(ROOT, 'Catalogs'), { recursive: true });
  mkdirSync(join(ROOT, 'print-forms', 'Демо', 'Templates', 'Макет', 'Ext'), { recursive: true });
  // G=1 (capability off), K=1 — blocks every config object unconditionally.
  const binText = `{6,1,1,aaaaaaaa-0000-0000-0000-000000000000,0,bbbbbbbb-0000-0000-0000-000000000000,` +
    `"1.0","Vendor","Name",1,0,0,${cat}}`;
  writeFileSync(join(ROOT, 'Ext', 'ParentConfigurations.bin'),
    Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(binText, 'utf8')]));
  writeFileSync(join(ROOT, 'Configuration.xml'),
    `<?xml version="1.0" encoding="UTF-8"?>\n<MetaDataObject><Configuration uuid="11111111-1111-1111-1111-111111111111"></Configuration></MetaDataObject>`);
  writeFileSync(join(ROOT, 'Catalogs', 'InConfig.xml'),
    `<?xml version="1.0" encoding="UTF-8"?>\n<MetaDataObject><Catalog uuid="${cat}"></Catalog></MetaDataObject>`);
  writeFileSync(join(ROOT, 'print-forms', 'Демо.xml'),
    `<?xml version="1.0" encoding="UTF-8"?>\n<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses">\n\t<ExternalDataProcessor uuid="99999999-9999-9999-9999-999999999999"><Properties><Name>Демо</Name></Properties></ExternalDataProcessor>\n</MetaDataObject>`);
  writeFileSync(join(ROOT, 'print-forms', 'Демо', 'Templates', 'Макет', 'Ext', 'Template.xml'),
    `<?xml version="1.0"?><document xmlns="http://v8.1c.ru/8.1/data/spreadsheet"></document>`);

  const epfRoot = join(ROOT, 'print-forms', 'Демо.xml');
  const epfTpl = join(ROOT, 'print-forms', 'Демо', 'Templates', 'Макет', 'Ext', 'Template.xml');
  const cfgObj = join(ROOT, 'Catalogs', 'InConfig.xml');

  check('isExternalObjectRoot(EPF root) → true', isExternalObjectRoot(epfRoot) === true);
  check('isExternalObjectRoot(config Catalog) → false', isExternalObjectRoot(cfgObj) === false);
  check('EPF root → NOT blocked (G=1 config ignored)', decideSupport(epfRoot, 'editable').blocked === false, JSON.stringify(decideSupport(epfRoot, 'editable')));
  const rTpl = decideSupport(epfTpl, 'editable');
  check('EPF template → NOT blocked (climb stops at EPF root)', rTpl.blocked === false, JSON.stringify(rTpl));
  const rCfg = decideSupport(cfgObj, 'editable');
  check('control: config object under G=1 → blocked', rCfg.blocked === true && rCfg.code === 'capability-off', JSON.stringify(rCfg));
  check('findConfigRoot(EPF template) → no cfgDir', findConfigRoot(epfTpl).cfgDir === null, JSON.stringify(findConfigRoot(epfTpl)));
  const rGuard = guard({ tool_name: 'Edit', cwd: REPO, tool_input: { file_path: epfTpl } });
  check('guard on EPF template → allow (no stdout)', rGuard.stdout === '' && rGuard.exitCode === 0, JSON.stringify(rGuard));
}

console.log('=== project: reaction modes ===');
{
  const m = getEditMode(ACC, REPO);
  check('getEditMode default → deny', m === 'deny', m);
  const s = getSuggesterMode(ACC, REPO);
  check('getSuggesterMode default → on', s === 'on', s);
}

console.log('=== support-guard: §1A PreToolUse ===');
{
  const SYNTH = join(REPO, 'test-tmp', 'hooks-synth');
  const edit = (fp, cwd = REPO) => guard({ tool_name: 'Edit', cwd, tool_input: { file_path: fp } });

  // deny (default): G=1 corpus → capability-off remedy; synth locked → editable remedy.
  if (existsSync(join(ACC, 'Configuration.xml'))) {
    const r = edit(join(ACC, 'Configuration.xml'));
    let d = null; try { d = JSON.parse(r.stdout); } catch { /* */ }
    const reason = d?.hookSpecificOutput?.permissionDecisionReason || '';
    check('guard acc (G=1) → deny JSON', d?.hookSpecificOutput?.permissionDecision === 'deny', r.stdout);
    check('guard G=1 reason → -Capability on remedy', /-Capability on/.test(reason) && /возможность изменения/.test(reason), reason);
  }
  const rLocked = edit(join(SYNTH, 'Catalogs', 'Locked.xml'));
  let dLocked = null; try { dLocked = JSON.parse(rLocked.stdout); } catch { /* */ }
  const reasonLocked = dLocked?.hookSpecificOutput?.permissionDecisionReason || '';
  check('guard synth locked → deny JSON', dLocked?.hookSpecificOutput?.permissionDecision === 'deny', rLocked.stdout);
  check('guard locked reason → -Set editable with real path', /-Set editable/.test(reasonLocked) && reasonLocked.includes('Locked.xml'), reasonLocked);
  check('guard reason offers cfe + support-edit', /cfe-borrow/.test(reasonLocked) && /support-edit/.test(reasonLocked), reasonLocked);

  // allow: erp + synth editable + non-config file → empty stdout, exit 0.
  const rEdit = edit(join(SYNTH, 'Catalogs', 'Editable.xml'));
  check('guard synth editable → allow (no stdout)', rEdit.stdout === '' && rEdit.exitCode === 0, JSON.stringify(rEdit));
  const rReadme = edit(join(REPO, 'README.md'));
  check('guard non-config → allow', rReadme.stdout === '' && rReadme.exitCode === 0);

  // MultiEdit array form.
  const rMulti = guard({ tool_name: 'MultiEdit', cwd: REPO,
    tool_input: { file_edits: [{ file_path: join(SYNTH, 'Catalogs', 'Editable.xml') }, { file_path: join(SYNTH, 'Catalogs', 'Locked.xml') }] } });
  let dMulti = null; try { dMulti = JSON.parse(rMulti.stdout); } catch { /* */ }
  check('guard MultiEdit (one locked) → deny', dMulti?.hookSpecificOutput?.permissionDecision === 'deny', rMulti.stdout);

  // warn / off via local .v8-project.json in the synth root.
  writeFileSync(join(SYNTH, '.v8-project.json'), JSON.stringify({ editingAllowedCheck: 'warn' }));
  const rWarn = edit(join(SYNTH, 'Catalogs', 'Locked.xml'), SYNTH);
  check('guard warn → allow + stderr note', rWarn.stdout === '' && /ПРЕДУПРЕЖДЕНИЕ/.test(rWarn.stderr), JSON.stringify(rWarn));
  writeFileSync(join(SYNTH, '.v8-project.json'), JSON.stringify({ editingAllowedCheck: 'off' }));
  const rOff = edit(join(SYNTH, 'Catalogs', 'Locked.xml'), SYNTH);
  check('guard off → silent allow', rOff.stdout === '' && rOff.stderr === '', JSON.stringify(rOff));

  // Real stdin→stdout wiring through node (deny path, default project).
  try {
    const payload = JSON.stringify({ tool_name: 'Edit', cwd: REPO, tool_input: { file_path: join(SYNTH, 'Catalogs', 'Locked.xml') } });
    // remove the off-mode project file so default deny applies
    writeFileSync(join(SYNTH, '.v8-project.json'), JSON.stringify({ editingAllowedCheck: 'deny' }));
    const out = execFileSync(process.execPath, [join(REPO, 'hooks', 'support-guard.mjs')], { input: payload, encoding: 'utf8' });
    const d = JSON.parse(out);
    check('guard via stdin subprocess → deny JSON', d?.hookSpecificOutput?.permissionDecision === 'deny', out);
  } catch (e) {
    check('guard via stdin subprocess → deny JSON', false, String(e));
  }
}

console.log('=== skill-suggester: PostToolUse nudge ===');
{
  const SYNTH = join(REPO, 'test-tmp', 'hooks-synth');
  const THR = join(REPO, 'test-tmp', 'hooks-throttle');
  rmSync(THR, { recursive: true, force: true });
  mkdirSync(THR, { recursive: true });
  // suggester reads skillSuggester from .v8-project.json; clear synth project file → default on
  rmSync(join(SYNTH, '.v8-project.json'), { force: true });

  // sniff fixtures
  mkdirSync(join(SYNTH, 'Catalogs', 'Obj', 'Forms', 'F', 'Ext'), { recursive: true });
  mkdirSync(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Print', 'Ext'), { recursive: true });
  mkdirSync(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Scheme', 'Ext'), { recursive: true });
  mkdirSync(join(SYNTH, 'Roles', 'R', 'Ext'), { recursive: true });
  mkdirSync(join(SYNTH, 'ext'), { recursive: true });
  writeFileSync(join(SYNTH, 'Catalogs', 'Obj', 'Forms', 'F', 'Ext', 'Form.xml'), '<?xml version="1.0"?><Form/>');
  writeFileSync(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Print', 'Ext', 'Template.xml'),
    '<?xml version="1.0"?>\n<document xmlns="http://v8.1c.ru/8.2/data/spreadsheet"></document>');
  writeFileSync(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Scheme', 'Ext', 'Template.xml'),
    '<?xml version="1.0"?>\n<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data/data-composition-system/schema"></DataCompositionSchema>');
  writeFileSync(join(SYNTH, 'Roles', 'R', 'Ext', 'Rights.xml'), '<?xml version="1.0"?><Rights/>');
  writeFileSync(join(SYNTH, 'ext', 'Configuration.xml'),
    '<?xml version="1.0"?>\n<MetaDataObject><Configuration uuid="x"><Properties><ConfigurationExtensionPurpose>Customization</ConfigurationExtensionPurpose></Properties></Configuration></MetaDataObject>');

  const call = (fp, session, tool) => suggest({ tool_name: tool, session_id: session, cwd: REPO, tool_input: { file_path: fp } }, { throttleDir: THR });
  const read = (fp, session = 's1') => call(fp, session, 'Read');
  const edit = (fp, session = 's1') => call(fp, session, 'Edit');
  const grp = (r) => { try { return JSON.parse(r.stdout)?.hookSpecificOutput?.additionalContext; } catch { return null; } };

  // Read → info-skill; Edit → mutator-skill (same group, distinct nudge).
  const rMeta = read(join(SYNTH, 'Catalogs', 'Locked.xml'), 'A');
  check('Read Catalogs/X.xml → meta-info', /meta-info/.test(grp(rMeta) || ''), rMeta.stdout);
  const rMetaEdit = edit(join(SYNTH, 'Catalogs', 'Editable.xml'), 'A'); // same session+group, write action
  check('Edit Catalogs/X.xml → meta-edit (not throttled by the read)', /meta-edit/.test(grp(rMetaEdit) || ''), rMetaEdit.stdout);
  const rMeta2 = read(join(SYNTH, 'Catalogs', 'Editable.xml'), 'A'); // same session+group+action → throttled
  check('second Read meta same session → silent (throttle)', rMeta2.stdout === '', rMeta2.stdout);
  const rForm = read(join(SYNTH, 'Catalogs', 'Obj', 'Forms', 'F', 'Ext', 'Form.xml'), 'A');
  check('Read Form.xml (diff group) → form-info', /form-info/.test(grp(rForm) || ''), rForm.stdout);

  const rMxl = read(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Print', 'Ext', 'Template.xml'), 'B');
  check('Read spreadsheet Template → mxl-info', /mxl-info/.test(grp(rMxl) || ''), rMxl.stdout);
  const rSkd = edit(join(SYNTH, 'Catalogs', 'Obj', 'Templates', 'Scheme', 'Ext', 'Template.xml'), 'B');
  check('Edit DCS Template → skd-edit', /skd-edit/.test(grp(rSkd) || ''), rSkd.stdout);
  const rRole = read(join(SYNTH, 'Roles', 'R', 'Ext', 'Rights.xml'), 'B');
  check('Read Rights.xml → role-info', /role-info/.test(grp(rRole) || ''), rRole.stdout);

  const rCf = read(join(ACC, 'Configuration.xml'), 'C');
  check('Read base Configuration.xml → cf-info', /cf-info/.test(grp(rCf) || ''), rCf.stdout);
  const rCfe = read(join(SYNTH, 'ext', 'Configuration.xml'), 'C');
  check('Read extension Configuration.xml → cfe/cf-info', /cfe-diff|cf-info/.test(grp(rCfe) || ''), rCfe.stdout);
  const rCfeEdit = edit(join(SYNTH, 'ext', 'Configuration.xml'), 'C');
  check('Edit extension Configuration.xml → cfe-borrow/patch', /cfe-borrow|cfe-patch-method/.test(grp(rCfeEdit) || ''), rCfeEdit.stdout);

  // blind spots
  const rBsl = read(join(SYNTH, 'Catalogs', 'Obj', 'Ext', 'ObjectModule.bsl'), 'D');
  check('Read .bsl → silent', rBsl.stdout === '', rBsl.stdout);
  const rReadme = read(join(REPO, 'README.md'), 'D');
  check('Read non-1C file → silent', rReadme.stdout === '', rReadme.stdout);

  // search tools no longer nudge
  const rGrep = suggest({ tool_name: 'Grep', session_id: 'E', cwd: REPO, tool_input: { path: join(ACC, 'Catalogs'), pattern: 'foo' } }, { throttleDir: THR });
  check('Grep → silent (search trigger removed)', rGrep.stdout === '', rGrep.stdout);
  const rGlob = suggest({ tool_name: 'Glob', session_id: 'E', cwd: REPO, tool_input: { pattern: '**/Catalogs/*.xml' } }, { throttleDir: THR });
  check('Glob → silent (search trigger removed)', rGlob.stdout === '', rGlob.stdout);

  // skillSuggester off
  writeFileSync(join(SYNTH, '.v8-project.json'), JSON.stringify({ skillSuggester: 'off' }));
  const rOff = suggest({ tool_name: 'Read', session_id: 'F', cwd: SYNTH, tool_input: { file_path: join(SYNTH, 'Catalogs', 'Locked.xml') } }, { throttleDir: THR });
  check('suggest skillSuggester=off → silent', rOff.stdout === '', rOff.stdout);
  rmSync(join(SYNTH, '.v8-project.json'), { force: true });
}

console.log(`\n${fail === 0 ? 'ALL OK' : 'FAILURES'}: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
