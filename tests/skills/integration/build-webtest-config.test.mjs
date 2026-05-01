// build-webtest-config.test.mjs — Integration test: build synthetic configuration for web-test regression
// Extends base-config with: diverse field types, hierarchical catalog, two-tab form,
// second subsystem, full-rights role.
// Steps: cf-init → meta-compile → form-add + form-compile → skd-compile
//        → subsystem-compile → role-compile → cf-edit → cf-validate

export const name = 'Сборка конфигурации для web-test';
export const setup = 'none';
export const cache = 'webtest-config';

export const steps = [
  // ── 1. Init empty configuration ──
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'ТестоваяВебКонфигурация', '-OutputDir': '{workDir}' },
    validate: { script: 'cf-validate/scripts/cf-validate', flag: '-ConfigPath' },
  },

  // ── 2. Metadata objects ──

  // Справочник Контрагенты — простой, для CRUD и ссылочных полей
  {
    name: 'meta-compile: Справочник Контрагенты',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Catalog', name: 'Контрагенты',
      codeLength: 9, descriptionLength: 100,
      attributes: [
        { name: 'ИНН', type: 'String', length: 12 },
        { name: 'Телефон', type: 'String', length: 20 },
        { name: 'Адрес', type: 'String', length: 200 },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Catalogs/Контрагенты' },
  },

  // Справочник Номенклатура — иерархический, все типы полей
  {
    name: 'meta-compile: Справочник Номенклатура',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Catalog', name: 'Номенклатура',
      codeLength: 11, descriptionLength: 150,
      hierarchical: true,
      attributes: [
        { name: 'Артикул', type: 'String', length: 25 },
        { name: 'Цена', type: 'Number', length: 15, precision: 2 },
        { name: 'Активен', type: 'Boolean' },
        { name: 'ДатаПоступления', type: 'Date' },
        { name: 'Комментарий', type: 'String' },
        { name: 'ЕдиницаИзмерения', type: 'String', length: 10 },
      ],
      fillChecking: { 'Description': 'ShowError' },
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Catalogs/Номенклатура' },
  },

  // Перечисление ВидыНоменклатуры
  {
    name: 'meta-compile: Перечисление ВидыНоменклатуры',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Enum', name: 'ВидыНоменклатуры',
      values: ['Товар', 'Услуга', 'Работа'],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Enums/ВидыНоменклатуры' },
  },

  // Документ ПриходнаяНакладная — шапка + ТЧ
  {
    name: 'meta-compile: Документ ПриходнаяНакладная',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Document', name: 'ПриходнаяНакладная',
      attributes: [
        { name: 'Контрагент', type: 'String', length: 100 },
        { name: 'Склад', type: 'String', length: 50 },
        { name: 'Комментарий', type: 'String', length: 200 },
      ],
      tabularSections: [{
        name: 'Товары',
        attributes: [
          { name: 'Номенклатура', type: 'String', length: 150 },
          { name: 'Количество', type: 'Number', length: 15, precision: 3 },
          { name: 'Цена', type: 'Number', length: 15, precision: 2 },
          { name: 'Сумма', type: 'Number', length: 15, precision: 2 },
        ],
      }],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Documents/ПриходнаяНакладная' },
  },

  // Регистр сведений КурсыВалют (Independent — без регистратора)
  {
    name: 'meta-compile: Регистр сведений КурсыВалют',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'InformationRegister', name: 'КурсыВалют',
      writeMode: 'Independent',
      dimensions: [
        { name: 'Валюта', type: 'String', length: 10 },
      ],
      resources: [
        { name: 'Курс', type: 'Number', length: 10, precision: 4 },
        { name: 'Кратность', type: 'Number', length: 10 },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'InformationRegisters/КурсыВалют' },
  },

  // Константа ОсновнаяВалюта
  {
    name: 'meta-compile: Константа ОсновнаяВалюта',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Constant', name: 'ОсновнаяВалюта',
      valueType: 'String', length: 10,
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Constants/ОсновнаяВалюта' },
  },

  // Общий модуль ОбщиеФункции
  {
    name: 'meta-compile: Общий модуль ОбщиеФункции',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'CommonModule', name: 'ОбщиеФункции',
      server: true, clientManagedApplication: false,
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'CommonModules/ОбщиеФункции' },
  },

  // Отчёт ОстаткиТоваров
  {
    name: 'meta-compile: Отчёт ОстаткиТоваров',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Report', name: 'ОстаткиТоваров',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Reports/ОстаткиТоваров' },
  },

  // ── 3. Forms ──

  // Форма элемента Контрагенты — простая
  {
    name: 'form-add: Форма элемента Контрагенты',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/Контрагенты.xml', '-FormName': 'ФормаЭлемента' },
  },
  {
    name: 'form-compile: Форма элемента Контрагенты',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Контрагент',
      attributes: [
        { name: 'Объект', type: 'CatalogObject.Контрагенты', main: true },
      ],
      elements: [
        { input: 'Наименование', path: 'Объект.Description', title: 'Наименование' },
        { input: 'ИНН', path: 'Объект.ИНН', title: 'ИНН' },
        { input: 'Телефон', path: 'Объект.Телефон', title: 'Телефон' },
        { input: 'Адрес', path: 'Объект.Адрес', title: 'Адрес' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Контрагенты/Forms/ФормаЭлемента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Контрагенты/Forms/ФормаЭлемента/Ext/Form.xml' },
  },

  // Форма элемента Номенклатура — 2 вкладки, все типы полей
  {
    name: 'form-add: Форма элемента Номенклатура',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/Номенклатура.xml', '-FormName': 'ФормаЭлемента' },
  },
  {
    name: 'form-compile: Форма элемента Номенклатура (2 вкладки)',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Номенклатура',
      attributes: [
        { name: 'Объект', type: 'CatalogObject.Номенклатура', main: true },
      ],
      elements: [
        { pages: 'Страницы', children: [
          { page: 'Основное', children: [
            { input: 'Наименование', path: 'Объект.Description', title: 'Наименование' },
            { input: 'Артикул', path: 'Объект.Артикул', title: 'Артикул' },
            { input: 'Цена', path: 'Объект.Цена', title: 'Цена' },
            { input: 'Активен', path: 'Объект.Активен', title: 'Активен' },
            { input: 'ДатаПоступления', path: 'Объект.ДатаПоступления', title: 'Дата поступления' },
          ]},
          { page: 'Дополнительно', children: [
            { input: 'ЕдиницаИзмерения', path: 'Объект.ЕдиницаИзмерения', title: 'Единица измерения' },
            { input: 'Комментарий', path: 'Объект.Комментарий', title: 'Комментарий' },
          ]},
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Номенклатура/Forms/ФормаЭлемента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Номенклатура/Forms/ФормаЭлемента/Ext/Form.xml' },
  },

  // Форма документа ПриходнаяНакладная
  {
    name: 'form-add: Форма документа ПриходнаяНакладная',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Documents/ПриходнаяНакладная.xml', '-FormName': 'ФормаДокумента' },
  },
  {
    name: 'form-compile: Форма документа ПриходнаяНакладная',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Приходная накладная',
      attributes: [
        { name: 'Объект', type: 'DocumentObject.ПриходнаяНакладная', main: true },
      ],
      elements: [
        { input: 'Контрагент', path: 'Объект.Контрагент', title: 'Контрагент' },
        { input: 'Склад', path: 'Объект.Склад', title: 'Склад' },
        { input: 'Комментарий', path: 'Объект.Комментарий', title: 'Комментарий' },
        { table: 'Товары', path: 'Объект.Товары', title: 'Товары', columns: [
          { input: 'Номенклатура', path: 'Объект.Товары.Номенклатура', title: 'Номенклатура' },
          { input: 'Количество', path: 'Объект.Товары.Количество', title: 'Количество' },
          { input: 'Цена', path: 'Объект.Товары.Цена', title: 'Цена' },
          { input: 'Сумма', path: 'Объект.Товары.Сумма', title: 'Сумма' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Documents/ПриходнаяНакладная/Forms/ФормаДокумента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Documents/ПриходнаяНакладная/Forms/ФормаДокумента/Ext/Form.xml' },
  },

  // ── 4. DCS for report ──
  {
    name: 'skd-compile: Схема отчёта ОстаткиТоваров',
    script: 'skd-compile/scripts/skd-compile',
    input: {
      dataSets: [{
        name: 'НаборДанных',
        type: 'Query',
        query: 'SELECT Номенклатура, Количество, Цена, Сумма FROM Document.ПриходнаяНакладная.Товары',
      }],
      fields: [
        { name: 'Номенклатура', title: 'Номенклатура' },
        { name: 'Количество', title: 'Количество' },
        { name: 'Цена', title: 'Цена' },
        { name: 'Сумма', title: 'Сумма' },
      ],
    },
    args: { '-DefinitionFile': '{inputFile}', '-OutputPath': '{workDir}/Reports/ОстаткиТоваров/Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml' },
    validate: { script: 'skd-validate/scripts/skd-validate', flag: '-TemplatePath', path: 'Reports/ОстаткиТоваров/Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml' },
  },

  // ── 5. Subsystems ──
  {
    name: 'subsystem-compile: Подсистема Склад',
    script: 'subsystem-compile/scripts/subsystem-compile',
    input: {
      name: 'Склад',
      synonym: 'Склад',
      content: [
        'Catalog.Контрагенты',
        'Catalog.Номенклатура',
        'Document.ПриходнаяНакладная',
        'Report.ОстаткиТоваров',
      ],
    },
    args: { '-DefinitionFile': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'subsystem-validate/scripts/subsystem-validate', flag: '-SubsystemPath', path: 'Subsystems/Склад' },
  },
  {
    name: 'subsystem-compile: Подсистема Администрирование',
    script: 'subsystem-compile/scripts/subsystem-compile',
    input: {
      name: 'Администрирование',
      synonym: 'Администрирование',
      content: [
        'InformationRegister.КурсыВалют',
        'Constant.ОсновнаяВалюта',
      ],
    },
    args: { '-DefinitionFile': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'subsystem-validate/scripts/subsystem-validate', flag: '-SubsystemPath', path: 'Subsystems/Администрирование' },
  },

  // ── 6. Role with full rights ──
  {
    name: 'role-compile: Роль Администратор',
    script: 'role-compile/scripts/role-compile',
    input: {
      name: 'Администратор',
      objects: [
        'Catalog.Контрагенты: Read View Add Update Delete',
        'Catalog.Номенклатура: Read View Add Update Delete',
        'Document.ПриходнаяНакладная: Read View Add Update Delete Posting UnPosting',
        'InformationRegister.КурсыВалют: Read View Add Update Delete',
        'Report.ОстаткиТоваров: Use View',
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'role-validate/scripts/role-validate', flag: '-RightsPath', path: 'Roles/Администратор' },
  },

  // ── 7. Register all objects in Configuration.xml ──
  {
    name: 'cf-edit: Регистрация объектов в конфигурации',
    script: 'cf-edit/scripts/cf-edit',
    input: [
      { operation: 'add-childObject', value: 'Catalog.Контрагенты' },
      { operation: 'add-childObject', value: 'Catalog.Номенклатура' },
      { operation: 'add-childObject', value: 'Enum.ВидыНоменклатуры' },
      { operation: 'add-childObject', value: 'Document.ПриходнаяНакладная' },
      { operation: 'add-childObject', value: 'InformationRegister.КурсыВалют' },
      { operation: 'add-childObject', value: 'Constant.ОсновнаяВалюта' },
      { operation: 'add-childObject', value: 'CommonModule.ОбщиеФункции' },
      { operation: 'add-childObject', value: 'Report.ОстаткиТоваров' },
      { operation: 'add-childObject', value: 'Subsystem.Склад' },
      { operation: 'add-childObject', value: 'Subsystem.Администрирование' },
      { operation: 'add-childObject', value: 'Role.Администратор' },
    ],
    args: { '-ConfigPath': '{workDir}', '-DefinitionFile': '{inputFile}' },
  },

  // ── 8. Final validation ──
  {
    name: 'cf-validate: Финальная валидация конфигурации',
    script: 'cf-validate/scripts/cf-validate',
    args: { '-ConfigPath': '{workDir}' },
  },
];
