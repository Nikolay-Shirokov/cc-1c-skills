// platform-partial.test.mjs — partial dump/load round-trip with marker survival
// Requires: 1C platform (1cv8.exe) via .v8-project.json
// Exercises partial config import (Mode Partial -Files) and partial export
// (Mode Partial -Objects) on BOTH engines: DESIGNER (1cv8) and ibcmd. Proves a
// partially-loaded change actually propagates by round-tripping a marker
// (<Comment>ibtestMARK</Comment>). Mirrors the proven debug/ibtest/lifecycle.sh partial flow.

export const name = 'Частичная выгрузка/загрузка объекта (round-trip маркера)';
export const setup = 'none';
export const requiresPlatform = true;
// Engine matrix: partial round-trip must hold on DESIGNER (1cv8) and ibcmd.
export const engines = ['1cv8', 'ibcmd'];

export const steps = [
  // ── 1. Build minimal config ──
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'ИбcmdТест', '-OutputDir': '{workDir}/config' },
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

  // ── 2. Create file IB and load baseline (full, unmarked) via ibcmd ──
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

  // ── 3. Mark the source object, then partial-LOAD just that object ──
  {
    name: 'editFile: маркер в Comment справочника',
    editFile: '{workDir}/config/Catalogs/Товары.xml',
    replace: '<Comment/>',
    with: '<Comment>ibtestMARK</Comment>',
  },
  {
    name: 'db-load-xml: частичная загрузка Товары (Partial)',
    script: 'db-load-xml/scripts/db-load-xml',
    args: {
      '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb',
      '-ConfigDir': '{workDir}/config', '-Mode': 'Partial', '-Files': 'Catalogs/Товары.xml',
    },
  },
  {
    name: 'db-update: обновление БД (после partial load)',
    script: 'db-update/scripts/db-update',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb' },
  },

  // ── 4. Partial-DUMP the object back and verify the marker survived ──
  {
    name: 'db-dump-xml: частичная выгрузка Товары (Partial)',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: {
      '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb',
      '-ConfigDir': '{workDir}/pv', '-Mode': 'Partial', '-Objects': 'Справочник.Товары',
    },
  },
  {
    name: 'assert: маркер ibtestMARK пережил round-trip',
    assertContains: '{workDir}/pv/Catalogs/Товары.xml',
    expect: 'ibtestMARK',
  },
];
