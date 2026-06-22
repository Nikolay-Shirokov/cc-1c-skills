// platform-config.test.mjs — Integration test: load config into 1C platform
// Requires: 1C platform (1cv8.exe) via .v8-project.json
// Steps: cf-init → meta-compile → form-add → form-compile → cf-edit → db-create → db-load-xml → db-update

export const name = 'Загрузка конфигурации в платформу 1С';
export const setup = 'none';
export const requiresPlatform = true;
// Engine matrix: same load path must hold on DESIGNER (1cv8) and ibcmd.
// The ibcmd pass is skipped automatically when ibcmd.exe is not present.
export const engines = ['1cv8', 'ibcmd'];

export const steps = [
  // ── 1. Build minimal config ──
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'ПлатформенныйТест', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Справочник',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Catalog', name: 'Товары', codeLength: 9, descriptionLength: 100 },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Документ',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Document', name: 'Приход',
      attributes: [{ name: 'Склад', type: 'String', length: 50 }],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Перечисление',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Enum', name: 'Статусы', values: ['Новый', 'Выполнен'] },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'form-add: форма элемента справочника',
    script: 'form-add/scripts/form-add',
    args: {
      '-ObjectPath': '{workDir}/config/Catalogs/Товары',
      '-FormName': 'ФормаЭлемента',
      '-Purpose': 'Object',
    },
  },
  {
    name: 'form-compile: наполнение формы справочника',
    script: 'form-compile/scripts/form-compile',
    input: {
      elements: [
        { id: 'Код', type: 'input', path: 'Object.Code', title: 'Код' },
        { id: 'Наименование', type: 'input', path: 'Object.Description', title: 'Наименование' },
      ],
    },
    args: { '-OutputPath': '{workDir}/config/Catalogs/Товары/Forms/ФормаЭлемента/Ext/Form.xml', '-JsonPath': '{inputFile}' },
  },
  {
    name: 'form-add: форма документа',
    script: 'form-add/scripts/form-add',
    args: {
      '-ObjectPath': '{workDir}/config/Documents/Приход',
      '-FormName': 'ФормаДокумента',
      '-Purpose': 'Object',
    },
  },
  {
    name: 'form-compile: наполнение формы документа',
    script: 'form-compile/scripts/form-compile',
    input: {
      elements: [
        { id: 'Склад', type: 'input', path: 'Object.Склад', title: 'Склад' },
      ],
    },
    args: { '-OutputPath': '{workDir}/config/Documents/Приход/Forms/ФормаДокумента/Ext/Form.xml', '-JsonPath': '{inputFile}' },
  },
  {
    name: 'cf-edit: регистрация объектов',
    script: 'cf-edit/scripts/cf-edit',
    input: [
      { operation: 'add-childObject', value: 'Catalog.Товары' },
      { operation: 'add-childObject', value: 'Document.Приход' },
      { operation: 'add-childObject', value: 'Enum.Статусы' },
    ],
    args: { '-ConfigPath': '{workDir}/config', '-DefinitionFile': '{inputFile}' },
  },

  // ── 2. Create DB and load ──
  {
    name: 'db-create: создание файловой ИБ',
    script: 'db-create/scripts/db-create',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
    },
  },
  {
    name: 'db-load-xml: загрузка конфигурации',
    script: 'db-load-xml/scripts/db-load-xml',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
      '-ConfigDir': '{workDir}/config',
    },
  },
  {
    name: 'db-update: обновление БД',
    script: 'db-update/scripts/db-update',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
    },
  },
];
