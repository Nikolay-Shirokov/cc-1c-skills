// platform-dump-modes.test.mjs — db-dump-xml Full / Changes / UpdateInfo on a real base.
// Guards the artifact postcondition (non-empty output dir) against false-fail in the
// less-common dump modes: each step succeeding proves the mode produces real output.
// 1cv8-only: ibcmd config export does not support Mode UpdateInfo.

export const name = 'Режимы выгрузки конфигурации (Full/Changes/UpdateInfo)';
export const setup = 'none';
export const requiresPlatform = true;

export const steps = [
  // ── 1. Build + load a minimal base ──
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'РежимыВыгрузки', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Справочник Товары',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Catalog', name: 'Товары', codeLength: 9, descriptionLength: 100 },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'cf-edit: регистрация справочника',
    script: 'cf-edit/scripts/cf-edit',
    input: [{ operation: 'add-childObject', value: 'Catalog.Товары' }],
    args: { '-ConfigPath': '{workDir}/config', '-DefinitionFile': '{inputFile}' },
  },
  {
    name: 'db-create: файловая ИБ',
    script: 'db-create/scripts/db-create',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb' },
  },
  {
    name: 'db-load-xml: загрузка конфигурации (Full)',
    script: 'db-load-xml/scripts/db-load-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/config' },
  },
  {
    name: 'db-update: обновление БД',
    script: 'db-update/scripts/db-update',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb' },
  },

  // ── 2. Full dump (baseline) → postcondition must pass on a real export ──
  {
    name: 'db-dump-xml: Full',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dumpA', '-Mode': 'Full' },
  },
  // ── 3. Changes dump into the same dir → must not false-fail ──
  {
    name: 'db-dump-xml: Changes',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dumpA', '-Mode': 'Changes' },
  },
  // ── 4. UpdateInfo into a FRESH dir → proves the mode alone yields non-empty output ──
  {
    name: 'db-dump-xml: UpdateInfo',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dumpB', '-Mode': 'UpdateInfo' },
  },
  {
    name: 'assert: UpdateInfo записал ConfigDumpInfo.xml',
    assertContains: '{workDir}/dumpB/ConfigDumpInfo.xml',
    expect: 'ConfigDumpInfo',
  },
];
