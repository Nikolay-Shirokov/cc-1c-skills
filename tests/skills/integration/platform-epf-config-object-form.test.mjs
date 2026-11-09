// platform-epf-config-object-form.test.mjs — Integration test: EPF, чья форма ссылается на объекты конфигурации
// Requires: 1C platform (1cv8.exe) via .v8-project.json
// Заглушка получает реквизиты из путей формы; без базы и с проверками по умолчанию сборка должна пройти.

export const name = 'Сборка обработки с формой по объектам конфигурации (заглушки из путей формы)';
export const setup = 'none';
export const requiresPlatform = true;
export const engines = ['1cv8', 'ibcmd'];

const buildForm = (id, attributes, elements) => [
  {
    name: `epf-init: ${id}`,
    script: 'epf-init/scripts/init',
    args: { '-Name': id, '-SrcDir': `{workDir}/${id}` },
  },
  {
    name: `form-add: ${id}`,
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': `{workDir}/${id}/${id}.xml`, '-FormName': 'Форма' },
  },
  {
    name: `form-compile: ${id}`,
    script: 'form-compile/scripts/form-compile',
    input: { title: id, attributes, elements },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': `{workDir}/${id}/${id}/Forms/Форма/Ext/Form.xml` },
  },
  {
    name: `epf-build: ${id}`,
    script: 'epf-build/scripts/epf-build',
    args: { '-V8Path': '{v8path}', '-SourceFile': `{workDir}/${id}/${id}.xml`, '-OutputFile': `{workDir}/${id}.epf` },
  },
];

const field = (path) => ({ input: path.replaceAll('.', ''), path });
const main = (type) => ({ name: 'Объект', type, main: true });
const withTable = [field('Объект.Реквизит'), { table: 'ТЧ', path: 'Объект.ТЧ', columns: [field('Объект.ТЧ.Колонка')] }];

export const steps = [
  // Реквизиты, табличная часть, глубокий путь через ссылку, стандартные Parent и Owner, разные виды полей
  ...buildForm('ОсновнойСправочник', [main('CatalogObject.Контрагенты'), { name: 'Ссылка2', type: 'CatalogRef.Банки' }], [
    field('Объект.Реквизит'),
    { check: 'Флаг', path: 'Объект.Флаг' },
    field('Объект.Parent'),
    field('Объект.Owner'),
    field('Объект.Договор.Организация.ИНН'),
    field('Ссылка2.БИК'),
    { table: 'ТЧ', path: 'Объект.ТЧ', columns: [field('Объект.ТЧ.Колонка'), field('Объект.ТЧ.LineNumber')] },
  ]),
  ...buildForm('ОсновнойДокумент', [main('DocumentObject.Заказ')], withTable),
  // Шаблоны видов, заглушки которых раньше не загружались
  ...buildForm('ОсновнойПланСчетов', [main('ChartOfAccountsObject.Хозрасчетный')], withTable),
  ...buildForm('ОсновнойПВР', [main('ChartOfCalculationTypesObject.Начисления')], withTable),
  ...buildForm('ОсновнойБП', [main('BusinessProcessObject.Согласование')], withTable),
  ...buildForm('ОсновнаяЗадача', [main('TaskObject.Задача')], withTable),
  // Динамический список: основная таблица и поля из неё, в том числе с запросом и русским именем стандартного реквизита
  ...buildForm('СписокТаблица', [{ name: 'Список', type: 'DynamicList', main: true, settings: { mainTable: 'Catalog.Номенклатура' } }], [
    { table: 'Список', path: 'Список', columns: [field('Список.Ref'), field('Список.Артикул')] },
  ]),
  ...buildForm('СписокЗапрос', [{ name: 'Список', type: 'DynamicList', main: true, settings: {
    mainTable: 'Catalog.Номенклатура', query: 'ВЫБРАТЬ Т.Ссылка, Т.Артикул ИЗ Справочник.Номенклатура КАК Т',
  } }], [
    { table: 'Список', path: 'Список', columns: [field('Список.Ссылка'), field('Список.Артикул')] },
  ]),
  // Основная таблица списка — регистр
  ...buildForm('СписокРегистр', [{ name: 'Список', type: 'DynamicList', main: true, settings: { mainTable: 'InformationRegister.Цены' } }], [
    { table: 'Список', path: 'Список', columns: [field('Список.Цена')] },
  ]),
  // Глубокий путь через реквизит самой обработки и колонку таблицы значений; реквизиты родителя и ссылки
  { name: 'epf-init: СвойРеквизит', script: 'epf-init/scripts/init', args: { '-Name': 'СвойРеквизит', '-SrcDir': '{workDir}/СвойРеквизит' } },
  {
    name: 'meta-edit: реквизит-ссылка',
    script: 'meta-edit/scripts/meta-edit',
    args: { '-ObjectPath': '{workDir}/СвойРеквизит/СвойРеквизит.xml', '-Operation': 'add-attribute', '-Value': 'Контрагент: CatalogRef.Контрагенты' },
  },
  { name: 'form-add: СвойРеквизит', script: 'form-add/scripts/form-add', args: { '-ObjectPath': '{workDir}/СвойРеквизит/СвойРеквизит.xml', '-FormName': 'Форма' } },
  {
    name: 'form-compile: СвойРеквизит',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'СвойРеквизит',
      attributes: [
        main('ExternalDataProcessorObject.СвойРеквизит'),
        { name: 'Таблица', type: 'ValueTable', columns: [{ name: 'Банк', type: 'CatalogRef.Банки' }] },
        { name: 'Спр', type: 'CatalogRef.Банки' },
      ],
      elements: [
        field('Объект.Контрагент.ИНН'),
        field('Объект.Контрагент.Parent.Адрес'),
        field('Объект.Контрагент.IsFolder'),
        field('Спр.Ref.БИК'),
        { table: 'Таблица', path: 'Таблица', columns: [field('Таблица.Банк.БИК')] },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/СвойРеквизит/СвойРеквизит/Forms/Форма/Ext/Form.xml' },
  },
  {
    name: 'epf-build: СвойРеквизит',
    script: 'epf-build/scripts/epf-build',
    args: { '-V8Path': '{v8path}', '-SourceFile': '{workDir}/СвойРеквизит/СвойРеквизит.xml', '-OutputFile': '{workDir}/СвойРеквизит.epf' },
  },
];
