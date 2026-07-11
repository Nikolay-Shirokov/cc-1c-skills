// meta-edit-create-if-missing.test.mjs — Integration: create-if-missing свойства объекта
// Steps: cf-init → meta-compile Catalog → editFile (удалить DataHistory) → meta-edit modify-property
//        DataHistory=Use (свойство отсутствует → должно СОЗДАТЬСЯ, а не тихий no-op) → assertContains

export const name = 'meta-edit create-if-missing: пересоздание отсутствующего свойства объекта';
export const setup = 'none';

export const steps = [
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'ТестПравки', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Catalog Спр',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Catalog', name: 'Спр' },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'editFile: удалить свойство DataHistory (симуляция отсутствия)',
    editFile: '{workDir}/config/Catalogs/Спр.xml',
    replace: '<DataHistory>DontUse</DataHistory>',
    with: '',
  },
  {
    name: 'meta-edit: modify-property DataHistory=Use (create-if-missing)',
    script: 'meta-edit/scripts/meta-edit',
    input: { modify: { properties: { DataHistory: 'Use' } } },
    args: { '-DefinitionFile': '{inputFile}', '-ObjectPath': '{workDir}/config/Catalogs/Спр.xml' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'config/Catalogs/Спр.xml' },
  },
  {
    name: 'assertContains: DataHistory создан',
    assertContains: '{workDir}/config/Catalogs/Спр.xml',
    expect: '<DataHistory>Use</DataHistory>',
  },
];
