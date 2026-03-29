// build-epf.test.mjs — Integration test: build an external data processor (EPF) from scratch
// Steps: epf-init → epf-add-form → form-compile → template-add → mxl-compile → epf-validate

export const name = 'Сборка внешней обработки с нуля';
export const setup = 'none';

export const steps = [
  // ── 1. Init empty EPF ──
  {
    name: 'epf-init: пустая обработка ТестоваяОбработка',
    script: 'epf-init/scripts/init',
    args: { '-Name': 'ТестоваяОбработка', '-SrcDir': '{workDir}' },
    validate: { script: 'epf-validate/scripts/epf-validate', flag: '-ObjectPath', path: 'ТестоваяОбработка' },
  },

  // ── 2. Add form ──
  {
    name: 'epf-add-form: Форма к ТестоваяОбработка',
    script: 'epf-add-form/scripts/add-form',
    args: { '-ProcessorName': 'ТестоваяОбработка', '-FormName': 'Форма', '-SrcDir': '{workDir}' },
    validate: { script: 'epf-validate/scripts/epf-validate', flag: '-ObjectPath', path: 'ТестоваяОбработка' },
  },

  // ── 3. Compile form ──
  {
    name: 'form-compile: Форма с заголовком и полями ввода',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Тестовая обработка',
      attributes: [
        { name: 'Объект', type: 'FormDataStructure', main: true },
        { name: 'Наименование', type: 'String' },
        { name: 'Количество', type: 'Number' },
      ],
      elements: [
        { input: 'Наименование', path: 'Наименование', title: 'Наименование' },
        { input: 'Количество', path: 'Количество', title: 'Количество' },
      ],
    },
    args: {
      '-JsonPath': '{inputFile}',
      '-OutputPath': '{workDir}/ТестоваяОбработка/Forms/Форма/Ext/Form.xml',
    },
    validate: {
      script: 'form-validate/scripts/form-validate',
      flag: '-FormPath',
      path: 'ТестоваяОбработка/Forms/Форма/Ext/Form.xml',
    },
  },

  // ── 4. Add spreadsheet template ──
  {
    name: 'template-add: Макет к ТестоваяОбработка',
    script: 'template-add/scripts/add-template',
    args: {
      '-ObjectName': 'ТестоваяОбработка',
      '-TemplateName': 'Макет',
      '-TemplateType': 'SpreadsheetDocument',
      '-SrcDir': '{workDir}',
    },
  },

  // ── 5. Compile MXL template ──
  {
    name: 'mxl-compile: простой макет с двумя областями',
    script: 'mxl-compile/scripts/mxl-compile',
    input: {
      columns: 3,
      defaultWidth: 40,
      areas: [
        {
          name: 'Шапка',
          rows: [
            { cells: [
              { col: 1, span: 3, text: 'Заголовок документа' },
            ]},
          ],
        },
        {
          name: 'Строка',
          rows: [
            { cells: [
              { col: 1, param: 'НомерСтроки' },
              { col: 2, param: 'Наименование' },
              { col: 3, param: 'Сумма' },
            ]},
          ],
        },
      ],
    },
    args: {
      '-JsonPath': '{inputFile}',
      '-OutputPath': '{workDir}/ТестоваяОбработка/Templates/Макет/Ext/Template.xml',
    },
    validate: {
      script: 'mxl-validate/scripts/mxl-validate',
      flag: '-TemplatePath',
      path: 'ТестоваяОбработка/Templates/Макет/Ext/Template.xml',
    },
  },

  // ── 6. Final validation ──
  {
    name: 'epf-validate: Финальная валидация обработки',
    script: 'epf-validate/scripts/epf-validate',
    args: { '-ObjectPath': '{workDir}/ТестоваяОбработка' },
  },
];
