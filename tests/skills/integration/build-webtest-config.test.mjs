// build-webtest-config.test.mjs — Integration test: build synthetic configuration for web-test regression
// Extends base-config with: diverse field types, hierarchical catalog, two-tab form,
// second subsystem, full-rights role.
// Steps: cf-init → meta-compile → form-add + form-compile → skd-compile
//        → subsystem-compile → role-compile → cf-validate

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
        { name: 'КодКПП', type: 'String', length: 9 },
        // Доп. строковые реквизиты — выводятся в широкую ФОРМУ ВЫБОРА (ниже),
        // чтобы строка формы выбора стала шире окна выбора. Регресс бага
        // «центр широкой строки уезжает за вьюпорт → клик мимо» (04-selectvalue).
        { name: 'Регион', type: 'String', length: 50 },
        { name: 'Город', type: 'String', length: 50 },
        { name: 'Улица', type: 'String', length: 100 },
        { name: 'БИК', type: 'String', length: 9 },
        { name: 'ОГРН', type: 'String', length: 13 },
        { name: 'ОКПО', type: 'String', length: 10 },
        { name: 'ВидДеятельности', type: 'String', length: 100 },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Catalogs/Контрагенты' },
  },

  // Справочник Организации — маленький список с быстрым выбором (selectValue dropdown)
  {
    name: 'meta-compile: Справочник Организации',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Catalog', name: 'Организации',
      codeLength: 9, descriptionLength: 100,
      quickChoice: true,
      attributes: [
        { name: 'ИНН', type: 'String', length: 12 },
        { name: 'КПП', type: 'String', length: 9 },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Catalogs/Организации' },
  },

  // Подчинённый каталог КонтактныеЛица — для теста getFormState.navigation (subordinate-nav)
  {
    name: 'meta-compile: Справочник КонтактныеЛица (подчинённый Контрагентам)',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Catalog', name: 'КонтактныеЛица',
      codeLength: 9, descriptionLength: 100,
      owners: ['Catalog.Контрагенты'],
      attributes: [
        { name: 'Должность', type: 'String', length: 100 },
        { name: 'Телефон', type: 'String', length: 20 },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Catalogs/КонтактныеЛица' },
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
        { name: 'ВидНоменклатуры', type: 'EnumRef.ВидыНоменклатуры' },
        { name: 'КатегорияЦены', type: 'EnumRef.КатегорииЦен' },
        { name: 'СпособУчёта', type: 'EnumRef.СпособыУчёта' },
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

  // Перечисление КатегорииЦен — для будущего radio-button теста (fillFields branch #3)
  {
    name: 'meta-compile: Перечисление КатегорииЦен',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Enum', name: 'КатегорииЦен',
      values: ['Розничная', 'Оптовая', 'Закупочная'],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Enums/КатегорииЦен' },
  },

  // Перечисление СпособыУчёта — для radio с видом Tumbler (fillFields branch #3)
  {
    name: 'meta-compile: Перечисление СпособыУчёта',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Enum', name: 'СпособыУчёта',
      values: ['ПоСреднему', 'ФИФО'],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Enums/СпособыУчёта' },
  },

  // Перечисление СтавкиНДС — для реквизита СтавкаНДС в ТЧ Товары (18-cell-click)
  {
    name: 'meta-compile: Перечисление СтавкиНДС',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Enum', name: 'СтавкиНДС',
      values: ['БезНДС', 'НДС0', 'НДС10', 'НДС20'],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Enums/СтавкиНДС' },
  },

  // Документ ПриходнаяНакладная — шапка + ТЧ
  {
    name: 'meta-compile: Документ ПриходнаяНакладная',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Document', name: 'ПриходнаяНакладная',
      attributes: [
        { name: 'Организация', type: 'CatalogRef.Организации' },
        // choiceHistoryOnInput=DontUse: предотвращает выбор через историю в smoke-тестах
        // (04-selectvalue/direct-form проверяет open-form path; история обходит его).
        { name: 'Контрагент', type: 'CatalogRef.Контрагенты', choiceHistoryOnInput: 'DontUse' },
        { name: 'Склад', type: 'String', length: 50 },
        // Источник — составной тип (для 03-fillfields/composite).
        // Платформа покажет селектор типа в UI перед выбором значения.
        { name: 'Источник', type: 'CatalogRef.Контрагенты + CatalogRef.Номенклатура + CatalogRef.Организации' },
        // Поставщик — обычная ссылка, но на форме элемент с textEdit:false
        // (для 03-fillfields/direct-edit-form). Ручной ввод запрещён,
        // выбор только через pick-кнопку → форма выбора.
        { name: 'Поставщик', type: 'CatalogRef.Контрагенты' },
        // Менеджер — ссылка с дефолтным choiceHistoryOnInput=Auto (история включена,
        // для 04-selectvalue/show-all-form). После первого выбора платформа
        // запоминает значение и при повторном вводе показывает dropdown
        // с историей + кнопку «Показать все» → форма выбора.
        { name: 'Менеджер', type: 'CatalogRef.Контрагенты' },
        { name: 'Комментарий', type: 'String', length: 200 },
      ],
      tabularSections: [{
        name: 'Товары',
        // Существующие 6 реквизитов оставлены в начале (05-table / 06-document
        // полагаются на их позицию). Ниже добавлены ~12 новых для тестов
        // 18-cell-click: ширина для horizontal scroll, кластер из 3 boolean
        // подряд и финальный boolean в конце — для проверки что focus-click
        // умеет пропускать checkbox-ячейки при выборе edge-cell.
        attributes: [
          { name: 'Номенклатура', type: 'CatalogRef.Номенклатура' },
          { name: 'Количество', type: 'Number', length: 15, precision: 3 },
          { name: 'Цена', type: 'Number', length: 15, precision: 2 },
          { name: 'Сумма', type: 'Number', length: 15, precision: 2 },
          { name: 'Согласовано', type: 'Boolean' },
          // Источник — составной тип в ТЧ (для edit-dblclick через выбор типа)
          { name: 'Источник', type: 'CatalogRef.Контрагенты + CatalogRef.Номенклатура + CatalogRef.Организации' },
          // Кластер из 3 boolean сразу после Источник — при дефолтном открытии
          // формы они оказываются у правого края viewport. Это нужно для теста
          // «focus-click при horizontal scroll пропускает checkbox-ячейки».
          { name: 'ВРезерве', type: 'Boolean' },
          { name: 'НаКомиссии', type: 'Boolean' },
          { name: 'Подарок', type: 'Boolean' },
          // Дальше — text/number/enum для ширины и разнообразия типов.
          { name: 'Единица', type: 'String', length: 10 },
          { name: 'Скидка', type: 'Number', length: 10, precision: 2 },
          { name: 'СтавкаНДС', type: 'EnumRef.СтавкиНДС' },
          { name: 'СуммаСНДС', type: 'Number', length: 15, precision: 2 },
          { name: 'Серия', type: 'String', length: 25 },
          { name: 'НомерГТД', type: 'String', length: 25 },
          { name: 'СтранаПроисхождения', type: 'String', length: 50 },
          { name: 'СрокГодности', type: 'Date' },
          // Последняя колонка — тоже boolean (edge-case: самая крайняя = checkbox).
          { name: 'ПризнакКонтроля', type: 'Boolean' },
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

  // Константа ДанныеЗаполнены — флаг первоначального заполнения фикстур
  {
    name: 'meta-compile: Константа ДанныеЗаполнены',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'Constant', name: 'ДанныеЗаполнены',
      valueType: 'Boolean',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'Constants/ДанныеЗаполнены' },
  },

  // Общий модуль ОбщиеФункции
  {
    name: 'meta-compile: Общий модуль ОбщиеФункции',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'CommonModule', name: 'ОбщиеФункции',
      server: true, serverCall: true, clientManagedApplication: false,
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'CommonModules/ОбщиеФункции' },
  },
  {
    name: 'writeFile: ОбщиеФункции Module.bsl',
    writeFile: 'CommonModules/ОбщиеФункции/Ext/Module.bsl',
    content: `Процедура ПоказатьСообщение() Экспорт
\tСообщить("Тестовое сообщение");
КонецПроцедуры

Процедура ВызватьТестовоеИсключение() Экспорт
\tВызватьИсключение "Тестовое исключение";
КонецПроцедуры

Процедура ЗаполнитьФикстурыЕслиНужно() Экспорт
\tЕсли Константы.ДанныеЗаполнены.Получить() Тогда
\t\tВозврат;
\tКонецЕсли;
\tНачатьТранзакцию();
\tПопытка
\t\tЗаполнитьОрганизации();
\t\tЗаполнитьКонтрагентов();
\t\tЗаполнитьНоменклатуру();
\t\tЗаполнитьДокументы();
\t\tКонстанты.ДанныеЗаполнены.Установить(Истина);
\t\tЗафиксироватьТранзакцию();
\tИсключение
\t\tОтменитьТранзакцию();
\t\tВызватьИсключение;
\tКонецПопытки;
КонецПроцедуры

Процедура ЗаполнитьОрганизации()
\tСписок = Новый Массив;
\tСписок.Добавить(Новый Структура("Имя,ИНН,КПП", "Альфа", "7800000001", "780000001"));
\tСписок.Добавить(Новый Структура("Имя,ИНН,КПП", "Бета",  "7800000002", "780000002"));
\tДля Каждого Запись Из Список Цикл
\t\tЭлемент = Справочники.Организации.СоздатьЭлемент();
\t\tЭлемент.Наименование = Запись.Имя;
\t\tЭлемент.ИНН = Запись.ИНН;
\t\tЭлемент.КПП = Запись.КПП;
\t\tЭлемент.Записать();
\tКонецЦикла;
КонецПроцедуры

Процедура ЗаполнитьКонтрагентов()
\tСписок = Новый Массив;
\tСписок.Добавить(Новый Структура("Имя,ИНН", "ООО Север", "7700000001"));
\tСписок.Добавить(Новый Структура("Имя,ИНН", "ООО Юг", "7700000002"));
\tСписок.Добавить(Новый Структура("Имя,ИНН", "ООО Восток", "7700000003"));
\tСписок.Добавить(Новый Структура("Имя,ИНН", "АО Запад", "7700000004"));
\t// Контрагент с именем ровно «Север» рядом с «ООО Север» — для детерминированного
\t// регресса широкой формы выбора (04-selectvalue): поиск «Север» даёт 2 вхождения,
\t// «ООО Север» сортируется раньше. Багованный клик-по-центру/эскалация выберут
\t// «ООО Север»; фикс через exact-preference обязан выбрать точное «Север».
\tСписок.Добавить(Новый Структура("Имя,ИНН", "Север", "7700000005"));
\tДля Каждого Запись Из Список Цикл
\t\tЭлемент = Справочники.Контрагенты.СоздатьЭлемент();
\t\tЭлемент.Наименование = Запись.Имя;
\t\tЭлемент.ИНН = Запись.ИНН;
\t\tЭлемент.Записать();
\tКонецЦикла;
КонецПроцедуры

Процедура ЗаполнитьНоменклатуру()
\tГруппаТовары = СоздатьГруппуНоменклатуры("Товары");
\tГруппаУслуги = СоздатьГруппуНоменклатуры("Услуги");
\t// 15 товаров — для существующих тестов (05/06/08/12), которые предполагают
\t// что обе группы помещаются в DOM-окно с развёрнутыми элементами.
\tДля Сч = 1 По 15 Цикл
\t\tЭлемент = Справочники.Номенклатура.СоздатьЭлемент();
\t\tЭлемент.Родитель = ГруппаТовары;
\t\tЭлемент.Наименование = "Товар " + Формат(Сч, "ЧЦ=2; ЧВН=");
\t\tЭлемент.Артикул = "T" + Формат(Сч, "ЧЦ=4; ЧВН=");
\t\tЭлемент.Цена = 100 * Сч;
\t\tЭлемент.Активен = Истина;
\t\tЭлемент.ВидНоменклатуры = Перечисления.ВидыНоменклатуры.Товар;
\t\tЭлемент.Записать();
\tКонецЦикла;
\t// Элемент С ПОМЕТКОЙ УДАЛЕНИЯ — для теста ведущей иконки состояния строки (22-row-state).
\t// Внутри группы Товары, а не на верхнем уровне: 08-hierarchy проверяет ровно 3 группы сверху.
\tПомеченный = Справочники.Номенклатура.СоздатьЭлемент();
\tПомеченный.Родитель = ГруппаТовары;
\tПомеченный.Наименование = "Товар помеченный";
\tПомеченный.Артикул = "TDEL1";
\tПомеченный.Цена = 999;
\tПомеченный.Активен = Истина;
\tПомеченный.ВидНоменклатуры = Перечисления.ВидыНоменклатуры.Товар;
\tПомеченный.Записать();
\tПомеченный.Ссылка.ПолучитьОбъект().УстановитьПометкуУдаления(Истина);
\tДля Сч = 1 По 10 Цикл
\t\tЭлемент = Справочники.Номенклатура.СоздатьЭлемент();
\t\tЭлемент.Родитель = ГруппаУслуги;
\t\tЭлемент.Наименование = "Услуга " + Формат(Сч, "ЧЦ=2; ЧВН=");
\t\tЭлемент.Артикул = "U" + Формат(Сч, "ЧЦ=4; ЧВН=");
\t\tЭлемент.Цена = 500 * Сч;
\t\tЭлемент.Активен = Истина;
\t\tЭлемент.ВидНоменклатуры = Перечисления.ВидыНоменклатуры.Услуга;
\t\tЭлемент.Записать();
\tКонецЦикла;
\t// Третья группа БольшойСписок с 60 элементами — заведомо больше окна
\t// виртуализации (~22-30 строк), для тестов reveal-loop и hasMore.above
\t// на динамическом списке. Существующие тесты её не трогают.
\tГруппаБольшойСписок = СоздатьГруппуНоменклатуры("БольшойСписок");
\tДля Сч = 1 По 60 Цикл
\t\tЭлемент = Справочники.Номенклатура.СоздатьЭлемент();
\t\tЭлемент.Родитель = ГруппаБольшойСписок;
\t\tЭлемент.Наименование = "Позиция " + Формат(Сч, "ЧЦ=3; ЧВН=");
\t\tЭлемент.Артикул = "P" + Формат(Сч, "ЧЦ=5; ЧВН=");
\t\tЭлемент.Цена = 10 * Сч;
\t\tЭлемент.Активен = Истина;
\t\tЭлемент.ВидНоменклатуры = Перечисления.ВидыНоменклатуры.Товар;
\t\tЭлемент.Записать();
\tКонецЦикла;
КонецПроцедуры

Функция СоздатьГруппуНоменклатуры(Имя)
\tГруппа = Справочники.Номенклатура.СоздатьГруппу();
\tГруппа.Наименование = Имя;
\tГруппа.Записать();
\tВозврат Группа.Ссылка;
КонецФункции

Процедура ЗаполнитьДокументы()
\tЗапросК = Новый Запрос("ВЫБРАТЬ ПЕРВЫЕ 5 Контрагенты.Ссылка КАК Контрагент ИЗ Справочник.Контрагенты КАК Контрагенты");
\tКонтрагенты = ЗапросК.Выполнить().Выгрузить().ВыгрузитьКолонку("Контрагент");
\tЗапросН = Новый Запрос("ВЫБРАТЬ ПЕРВЫЕ 10 Номенклатура.Ссылка КАК Номенклатура ИЗ Справочник.Номенклатура КАК Номенклатура ГДЕ НЕ Номенклатура.ЭтоГруппа");
\tНоменклатура = ЗапросН.Выполнить().Выгрузить().ВыгрузитьКолонку("Номенклатура");
\tЕсли Контрагенты.Количество() = 0 Или Номенклатура.Количество() = 0 Тогда
\t\tВозврат;
\tКонецЕсли;
\tЗапросО = Новый Запрос("ВЫБРАТЬ ПЕРВЫЕ 1 Организации.Ссылка КАК Организация ИЗ Справочник.Организации КАК Организации");
\tВыборкаО = ЗапросО.Выполнить().Выбрать();
\tОрганизация = Неопределено;
\tЕсли ВыборкаО.Следующий() Тогда
\t\tОрганизация = ВыборкаО.Организация;
\tКонецЕсли;
\tДля Сч = 1 По 3 Цикл
\t\tДок = Документы.ПриходнаяНакладная.СоздатьДокумент();
\t\tДок.Дата = ТекущаяДата();
\t\tДок.Организация = Организация;
\t\tДок.Контрагент = Контрагенты[(Сч - 1) % Контрагенты.Количество()];
\t\tДок.Склад = "Основной";
\t\tДля Поз = 1 По 3 Цикл
\t\t\tСтрока = Док.Товары.Добавить();
\t\t\tСтрока.Номенклатура = Номенклатура[(Сч * Поз) % Номенклатура.Количество()];
\t\t\tСтрока.Количество = Поз * 10;
\t\t\tСтрока.Цена = Поз * 100;
\t\t\tСтрока.Сумма = Строка.Количество * Строка.Цена;
\t\tКонецЦикла;
\t\tДок.Записать(РежимЗаписиДокумента.Запись);
\tКонецЦикла;
\t// Длинный документ — 30 строк для тестов виртуализации / reveal-loop (18-cell-click).
\t// Комментарий "LongDoc" — селектор для тестов, чтобы найти именно этот документ.
\tДокДлинный = Документы.ПриходнаяНакладная.СоздатьДокумент();
\tДокДлинный.Дата = ТекущаяДата();
\tДокДлинный.Организация = Организация;
\tДокДлинный.Контрагент = Контрагенты[0];
\tДокДлинный.Склад = "Основной";
\tДокДлинный.Комментарий = "LongDoc";
\tДля Поз = 1 По 30 Цикл
\t\tСтрока = ДокДлинный.Товары.Добавить();
\t\tСтрока.Номенклатура = Номенклатура[Поз % Номенклатура.Количество()];
\t\tСтрока.Количество = Поз;
\t\tСтрока.Цена = 50;
\t\tСтрока.Сумма = Строка.Количество * Строка.Цена;
\tКонецЦикла;
\tДокДлинный.Записать(РежимЗаписиДокумента.Запись);
\tЗаполнитьДокументыСостояний(Организация, Контрагенты, Номенклатура);
КонецПроцедуры

// Документы в ЗАДАННЫХ состояниях — для теста ведущей иконки состояния строки (22-row-state).
// Ищутся по Комментарий, не по позиции: список сортируется по дате, порядок не гарантирован.
Процедура ЗаполнитьДокументыСостояний(Организация, Контрагенты, Номенклатура)
\tСостояния = Новый Массив;
\tСостояния.Добавить("StatePosted");
\tСостояния.Добавить("StateDeleted");
\tСостояния.Добавить("StateWritten");
\tДля Каждого Состояние Из Состояния Цикл
\t\tДок = Документы.ПриходнаяНакладная.СоздатьДокумент();
\t\tДок.Дата = ТекущаяДата();
\t\tДок.Организация = Организация;
\t\tДок.Контрагент = Контрагенты[0];
\t\tДок.Склад = "Основной";
\t\tДок.Комментарий = Состояние;
\t\tСтрока = Док.Товары.Добавить();
\t\tСтрока.Номенклатура = Номенклатура[0];
\t\tСтрока.Количество = 1;
\t\tСтрока.Цена = 100;
\t\tСтрока.Сумма = 100;
\t\tЕсли Состояние = "StatePosted" Тогда
\t\t\tДок.Записать(РежимЗаписиДокумента.Проведение);
\t\tИначе
\t\t\tДок.Записать(РежимЗаписиДокумента.Запись);
\t\t\tЕсли Состояние = "StateDeleted" Тогда
\t\t\t\tДок.Ссылка.ПолучитьОбъект().УстановитьПометкуУдаления(Истина);
\t\t\tКонецЕсли;
\t\tКонецЕсли;
\tКонецЦикла;
КонецПроцедуры
`,
  },

  // ManagedApplicationModule — вызывает заполнение фикстур при первом запуске
  {
    name: 'writeFile: ManagedApplicationModule.bsl',
    writeFile: 'Ext/ManagedApplicationModule.bsl',
    content: `&НаКлиенте
Процедура ПриНачалеРаботыСистемы()
\tОбщиеФункции.ЗаполнитьФикстурыЕслиНужно();
КонецПроцедуры
`,
  },

  // Раскладка панелей (Ext/ClientApplicationInterface.xml) теперь создаётся
  // самим cf-init с ERP-дефолтом — отдельная запись больше не нужна.

  // Обработка ТестовыеОшибки — для тестов errors balloon/messages/modal (10-validation)
  {
    name: 'meta-compile: Обработка ТестовыеОшибки',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'ТестовыеОшибки',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/ТестовыеОшибки' },
  },

  // Обработка ДеревоНоменклатуры — реквизит формы ДеревоЗначений с данными
  // справочника Номенклатура для тестов tree-grid (05-table/direct-edit-form,
  // 08-hierarchy/tree-edit).
  {
    name: 'meta-compile: Обработка ДеревоНоменклатуры',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'ДеревоНоменклатуры',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/ДеревоНоменклатуры' },
  },

  // Обработка МножественныйВыбор — поля ввода типа «список значений» (ValueList)
  // для тестов мультивыбора. Основная форма: 4 поля (Организации/Контрагенты —
  // штатный редактор платформы; ЧерезФлажки/ЧерезПодбор — через StartChoice
  // открывают вторую форму ФормаВводаЗначений). Вторая форма — обрезанный порт
  // БСП «ВводЗначенийСпискомСФлажками»: безшапочная таблица Check+Value, Подбор/
  // Установить-Снять флажки, ОК/Отмена. Режим A (предзагрузка кандидатов + флажки,
  // без Подбора) vs B (пул + Подбор → каталог) решается по СпособВыбора типа значений.
  {
    name: 'meta-compile: Обработка МножественныйВыбор',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'МножественныйВыбор',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/МножественныйВыбор' },
  },

  // Обработка БезшапочнаяТаблица — обычная редактируемая таблица значений со скрытой
  // шапкой (<Header>false</Header>) для регресса безшапочных гридов (deriveGridColumns):
  // чтение (readTable), заполнение строк (fillTableRow) и клик по строке. Колонки разных
  // типов: ссылка / число / булево (чекбокс).
  {
    name: 'meta-compile: Обработка БезшапочнаяТаблица',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'БезшапочнаяТаблица',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/БезшапочнаяТаблица' },
  },

  // Обработка МногострочнаяШапка — грид с ДВУХЭТАЖНОЙ шапкой, для регресса резолвинга колонок
  // (24-multirow-header). Воспроизводит два паттерна, снятые с ERP:
  //   1) «Задачи» — широкая колонка сверху над парой узких: центр широкой ячейки попадает в
  //      x-диапазон ПРАВОЙ узкой шапки, и матчинг по геометрии ворует ячейку;
  //   2) «Операция» — объединённая шапка над несколькими под-рядами: законный разворот в
  //      «Имя 1/2/3», который ломать нельзя.
  {
    name: 'meta-compile: Обработка МногострочнаяШапка',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'МногострочнаяШапка',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/МногострочнаяШапка' },
  },

  // Обработка ПроверкаДоступности — форма с парами «доступный / недоступный»
  // элементов каждого типа (кнопка командной панели, обычная кнопка, поле ввода,
  // флажок, переключатель). Недоступность задаётся декларативно (disabled:true →
  // <Enabled>false</Enabled>). Для регресса: clickElement по недоступной кнопке
  // должен бросать ошибку, а getFormState — корректно помечать disabled у всех
  // типов. Реквизиты парные (А=доступный, Б=недоступный), чтобы у элементов не
  // совпадали companion-имена.
  {
    name: 'meta-compile: Обработка ПроверкаДоступности',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'ПроверкаДоступности',
      attributes: [
        { name: 'СтрокаДоступная',    type: 'String', length: 50 },
        { name: 'СтрокаНедоступная',  type: 'String', length: 50 },
        { name: 'ФлажокДоступный',    type: 'Boolean' },
        { name: 'ФлажокНедоступный',  type: 'Boolean' },
        { name: 'ВидДоступный',       type: 'EnumRef.ВидыНоменклатуры' },
        { name: 'ВидНедоступный',     type: 'EnumRef.ВидыНоменклатуры' },
        { name: 'ТумблерДоступный',   type: 'EnumRef.СпособыУчёта' },
        { name: 'ТумблерНедоступный', type: 'EnumRef.СпособыУчёта' },
        { name: 'КонтрагентДоступный',   type: 'CatalogRef.Контрагенты' },
        { name: 'КонтрагентНедоступный', type: 'CatalogRef.Контрагенты' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/ПроверкаДоступности' },
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

  // Форма элемента КонтактныеЛица + список — для подчинённого каталога
  {
    name: 'form-add: Форма элемента КонтактныеЛица',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/КонтактныеЛица.xml', '-FormName': 'ФормаЭлемента' },
  },
  {
    name: 'form-compile: Форма элемента КонтактныеЛица',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Контактное лицо',
      attributes: [
        { name: 'Объект', type: 'CatalogObject.КонтактныеЛица', main: true },
      ],
      elements: [
        { input: 'Владелец', path: 'Объект.Owner', title: 'Контрагент' },
        { input: 'Наименование', path: 'Объект.Description', title: 'ФИО' },
        { input: 'Должность', path: 'Объект.Должность', title: 'Должность' },
        { input: 'Телефон', path: 'Объект.Телефон', title: 'Телефон' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/КонтактныеЛица/Forms/ФормаЭлемента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/КонтактныеЛица/Forms/ФормаЭлемента/Ext/Form.xml' },
  },
  {
    name: 'form-add: Форма списка КонтактныеЛица',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/КонтактныеЛица.xml', '-FormName': 'ФормаСписка', '-Purpose': 'List' },
  },
  {
    name: 'form-compile: Форма списка КонтактныеЛица',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Контактные лица',
      attributes: [
        { name: 'Список', type: 'DynamicList', main: true,
          settings: { mainTable: 'Catalog.КонтактныеЛица', dynamicDataRead: true } },
      ],
      elements: [
        { table: 'Список', path: 'Список', columns: [
          { input: 'Description', path: 'Список.Description', title: 'ФИО' },
          { input: 'Должность', path: 'Список.Должность', title: 'Должность' },
          { input: 'Телефон', path: 'Список.Телефон', title: 'Телефон' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/КонтактныеЛица/Forms/ФормаСписка/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/КонтактныеЛица/Forms/ФормаСписка/Ext/Form.xml' },
  },

  // Форма списка Контрагенты — для filterList тестов. КодКПП НЕ выводим
  // в форму — это покрывает FieldSelector DLB ветку (filterList #5)
  {
    name: 'form-add: Форма списка Контрагенты',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/Контрагенты.xml', '-FormName': 'ФормаСписка', '-Purpose': 'List' },
  },
  {
    name: 'form-compile: Форма списка Контрагенты',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Контрагенты',
      attributes: [
        { name: 'Список', type: 'DynamicList', main: true,
          settings: { mainTable: 'Catalog.Контрагенты', dynamicDataRead: true } },
      ],
      elements: [
        { table: 'Список', path: 'Список', columns: [
          { input: 'Code', path: 'Список.Code', title: 'Код' },
          { input: 'Description', path: 'Список.Description', title: 'Наименование' },
          { input: 'ИНН', path: 'Список.ИНН', title: 'ИНН' },
          { input: 'Телефон', path: 'Список.Телефон', title: 'Телефон' },
          { input: 'Адрес', path: 'Список.Адрес', title: 'Адрес' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Контрагенты/Forms/ФормаСписка/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Контрагенты/Forms/ФормаСписка/Ext/Form.xml' },
  },

  // Форма ВЫБОРА Контрагенты — НАМЕРЕННО ШИРОКАЯ (14 колонок), чтобы строка была
  // шире окна выбора. Регресс бага «центр широкой строки уезжает за вьюпорт →
  // клик в оверлей → not_selectable» (04-selectvalue/direct-form, выбор «Север»).
  // form-add с Purpose=Choice авто-назначает её DefaultChoiceForm → именно она
  // открывается при выборе ссылки на Контрагента.
  {
    name: 'form-add: Форма выбора Контрагенты',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/Контрагенты.xml', '-FormName': 'ФормаВыбора', '-Purpose': 'Choice' },
  },
  {
    name: 'form-compile: Форма выбора Контрагенты (широкая)',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Выбор контрагента',
      attributes: [
        { name: 'Список', type: 'DynamicList', main: true,
          settings: { mainTable: 'Catalog.Контрагенты', dynamicDataRead: true } },
      ],
      elements: [
        // choiceMode: true → <ChoiceMode>true</ChoiceMode> на таблице: Enter/двойной
        // клик ПОДТВЕРЖДАЮТ выбор (а не открывают элемент). Без него форма ведёт
        // себя как обычный список (Enter открывает элемент).
        { table: 'Список', path: 'Список', choiceMode: true, columns: [
          { input: 'Code', path: 'Список.Code', title: 'Код' },
          { input: 'Description', path: 'Список.Description', title: 'Наименование' },
          { input: 'ИНН', path: 'Список.ИНН', title: 'ИНН' },
          { input: 'Телефон', path: 'Список.Телефон', title: 'Телефон' },
          { input: 'Адрес', path: 'Список.Адрес', title: 'Адрес' },
          { input: 'КодКПП', path: 'Список.КодКПП', title: 'КПП' },
          { input: 'Регион', path: 'Список.Регион', title: 'Регион' },
          { input: 'Город', path: 'Список.Город', title: 'Город' },
          { input: 'Улица', path: 'Список.Улица', title: 'Улица' },
          { input: 'БИК', path: 'Список.БИК', title: 'БИК' },
          { input: 'ОГРН', path: 'Список.ОГРН', title: 'ОГРН' },
          { input: 'ОКПО', path: 'Список.ОКПО', title: 'ОКПО' },
          { input: 'ВидДеятельности', path: 'Список.ВидДеятельности', title: 'Вид деятельности' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Контрагенты/Forms/ФормаВыбора/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Контрагенты/Forms/ФормаВыбора/Ext/Form.xml' },
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
        { pages: 'Страницы', pagesRepresentation: 'TabsOnTop', children: [
          { page: 'Основное', title: 'Основное', children: [
            { input: 'Наименование', path: 'Объект.Description', title: 'Наименование' },
            { input: 'Артикул', path: 'Объект.Артикул', title: 'Артикул' },
            { input: 'ВидНоменклатуры', path: 'Объект.ВидНоменклатуры', title: 'Вид номенклатуры' },
            { input: 'Цена', path: 'Объект.Цена', title: 'Цена' },
            { radio: 'КатегорияЦены', path: 'Объект.КатегорияЦены',
              title: 'Категория цены',
              radioButtonType: 'RadioButtons',
              titleLocation: 'Top',
              choiceList: [
                { value: 'Enum.КатегорииЦен.EnumValue.Розничная',  presentation: 'Розничная' },
                { value: 'Enum.КатегорииЦен.EnumValue.Оптовая',    presentation: 'Оптовая' },
                { value: 'Enum.КатегорииЦен.EnumValue.Закупочная', presentation: 'Закупочная' },
              ],
            },
            { radio: 'СпособУчёта', path: 'Объект.СпособУчёта',
              title: 'Способ учёта',
              radioButtonType: 'Tumbler',
              titleLocation: 'Top',
              choiceList: [
                { value: 'Enum.СпособыУчёта.EnumValue.ПоСреднему', presentation: 'По среднему' },
                { value: 'Enum.СпособыУчёта.EnumValue.ФИФО',      presentation: 'ФИФО' },
              ],
            },
            { check: 'Активен', path: 'Объект.Активен', title: 'Активен' },
            { input: 'ДатаПоступления', path: 'Объект.ДатаПоступления', title: 'Дата поступления' },
          ]},
          { page: 'Дополнительно', title: 'Дополнительно', children: [
            { input: 'ЕдиницаИзмерения', path: 'Объект.ЕдиницаИзмерения', title: 'Единица измерения' },
            { input: 'Комментарий', path: 'Объект.Комментарий', title: 'Комментарий' },
          ]},
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Номенклатура/Forms/ФормаЭлемента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Номенклатура/Forms/ФормаЭлемента/Ext/Form.xml' },
  },

  // Форма списка Номенклатура — с колонкой ДатаПоступления для filterList #6 (date pattern)
  {
    name: 'form-add: Форма списка Номенклатура',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Catalogs/Номенклатура.xml', '-FormName': 'ФормаСписка', '-Purpose': 'List' },
  },
  {
    name: 'form-compile: Форма списка Номенклатура',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Номенклатура',
      attributes: [
        { name: 'Список', type: 'DynamicList', main: true,
          settings: { mainTable: 'Catalog.Номенклатура', dynamicDataRead: true } },
      ],
      elements: [
        { table: 'Список', path: 'Список', columns: [
          { input: 'Code', path: 'Список.Code', title: 'Код' },
          { input: 'Description', path: 'Список.Description', title: 'Наименование' },
          { input: 'Артикул', path: 'Список.Артикул', title: 'Артикул' },
          { input: 'ВидНоменклатуры', path: 'Список.ВидНоменклатуры', title: 'Вид номенклатуры' },
          { input: 'ДатаПоступления', path: 'Список.ДатаПоступления', title: 'Дата поступления' },
          { input: 'Цена', path: 'Список.Цена', title: 'Цена' },
          { check: 'Активен', path: 'Список.Активен', title: 'Активен' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Catalogs/Номенклатура/Forms/ФормаСписка/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Catalogs/Номенклатура/Forms/ФормаСписка/Ext/Form.xml' },
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
        { input: 'Организация', path: 'Объект.Организация', title: 'Организация' },
        { input: 'Контрагент', path: 'Объект.Контрагент', title: 'Контрагент' },
        { input: 'Склад', path: 'Объект.Склад', title: 'Склад' },
        { input: 'Источник', path: 'Объект.Источник', title: 'Источник' },
        // textEdit:false — ручной ввод запрещён, только pick → форма выбора
        { input: 'Поставщик', path: 'Объект.Поставщик', title: 'Поставщик', textEdit: false },
        { input: 'Менеджер', path: 'Объект.Менеджер', title: 'Менеджер' },
        { input: 'Комментарий', path: 'Объект.Комментарий', title: 'Комментарий' },
        { table: 'Товары', path: 'Объект.Товары', title: 'Товары', changeRowSet: true, columns: [
          { input: 'Номенклатура', path: 'Объект.Товары.Номенклатура', title: 'Номенклатура' },
          { input: 'Количество', path: 'Объект.Товары.Количество', title: 'Количество' },
          { input: 'Цена', path: 'Объект.Товары.Цена', title: 'Цена' },
          { input: 'Сумма', path: 'Объект.Товары.Сумма', title: 'Сумма' },
          { check: 'Согласовано', path: 'Объект.Товары.Согласовано', title: 'Согласовано' },
          // Имя элемента отличается от Источник (в шапке) — иначе ContextMenu
          // companion-имена дублируются в одной форме. form-compile использует
          // имя элемента, не путь, для генерации companion-имён.
          { input: 'ИсточникТЧ', path: 'Объект.Товары.Источник', title: 'Источник' },
          // Кластер из 3 boolean сразу после Источник — у правого края viewport
          // на дефолтном открытии (для теста skip-checkbox в focus-click).
          { check: 'ВРезерве', path: 'Объект.Товары.ВРезерве', title: 'В резерве' },
          { check: 'НаКомиссии', path: 'Объект.Товары.НаКомиссии', title: 'На комиссии' },
          { check: 'Подарок', path: 'Объект.Товары.Подарок', title: 'Подарок' },
          // Дальше text/number/enum — для ширины и разных типов в scroll-сценариях.
          { input: 'Единица', path: 'Объект.Товары.Единица', title: 'Единица' },
          { input: 'Скидка', path: 'Объект.Товары.Скидка', title: 'Скидка' },
          { input: 'СтавкаНДС', path: 'Объект.Товары.СтавкаНДС', title: 'Ставка НДС' },
          { input: 'СуммаСНДС', path: 'Объект.Товары.СуммаСНДС', title: 'Сумма с НДС' },
          { input: 'Серия', path: 'Объект.Товары.Серия', title: 'Серия' },
          { input: 'НомерГТД', path: 'Объект.Товары.НомерГТД', title: 'Номер ГТД' },
          { input: 'СтранаПроисхождения', path: 'Объект.Товары.СтранаПроисхождения', title: 'Страна происхождения' },
          { input: 'СрокГодности', path: 'Объект.Товары.СрокГодности', title: 'Срок годности' },
          { check: 'ПризнакКонтроля', path: 'Объект.Товары.ПризнакКонтроля', title: 'Признак контроля' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Documents/ПриходнаяНакладная/Forms/ФормаДокумента/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Documents/ПриходнаяНакладная/Forms/ФормаДокумента/Ext/Form.xml' },
  },

  // Форма списка ПриходнаяНакладная — с колонкой Контрагент для filterList #7 (reference pattern)
  {
    name: 'form-add: Форма списка ПриходнаяНакладная',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/Documents/ПриходнаяНакладная.xml', '-FormName': 'ФормаСписка', '-Purpose': 'List' },
  },
  {
    name: 'form-compile: Форма списка ПриходнаяНакладная',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Приходные накладные',
      attributes: [
        { name: 'Список', type: 'DynamicList', main: true,
          settings: { mainTable: 'Document.ПриходнаяНакладная', dynamicDataRead: true } },
      ],
      elements: [
        { table: 'Список', path: 'Список', columns: [
          // Произвольная картинка в ВЕДУЩЕЙ позиции — рядом с платформенным значком состояния
          // строки. Даёт строку с двумя значками: pictureCollection (эта колонка) и
          // convertPicture (состояние). Тест 22-row-state ловит на ней экстрактор, который
          // берёт первый .gridBoxImg вместо нужного.
          // titleLocation none — колонка БЕЗ шапки: попадает в ветку именования безымянных
          // колонок readTable (по тултипу заголовка → '(picture)'), а не в обычную.
          { picField: 'Метка', path: 'Список.Posted', title: 'Метка', titleLocation: 'none',
            valuesPicture: 'StdPicture.Favorites' },
          { input: 'Date', path: 'Список.Date', title: 'Дата' },
          { input: 'Number', path: 'Список.Number', title: 'Номер' },
          { input: 'Контрагент', path: 'Список.Контрагент', title: 'Контрагент' },
          // Комментарий — для тестов 18-cell-click: поиск длинного документа
          // через filterList по значению 'LongDoc'.
          { input: 'Комментарий', path: 'Список.Комментарий', title: 'Комментарий' },
          { input: 'Posted', path: 'Список.Posted', title: 'Проведён' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/Documents/ПриходнаяНакладная/Forms/ФормаСписка/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'Documents/ПриходнаяНакладная/Forms/ФормаСписка/Ext/Form.xml' },
  },

  // Форма обработки ТестовыеОшибки — кнопки вызова процедур ОбщиеФункции
  {
    name: 'form-add: Форма обработки ТестовыеОшибки',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/ТестовыеОшибки.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма обработки ТестовыеОшибки',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Тестовые ошибки',
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.ТестовыеОшибки', main: true },
      ],
      elements: [
        { button: 'ПоказатьСообщение', command: 'ПоказатьСообщение', title: 'Показать сообщение' },
        { button: 'ВызватьИсключение', command: 'ВызватьИсключениеКоманда', title: 'Вызвать исключение' },
      ],
      commands: [
        { name: 'ПоказатьСообщение', action: 'ПоказатьСообщение' },
        { name: 'ВызватьИсключениеКоманда', action: 'ВызватьИсключениеКоманда' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/ТестовыеОшибки/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/ТестовыеОшибки/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: ТестовыеОшибки form Module.bsl',
    writeFile: 'DataProcessors/ТестовыеОшибки/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаКлиенте
Процедура ПоказатьСообщение(Команда)
\tПоказатьСообщениеНаСервере();
КонецПроцедуры

&НаСервере
Процедура ПоказатьСообщениеНаСервере()
\tОбщиеФункции.ПоказатьСообщение();
КонецПроцедуры

&НаКлиенте
Процедура ВызватьИсключениеКоманда(Команда)
\tВызватьИсключениеНаСервере();
КонецПроцедуры

&НаСервере
Процедура ВызватьИсключениеНаСервере()
\tОбщиеФункции.ВызватьТестовоеИсключение();
КонецПроцедуры
`,
  },

  // Форма обработки ПроверкаДоступности — доступные/недоступные элементы каждого типа.
  // Командная панель формы (autoCmdBar) и обычные кнопки в группе; поля/флажки/
  // переключатели парами. Недоступные помечены disabled:true (→ <Enabled>false</Enabled>),
  // 1С рисует их серыми: кнопки получают класс pressDisabled.
  {
    name: 'form-add: Форма обработки ПроверкаДоступности',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/ПроверкаДоступности.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма обработки ПроверкаДоступности',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Проверка доступности',
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.ПроверкаДоступности', main: true },
      ],
      elements: [
        // Командная панель формы: доступная + недоступная кнопка.
        { autoCmdBar: 'ФормаКоманднаяПанель', autofill: false, children: [
          { button: 'КомандаПанелиДоступна',   command: 'КомандаПанелиДоступна',   title: 'Доступная команда' },
          { button: 'КомандаПанелиНедоступна', command: 'КомандаПанелиНедоступна', title: 'Недоступная команда', disabled: true },
        ]},
        // Обычные кнопки (в группе на теле формы, вне командной панели).
        { group: 'horizontal', name: 'ГруппаОбычныхКнопок', title: 'Обычные кнопки', children: [
          { button: 'КнопкаДоступна',   command: 'КомандаКнопкаДоступна',   title: 'Доступная кнопка' },
          { button: 'КнопкаНедоступна', command: 'КомандаКнопкаНедоступна', title: 'Недоступная кнопка', disabled: true },
        ]},
        // Поля ввода.
        { input: 'СтрокаДоступная',   path: 'Объект.СтрокаДоступная',   title: 'Строка доступная' },
        { input: 'СтрокаНедоступная', path: 'Объект.СтрокаНедоступная', title: 'Строка недоступная', disabled: true },
        // Флажки.
        { check: 'ФлажокДоступный',   path: 'Объект.ФлажокДоступный',   title: 'Флажок доступный' },
        { check: 'ФлажокНедоступный', path: 'Объект.ФлажокНедоступный', title: 'Флажок недоступный', disabled: true },
        // Переключатели.
        { radio: 'ВидДоступный', path: 'Объект.ВидДоступный',
          title: 'Вид доступный', radioButtonType: 'RadioButtons', titleLocation: 'Top',
          choiceList: [
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Товар',  presentation: 'Товар' },
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Услуга', presentation: 'Услуга' },
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Работа', presentation: 'Работа' },
          ],
        },
        { radio: 'ВидНедоступный', path: 'Объект.ВидНедоступный',
          title: 'Вид недоступный', radioButtonType: 'RadioButtons', titleLocation: 'Top', disabled: true,
          choiceList: [
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Товар',  presentation: 'Товар' },
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Услуга', presentation: 'Услуга' },
            { value: 'Enum.ВидыНоменклатуры.EnumValue.Работа', presentation: 'Работа' },
          ],
        },
        // Тумблеры (переключатель с видом Tumbler — рендерится иначе, чем RadioButtons).
        { radio: 'ТумблерДоступный', path: 'Объект.ТумблерДоступный',
          title: 'Тумблер доступный', radioButtonType: 'Tumbler', titleLocation: 'Top',
          choiceList: [
            { value: 'Enum.СпособыУчёта.EnumValue.ПоСреднему', presentation: 'По среднему' },
            { value: 'Enum.СпособыУчёта.EnumValue.ФИФО',      presentation: 'ФИФО' },
          ],
        },
        { radio: 'ТумблерНедоступный', path: 'Объект.ТумблерНедоступный',
          title: 'Тумблер недоступный', radioButtonType: 'Tumbler', titleLocation: 'Top', disabled: true,
          choiceList: [
            { value: 'Enum.СпособыУчёта.EnumValue.ПоСреднему', presentation: 'По среднему' },
            { value: 'Enum.СпособыУчёта.EnumValue.ФИФО',      presentation: 'ФИФО' },
          ],
        },
        // Ссылочные поля (для selectValue — выбор через DLB/CB-кнопки).
        { input: 'КонтрагентДоступный',   path: 'Объект.КонтрагентДоступный',   title: 'Контрагент доступный' },
        { input: 'КонтрагентНедоступный', path: 'Объект.КонтрагентНедоступный', title: 'Контрагент недоступный', disabled: true },
      ],
      commands: [
        { name: 'КомандаПанелиДоступна',   action: 'КомандаПанелиДоступна' },
        { name: 'КомандаПанелиНедоступна', action: 'КомандаПанелиНедоступна' },
        { name: 'КомандаКнопкаДоступна',   action: 'КомандаКнопкаДоступна' },
        { name: 'КомандаКнопкаНедоступна', action: 'КомандаКнопкаНедоступна' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/ПроверкаДоступности/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/ПроверкаДоступности/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: ПроверкаДоступности form Module.bsl',
    writeFile: 'DataProcessors/ПроверкаДоступности/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаКлиенте
Процедура КомандаПанелиДоступна(Команда)
\tСообщить("Команда панели (доступна)");
КонецПроцедуры

&НаКлиенте
Процедура КомандаПанелиНедоступна(Команда)
\tСообщить("Команда панели (недоступна)");
КонецПроцедуры

&НаКлиенте
Процедура КомандаКнопкаДоступна(Команда)
\tСообщить("Обычная кнопка (доступна)");
КонецПроцедуры

&НаКлиенте
Процедура КомандаКнопкаНедоступна(Команда)
\tСообщить("Обычная кнопка (недоступна)");
КонецПроцедуры
`,
  },

  // Форма обработки ДеревоНоменклатуры — tree-grid с двумя колонками
  {
    name: 'form-add: Форма обработки ДеревоНоменклатуры',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/ДеревоНоменклатуры.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма обработки ДеревоНоменклатуры',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Дерево номенклатуры',
      events: { OnCreateAtServer: 'ПриСозданииНаСервере' },
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.ДеревоНоменклатуры', main: true },
        { name: 'Дерево', type: 'ValueTree', columns: [
          { name: 'Номенклатура', type: 'CatalogRef.Номенклатура', title: 'Номенклатура' },
          { name: 'Цена', type: 'Number(15,2)', title: 'Цена' },
          { name: 'Картинка', type: 'Boolean', title: 'Картинка' },
          // Строковая колонка-выбор-из-списка: значение выбирается обработчиком НачалоВыбора
          // через СписокТипов.ПоказатьВыборЭлемента (как колонка Тип в типовой Консоли запросов).
          { name: 'ТипЗначения', type: 'String', title: 'Тип значения' },
          // Редактируемая строковая колонка: у поля есть кнопка выбора, но НачалоВыбора пустой
          // (F4 ничего не открывает), текст вводится напрямую — модель ячейки «Значение» Консоли запросов.
          { name: 'РедактируемаяСтрока', type: 'String', title: 'Редактируемая строка' },
          // Редактируемые choice-ячейки Число и Дата (та же модель «Значение» КЗ): кнопка выбора +
          // пустой НачалоВыбора, текст вводится напрямую и ПЕРЕФОРМАТИРУЕТСЯ маск-инпутом
          // (1234.56 → «1 234,56»). Регресс-guard для fillChoiceCell — раньше includes-проверка
          // рвалась о переформатирование → ложное F4 → калькулятор.
          { name: 'РедактируемоеЧисло', type: 'Number(15,2)', title: 'Редактируемое число' },
          { name: 'РедактируемаяДата', type: 'date', title: 'Редактируемая дата' },
          // Булева колонка-флажок (отдельно от Картинка) — для fillTableRow toggle на дереве.
          { name: 'Булево', type: 'Boolean', title: 'Булево' },
        ]},
        // Список значений для программного выбора (ПоказатьВыборЭлемента).
        { name: 'СписокТипов', type: 'ValueList' },
      ],
      elements: [
        { table: 'Дерево', path: 'Дерево', initialTreeView: 'ExpandTopLevel', changeRowSet: true,
          on: ['Selection'], handlers: { Selection: 'ДеревоВыбор' },
          columns: [
            { input: 'Номенклатура', path: 'Дерево.Номенклатура', readOnly: true, title: 'Номенклатура' },
            { input: 'Цена', path: 'Дерево.Цена', title: 'Цена' },
            // PictureField на булев Картинка — иконка-значение (frame-based, как ЭДО).
            { picField: 'ДеревоКартинка', path: 'Дерево.Картинка', title: 'Картинка', valuesPicture: 'StdPicture.Favorites', loadTransparent: true },
            // CheckBoxField на тот же булев — для кросс-проверки состояния картинки.
            { check: 'ДеревоКартинкаФлаг', path: 'Дерево.Картинка', title: 'Флаг' },
            // Поле-выбор-из-списка с кнопкой выбора и обработчиком НачалоВыбора.
            // textEdit:false — ручной ввод запрещён (как у колонки «Тип» Консоли запросов):
            // вставленный текст отвергается, значение задаётся только через форму выбора по F4.
            { input: 'ДеревоТипЗначения', path: 'Дерево.ТипЗначения', title: 'Тип значения', textEdit: false,
              choiceButton: true, on: ['StartChoice'], handlers: { StartChoice: 'ДеревоТипЗначенияНачалоВыбора' } },
            // Поле с кнопкой выбора, но пустым НачалоВыбора (СтандартнаяОбработка=Ложь):
            // кнопка iCB есть, F4 ничего не открывает, текст редактируется напрямую (модель «Значение»).
            { input: 'ДеревоРедактируемаяСтрока', path: 'Дерево.РедактируемаяСтрока', title: 'Редактируемая строка',
              choiceButton: true, on: ['StartChoice'], handlers: { StartChoice: 'ДеревоРедактируемаяСтрокаНачалоВыбора' } },
            // Редактируемые choice-ячейки Число/Дата: кнопка iCB + пустой НачалоВыбора → текст
            // редактируется напрямую, значение переформатируется маск-инпутом (модель «Значение» КЗ).
            { input: 'ДеревоРедактируемоеЧисло', path: 'Дерево.РедактируемоеЧисло', title: 'Редактируемое число',
              choiceButton: true, on: ['StartChoice'], handlers: { StartChoice: 'ДеревоРедактируемоеЧислоНачалоВыбора' } },
            { input: 'ДеревоРедактируемаяДата', path: 'Дерево.РедактируемаяДата', title: 'Редактируемая дата',
              choiceButton: true, on: ['StartChoice'], handlers: { StartChoice: 'ДеревоРедактируемаяДатаНачалоВыбора' } },
            // Булево как ПОЛЕ ВВОДА с кнопкой выбора (не флажок): в ячейке выбор Да/Нет —
            // fillTableRow идёт через dropdown-путь (как «Значение» типа Булево в Консоли
            // запросов), не toggle. Кнопка iCB + пустой НачалоВыбора — единая модель «Значение».
            { input: 'ДеревоБулево', path: 'Дерево.Булево', title: 'Булево',
              choiceButton: true, on: ['StartChoice'], handlers: { StartChoice: 'ДеревоБулевоНачалоВыбора' } },
          ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/ДеревоНоменклатуры/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/ДеревоНоменклатуры/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: ДеревоНоменклатуры form Module.bsl',
    writeFile: 'DataProcessors/ДеревоНоменклатуры/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаСервере
Процедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)
\tЗаполнитьУровень(Дерево.ПолучитьЭлементы(), Справочники.Номенклатура.ПустаяСсылка());
\tСписокТипов.Добавить("Строка");
\tСписокТипов.Добавить("Число");
\tСписокТипов.Добавить("Дата");
\tСписокТипов.Добавить("Булево");
\t// Подстрочный дубль «Дата» — для проверки exact-match в pickFromTypeDialog:
\t// поиск «Дата» даёт 2 совпадения, движок должен выбрать точное «Дата», не «Дата документа».
\tСписокТипов.Добавить("Дата документа");
КонецПроцедуры

&НаСервере
Процедура ЗаполнитьУровень(КоллекцияЭлементов, Родитель)
\tЗапрос = Новый Запрос;
\tЗапрос.Текст =
\t\t"ВЫБРАТЬ
\t\t|\tСсылка, ЭтоГруппа, Цена, Наименование
\t\t|ИЗ
\t\t|\tСправочник.Номенклатура
\t\t|ГДЕ
\t\t|\tРодитель = &Родитель
\t\t|УПОРЯДОЧИТЬ ПО
\t\t|\tЭтоГруппа УБЫВ, Наименование";
\tЗапрос.УстановитьПараметр("Родитель", Родитель);
\tВыборка = Запрос.Выполнить().Выбрать();
\tПока Выборка.Следующий() Цикл
\t\tНовыйУзел = КоллекцияЭлементов.Добавить();
\t\tНовыйУзел.Номенклатура = Выборка.Ссылка;
\t\tНовыйУзел.Цена = Выборка.Цена;
\t\t// Детерминированный микс: иконка у позиций дороже 1000.
\t\t// У групп Цена = NULL (реквизит только для элементов) — сравнение пропускаем.
\t\tЕсли НЕ Выборка.ЭтоГруппа Тогда
\t\t\tНовыйУзел.Картинка = Выборка.Цена > 1000;
\t\tКонецЕсли;
\t\tЕсли Выборка.ЭтоГруппа Тогда
\t\t\tЗаполнитьУровень(НовыйУзел.ПолучитьЭлементы(), Выборка.Ссылка);
\t\tКонецЕсли;
\tКонецЦикла;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоВыбор(Элемент, ВыбраннаяСтрока, Поле, СтандартнаяОбработка)
\tТекущиеДанные = Дерево.НайтиПоИдентификатору(ВыбраннаяСтрока);
\tЕсли ТекущиеДанные = Неопределено Тогда
\t\tВозврат;
\tКонецЕсли;
\tЕсли Поле.Имя = "ДеревоКартинка" Тогда
\t\tТекущиеДанные.Картинка = НЕ ТекущиеДанные.Картинка;
\tКонецЕсли;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоТипЗначенияНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\tСтандартнаяОбработка = Ложь;
\tОписаниеОповещения = Новый ОписаниеОповещения("ТипЗначенияЗавершениеВыбора", ЭтотОбъект);
\tСписокТипов.ПоказатьВыборЭлемента(ОписаниеОповещения, НСтр("ru = 'Выбрать тип'"));
КонецПроцедуры

&НаКлиенте
Процедура ТипЗначенияЗавершениеВыбора(ВыбранныйЭлемент, ДополнительныеПараметры) Экспорт
\tЕсли ВыбранныйЭлемент = Неопределено Тогда
\t\tВозврат;
\tКонецЕсли;
\tТекущиеДанные = Элементы.Дерево.ТекущиеДанные;
\tЕсли ТекущиеДанные <> Неопределено Тогда
\t\tТекущиеДанные.ТипЗначения = ВыбранныйЭлемент.Значение;
\tКонецЕсли;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоРедактируемаяСтрокаНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\t// Пустой обработчик: кнопка выбора есть, но F4 ничего не открывает.
\t// Текст вводится напрямую — модель ячейки «Значение» типовой Консоли запросов.
\tСтандартнаяОбработка = Ложь;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоРедактируемоеЧислоНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\t// Пустой обработчик — число редактируется напрямую (модель «Значение» КЗ).
\tСтандартнаяОбработка = Ложь;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоРедактируемаяДатаНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\t// Пустой обработчик — дата редактируется напрямую (модель «Значение» КЗ).
\tСтандартнаяОбработка = Ложь;
КонецПроцедуры

&НаКлиенте
Процедура ДеревоБулевоНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\t// Пустой обработчик: кнопка выбора есть, F4 ничего не открывает; значение задаётся
\t// штатным списком Да/Нет поля ввода булева (модель «Значение» типа Булево в КЗ).
\tСтандартнаяОбработка = Ложь;
КонецПроцедуры
`,
  },

  // Обработка СтраницаНастроек — форма-«страница настроек» БЕЗ полей ввода: только
  // гиперссылка-декорация + сворачиваемая группа (как «Администрирование → Интернет-поддержка
  // и сервисы» в реальных конфигурациях). commandBarLocation:None убирает автокомандную панель,
  // поэтому у формы НЕТ ни одного input.editInput / textarea / a.press — это воспроизводит баг
  // детекции формы (detectForm возвращал null → getFormState = «No form detected»). Регресс на
  // расширенный селектор детекции (dom/_shared.mjs). Открывается командой раздела и navigateLink.
  {
    name: 'meta-compile: Обработка СтраницаНастроек',
    script: 'meta-compile/scripts/meta-compile',
    input: {
      type: 'DataProcessor', name: 'СтраницаНастроек',
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'meta-validate/scripts/meta-validate', flag: '-ObjectPath', path: 'DataProcessors/СтраницаНастроек' },
  },
  {
    name: 'form-add: Форма обработки СтраницаНастроек',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/СтраницаНастроек.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма обработки СтраницаНастроек',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Страница настроек',
      // Без командной панели → на форме нет ни одного a.press.
      properties: { commandBarLocation: 'None' },
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.СтраницаНастроек', main: true },
      ],
      elements: [
        // Гиперссылка-декорация → .staticTextHyper (кликабельна через findClickTargetScript).
        { label: 'СсылкаТехническаяИнформация', title: 'Техническая информация', hyperlink: true },
        // Сворачиваемая группа с дочерней декорацией (пустая группа не рендерится).
        { group: 'collapsible', name: 'ГруппаКлассификаторы', title: 'Классификаторы и курсы валют',
          collapsed: true, showTitle: true, children: [
            { label: 'ПояснениеКлассификаторы', title: 'Загрузка курсов валют и классификаторов' },
          ],
        },
        // Развёрнутая сворачиваемая (collapsed:false) — сверка сигнала collapsed/expanded.
        { group: 'collapsible', name: 'ГруппаРазвёрнутая', title: 'Развёрнутая группа',
          collapsed: false, showTitle: true, children: [
            { label: 'ПояснениеРазвёрнутая', title: 'Содержимое развёрнутой группы' },
          ],
        },
        // Вариант B: контрол сворачивания как КАРТИНКА (#titleBtn-каретка) — как в реальном ERP,
        // в отличие от дефолтного «заголовок-гиперссылка» (вариант A) на этой платформе.
        { group: 'collapsible', name: 'ГруппаКартинкой', title: 'Свёрнута картинкой',
          controlRepresentation: 'Picture', collapsed: true, showTitle: true, children: [
            { label: 'ПояснениеКартинкой', title: 'Содержимое группы с картинкой-контролом' },
          ],
        },
        // Всплывающая (popup) группа — тоже прячет содержимое за триггером.
        { group: 'vertical', name: 'ГруппаВсплывающая', title: 'Всплывающая группа', behavior: 'popup',
          collapsed: true, showTitle: true, children: [
            { label: 'ПояснениеВсплывающая', title: 'Содержимое всплывающей группы' },
          ],
        },
        // Обычная НЕсворачиваемая группа — негатив: НЕ должна попадать в groups[] (не шуметь).
        { group: 'vertical', name: 'ГруппаОбычная', title: 'Обычная группа', showTitle: true, children: [
            { label: 'ПояснениеОбычная', title: 'Содержимое обычной группы' },
          ],
        },
        // СТРЕСС привязки контента: свёрнутая группа → свободный элемент верхнего уровня →
        // развёрнутая группа. Проверяем, отличим ли «свободный сосед после свёрнутой» от
        // «видимого дочернего развёрнутой» (порядок DOM их путает; нужен геометрич./иной сигнал).
        { group: 'collapsible', name: 'ГруппаСтрессСвёрнутая', title: 'Стресс: свёрнутая',
          collapsed: true, showTitle: true, children: [
            { label: 'ВнутриСтрессСвёрнутой', title: 'Внутри свёрнутой стресс-группы' },
          ],
        },
        { label: 'СвободныйМеждуГруппами', title: 'Свободный элемент между группами' },
        { group: 'collapsible', name: 'ГруппаСтрессРазвёрнутая', title: 'Стресс: развёрнутая',
          collapsed: false, showTitle: true, children: [
            { label: 'ВнутриСтрессРазвёрнутой', title: 'Внутри развёрнутой стресс-группы' },
          ],
        },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/СтраницаНастроек/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/СтраницаНастроек/Forms/ФормаОбработки/Ext/Form.xml' },
  },

  // Обработка МножественныйВыбор — основная форма с 4 полями типа «список значений».
  {
    name: 'form-add: Основная форма МножественныйВыбор',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/МножественныйВыбор.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Основная форма МножественныйВыбор',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Множественный выбор',
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.МножественныйВыбор', main: true },
        // 4 реквизита формы типа «список значений». Тип значений задаётся ДЕКЛАРАТИВНО
        // через valueType → <Settings xsi:type="v8:TypeDescription"> (form-compile),
        // без программной установки ТипЗначения в коде.
        { name: 'ОрганизацииСписок', type: 'ValueList', valueType: 'CatalogRef.Организации' },
        { name: 'КонтрагентыСписок', type: 'ValueList', valueType: 'CatalogRef.Контрагенты' },
        { name: 'ЧерезФлажки', type: 'ValueList', valueType: 'CatalogRef.Организации' },
        { name: 'ЧерезПодбор', type: 'ValueList', valueType: 'CatalogRef.Номенклатура' },
        // Граничный случай: поле без расширенного редактирования и без переопределения
        // выбора — чистая платформенная реализация списка значений.
        { name: 'СписокПлатформенный', type: 'ValueList', valueType: 'CatalogRef.Контрагенты' },
      ],
      elements: [
        // Организации/Контрагенты — без StartChoice → штатный редактор списка значений
        // платформы (отдельная, ещё не покрытая движком поверхность).
        // extendedEditMultipleValues:true — «Расширенное редактирование множественных
        // значений»: поле ввода работает как редактор списка значений (кнопка выбора
        // открывает форму ввода значений, в свёрнутом виде показывает «знач, +N»).
        { input: 'ОрганизацииСписок', path: 'ОрганизацииСписок', title: 'Организации (список)', extendedEditMultipleValues: true },
        { input: 'КонтрагентыСписок', path: 'КонтрагентыСписок', title: 'Контрагенты (список)', extendedEditMultipleValues: true },
        // ЧерезФлажки/ЧерезПодбор — StartChoice открывает кастомную ФормаВводаЗначений.
        { input: 'ЧерезФлажки', path: 'ЧерезФлажки', title: 'Через флажки', extendedEditMultipleValues: true, choiceButton: true,
          on: ['StartChoice'], handlers: { StartChoice: 'ЧерезФлажкиНачалоВыбора' } },
        { input: 'ЧерезПодбор', path: 'ЧерезПодбор', title: 'Через подбор', extendedEditMultipleValues: true, choiceButton: true,
          on: ['StartChoice'], handlers: { StartChoice: 'ЧерезПодборНачалоВыбора' } },
        // Граничный случай — без extendedEditMultipleValues и без StartChoice: как платформа
        // отрисует и отредактирует список значений «из коробки».
        { input: 'СписокПлатформенный', path: 'СписокПлатформенный', title: 'Без расширенного (платформ.)' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/МножественныйВыбор/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/МножественныйВыбор/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: МножественныйВыбор основная форма Module.bsl',
    writeFile: 'DataProcessors/МножественныйВыбор/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаКлиенте
Процедура ЧерезФлажкиНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\tСтандартнаяОбработка = Ложь;
\tОткрытьФормуВыбора("ЧерезФлажки");
КонецПроцедуры

&НаКлиенте
Процедура ЧерезПодборНачалоВыбора(Элемент, ДанныеВыбора, СтандартнаяОбработка)
\tСтандартнаяОбработка = Ложь;
\tОткрытьФормуВыбора("ЧерезПодбор");
КонецПроцедуры

&НаКлиенте
Процедура ОткрытьФормуВыбора(ИмяРеквизита)
\t// Тип значений берём из самого реквизита (задан декларативно через valueType),
\t// не хардкодим — единый источник истины.
\tСписокЗнч = ЭтотОбъект[ИмяРеквизита];
\tПарам = Новый Структура;
\tПарам.Вставить("ОписаниеТипов", СписокЗнч.ТипЗначения);
\tПарам.Вставить("Отмеченные", СписокЗнч);
\tОпов = Новый ОписаниеОповещения("ПослеВыбораЗначений", ЭтотОбъект, ИмяРеквизита);
\tОткрытьФорму("Обработка.МножественныйВыбор.Форма.ФормаВводаЗначений", Парам, ЭтотОбъект, , , , Опов, РежимОткрытияОкнаФормы.БлокироватьОкноВладельца);
КонецПроцедуры

&НаКлиенте
Процедура ПослеВыбораЗначений(Результат, ИмяРеквизита) Экспорт
\tЕсли Результат = Неопределено Тогда
\t\tВозврат;
\tКонецЕсли;
\t// Обновляем существующий список поля НА МЕСТЕ, не подменяя объект — иначе теряется
\t// декларированный ТипЗначения реквизита и повторное открытие уходит в режим B.
\tСписокПоля = ЭтотОбъект[ИмяРеквизита];
\tСписокПоля.Очистить();
\tДля Каждого Эл Из Результат Цикл
\t\tСписокПоля.Добавить(Эл.Значение, Эл.Представление);
\tКонецЦикла;
КонецПроцедуры
`,
  },

  // Обработка МножественныйВыбор — форма ввода значений (обрезанный порт БСП-формы
  // ВводЗначенийСпискомСФлажками): безшапочная таблица Check+Value, режим A/B по СпособВыбора.
  {
    name: 'form-add: ФормаВводаЗначений МножественныйВыбор',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/МножественныйВыбор.xml', '-FormName': 'ФормаВводаЗначений' },
  },
  {
    name: 'form-compile: ФормаВводаЗначений МножественныйВыбор',
    script: 'form-compile/scripts/form-compile',
    // Структура получена через /form-decompile titan-формы ВводЗначенийСпискомСФлажками
    // и обрезана: убраны только БСП-специфика («Вставить из буфера обмена» + её команда/
    // картинка) и обработчики событий таблицы (их БСП-процедуры не портируются). Командная
    // панель с группами кнопок, безшапочная таблица (Header=false, CommandBarLocation=None,
    // ColumnGroup InCell: Пометка+Значение), подвал (гиперссылка «Подобрать ещё» + ОК/Отмена)
    // — как в оригинале. main-реквизит form-compile не требует (как у CommonForm-оригинала).
    input: {
      title: 'Выбор значений',
      properties: { autoTitle: false, windowOpeningMode: 'LockOwnerWindow' },
      events: { OnCreateAtServer: 'ПриСозданииНаСервере' },
      elements: [
        {
          autoCmdBar: 'ФормаКоманднаяПанель', autofill: false,
          children: [
            { buttonGroup: 'СписокДобавлениеУдаление', title: { ru: 'Добавление удаление', en: 'Add delete' }, children: [
              { button: 'СписокПодбор', stdCommand: 'Список.Pickup', type: 'commandBar' },
              { button: 'СписокДобавить', stdCommand: 'Список.Add', type: 'commandBar', locationInCommandBar: 'InAdditionalSubmenu' },
              { button: 'СписокУдалить', stdCommand: 'Список.Delete', type: 'commandBar' },
            ]},
            { buttonGroup: 'СписокВключениеОтключениеФлажков', title: { ru: 'Включение отключение флажков', en: 'Select clear check boxes' }, representation: 'Compact', children: [
              { button: 'СписокУстановитьФлажки', stdCommand: 'Список.CheckAll', type: 'commandBar', locationInCommandBar: 'InCommandBarAndInAdditionalSubmenu' },
              { button: 'СписокСнятьФлажки', stdCommand: 'Список.UncheckAll', type: 'commandBar', locationInCommandBar: 'InCommandBarAndInAdditionalSubmenu' },
            ]},
            { buttonGroup: 'СписокСортировка', title: { ru: 'Сортировка', en: 'Sort' }, representation: 'Compact', children: [
              { button: 'СписокСортироватьПоВозрастанию', stdCommand: 'Список.SortListAsc', type: 'commandBar' },
              { button: 'СписокСортироватьПоУбыванию', stdCommand: 'Список.SortListDesc', type: 'commandBar' },
            ]},
            { buttonGroup: 'СписокПеремещение', title: { ru: 'Перемещение', en: 'Move' }, representation: 'Compact', children: [
              { button: 'СписокПереместитьВверх', stdCommand: 'Список.MoveUp', type: 'commandBar' },
              { button: 'СписокПереместитьВниз', stdCommand: 'Список.MoveDown', type: 'commandBar' },
            ]},
            { searchString: 'СтрокаПоиска', source: 'Список', title: { ru: 'Поиск', en: 'Search' } },
            { button: 'ФормаИзменитьФорму', stdCommand: 'CustomizeForm', type: 'commandBar' },
            { button: 'ФормаСправка', stdCommand: 'Help', type: 'commandBar' },
          ],
        },
        {
          table: 'Список', path: 'Список', title: { ru: 'Список', en: 'List' },
          excludedCommands: ['Change', 'Copy', 'EndEdit'],
          representation: 'List', autoInsertNewRow: true, header: false, commandBarLocation: 'None',
          verticalLines: false, horizontalLines: false, rowPictureDataPath: 'Список.Picture',
          fileDragMode: 'AsFile', commandBar: { autofill: false },
          // ChoiceProcessing — подобранные через Подбор значения добавляются с Пометка=Истина
          // (как в БСП-оригинале), иначе они вернутся неотмеченными и выпадут из результата.
          events: { ChoiceProcessing: 'СписокОбработкаВыбора' },
          columns: [
            { columnGroup: 'inCell', name: 'Колонки', title: { ru: 'Колонки', en: 'Columns' }, children: [
              { check: 'СписокПометка', path: 'Список.Check', title: { ru: 'Пометка', en: 'Checkbox' }, editMode: 'EnterOnInput', titleLocation: '' },
              { input: 'СписокЗначение', path: 'Список.Value', title: { ru: 'Значение', en: 'Value' }, editMode: 'EnterOnInput' },
            ]},
          ],
        },
        {
          group: '', behavior: 'usual', name: 'Подвал', title: { ru: 'Подвал', en: 'Footer' },
          representation: 'none', showTitle: false,
          children: [
            { button: 'СписокПодборПодвал', stdCommand: 'Список.Pickup', title: { ru: 'Подобрать еще', en: 'Pick more' }, type: 'hyperlink' },
            { cmdBar: 'НижняяКоманднаяПанель', title: { ru: 'Нижняя командная панель', en: 'Bottom command bar' }, horizontalLocation: 'right', children: [
              { button: 'КомандаОК', command: 'ЗавершитьРедактирование', title: { ru: 'ОК', en: 'OK' }, type: 'commandBar', defaultButton: true },
              { button: 'ФормаОтмена', stdCommand: 'Cancel', type: 'commandBar' },
            ]},
          ],
        },
      ],
      attributes: [
        { name: 'Список', type: 'ValueList', title: { ru: 'Список', en: 'List' } },
      ],
      parameters: [
        { name: 'ОписаниеТипов' },
        { name: 'ЗначенияДляВыбора', type: 'ValueList' },
        { name: 'Отмеченные', type: 'ValueList' },
        { name: 'Представление', type: 'string' },
      ],
      commands: [
        { name: 'ЗавершитьРедактирование', action: 'ЗавершитьРедактирование', title: { ru: 'ОК', en: 'OK' },
          tooltip: { ru: 'Завершить редактирование', en: 'Finish editing' }, currentRowUse: 'DontUse' },
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/МножественныйВыбор/Forms/ФормаВводаЗначений/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/МножественныйВыбор/Forms/ФормаВводаЗначений/Ext/Form.xml' },
  },
  {
    name: 'writeFile: ФормаВводаЗначений Module.bsl',
    writeFile: 'DataProcessors/МножественныйВыбор/Forms/ФормаВводаЗначений/Ext/Form/Module.bsl',
    content: `&НаСервере
Процедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)
\tЕсли Параметры.ОписаниеТипов <> Неопределено Тогда
\t\tСписок.ТипЗначения = Параметры.ОписаниеТипов;
\tКонецЕсли;
\tБыстрыйВыбор = ВсеТипыСБыстрымВыбором(Список.ТипЗначения);
\tЕсли БыстрыйВыбор Тогда
\t\tЗагрузитьВсехКандидатов(Список.ТипЗначения);
\t\tЭлементы.СписокПодбор.Видимость = Ложь;
\t\tЭлементы.СписокПодборПодвал.Видимость = Ложь;
\tКонецЕсли;
\tЕсли ТипЗнч(Параметры.Отмеченные) = Тип("СписокЗначений") Тогда
\t\tДля Каждого Эл Из Параметры.Отмеченные Цикл
\t\t\tНайден = Список.НайтиПоЗначению(Эл.Значение);
\t\t\tЕсли Найден = Неопределено Тогда
\t\t\t\tНайден = Список.Добавить(Эл.Значение);
\t\t\tКонецЕсли;
\t\t\tНайден.Пометка = Истина;
\t\tКонецЦикла;
\tКонецЕсли;
КонецПроцедуры

&НаСервере
Функция ВсеТипыСБыстрымВыбором(Описание)
\tЕсли Описание = Неопределено Тогда
\t\tВозврат Ложь;
\tКонецЕсли;
\tТипы = Описание.Типы();
\tЕсли Типы.Количество() = 0 Тогда
\t\tВозврат Ложь;
\tКонецЕсли;
\tДля Каждого Тип Из Типы Цикл
\t\tМО = Метаданные.НайтиПоТипу(Тип);
\t\tЕсли МО = Неопределено Тогда
\t\t\tВозврат Ложь;
\t\tКонецЕсли;
\t\t// БыстрыйВыбор (свойство QuickChoice) — даёт режим A. Не путать со СпособВыбора
\t\t// (ChoiceMode); meta-compile quickChoice:true пишет именно <QuickChoice>true</QuickChoice>.
\t\tПопытка
\t\t\tЕсли НЕ МО.БыстрыйВыбор Тогда
\t\t\t\tВозврат Ложь;
\t\t\tКонецЕсли;
\t\tИсключение
\t\t\tВозврат Ложь;
\t\tКонецПопытки;
\tКонецЦикла;
\tВозврат Истина;
КонецФункции

&НаСервере
Процедура ЗагрузитьВсехКандидатов(Описание)
\tДля Каждого Тип Из Описание.Типы() Цикл
\t\tМО = Метаданные.НайтиПоТипу(Тип);
\t\tЕсли МО = Неопределено Тогда
\t\t\tПродолжить;
\t\tКонецЕсли;
\t\tЗапрос = Новый Запрос("ВЫБРАТЬ Ссылка КАК Ссылка ИЗ " + МО.ПолноеИмя());
\t\tВыборка = Запрос.Выполнить().Выбрать();
\t\tПока Выборка.Следующий() Цикл
\t\t\tЕсли Список.НайтиПоЗначению(Выборка.Ссылка) = Неопределено Тогда
\t\t\t\tСписок.Добавить(Выборка.Ссылка);
\t\t\tКонецЕсли;
\t\tКонецЦикла;
\tКонецЦикла;
КонецПроцедуры

&НаКлиенте
Процедура СписокОбработкаВыбора(Элемент, РезультатВыбора, СтандартнаяОбработка)
\tСтандартнаяОбработка = Ложь;
\tЕсли ТипЗнч(РезультатВыбора) = Тип("Массив") Тогда
\t\tДля Каждого ЗначениеВыбора Из РезультатВыбора Цикл
\t\t\tДобавитьСОтметкой(ЗначениеВыбора);
\t\tКонецЦикла;
\tИначеЕсли ТипЗнч(РезультатВыбора) = Тип("СписокЗначений") Тогда
\t\tДля Каждого ЭлСписка Из РезультатВыбора Цикл
\t\t\tДобавитьСОтметкой(ЭлСписка.Значение);
\t\tКонецЦикла;
\tИначе
\t\tДобавитьСОтметкой(РезультатВыбора);
\tКонецЕсли;
КонецПроцедуры

&НаКлиенте
Процедура ДобавитьСОтметкой(ЗначениеВыбора)
\tНайден = Список.НайтиПоЗначению(ЗначениеВыбора);
\tЕсли Найден = Неопределено Тогда
\t\tНайден = Список.Добавить(ЗначениеВыбора);
\tКонецЕсли;
\tНайден.Пометка = Истина;
КонецПроцедуры

&НаКлиенте
Процедура ЗавершитьРедактирование(Команда)
\t// Возвращаем только отмеченные значения (а не весь рабочий список).
\tРезультат = Новый СписокЗначений;
\tРезультат.ТипЗначения = Список.ТипЗначения;
\tДля Каждого Эл Из Список Цикл
\t\tЕсли Эл.Пометка Тогда
\t\t\tРезультат.Добавить(Эл.Значение, Эл.Представление);
\t\tКонецЕсли;
\tКонецЦикла;
\tЗакрыть(Результат);
КонецПроцедуры
`,
  },

  // Обработка БезшапочнаяТаблица — форма с редактируемой безшапочной таблицей значений.
  {
    name: 'form-add: Форма БезшапочнаяТаблица',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/БезшапочнаяТаблица.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма БезшапочнаяТаблица',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Безшапочная таблица',
      events: { OnCreateAtServer: 'ПриСозданииНаСервере' },
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.БезшапочнаяТаблица', main: true },
        { name: 'Таблица', type: 'ValueTable', columns: [
          { name: 'Товар', type: 'CatalogRef.Номенклатура', title: 'Товар' },
          { name: 'Количество', type: 'Number(15,3)', title: 'Количество' },
          { name: 'Цена', type: 'Number(15,2)', title: 'Цена' },
          { name: 'Активен', type: 'Boolean', title: 'Активен' },
        ]},
      ],
      elements: [
        // header:false → <Header>false</Header>; changeRowSet → строки редактируемы.
        // Колонки: ссылка (заполнение через форму выбора) + числа + булево (чекбокс).
        { table: 'Таблица', path: 'Таблица', header: false, changeRowSet: true, columns: [
          { input: 'Товар', path: 'Таблица.Товар', title: 'Товар' },
          { input: 'Количество', path: 'Таблица.Количество', title: 'Количество' },
          { input: 'Цена', path: 'Таблица.Цена', title: 'Цена' },
          { check: 'Активен', path: 'Таблица.Активен', title: 'Активен' },
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/БезшапочнаяТаблица/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/БезшапочнаяТаблица/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: БезшапочнаяТаблица form Module.bsl',
    writeFile: 'DataProcessors/БезшапочнаяТаблица/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаСервере
Процедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)
\tЗапрос = Новый Запрос("ВЫБРАТЬ ПЕРВЫЕ 3 Ссылка КАК Ссылка ИЗ Справочник.Номенклатура ГДЕ НЕ ЭтоГруппа УПОРЯДОЧИТЬ ПО Наименование");
\tВыборка = Запрос.Выполнить().Выбрать();
\tСч = 0;
\tПока Выборка.Следующий() Цикл
\t\tСтрока = Таблица.Добавить();
\t\tСтрока.Товар = Выборка.Ссылка;
\t\tСтрока.Количество = (Сч + 1) * 10;
\t\tСтрока.Цена = (Сч + 1) * 100;
\t\tСтрока.Активен = (Сч % 2 = 0);
\t\tСч = Сч + 1;
\tКонецЦикла;
КонецПроцедуры
`,
  },

  // Обработка МногострочнаяШапка — форма с двухэтажной шапкой (columnGroup vertical).
  {
    name: 'form-add: Форма МногострочнаяШапка',
    script: 'form-add/scripts/form-add',
    args: { '-ObjectPath': '{workDir}/DataProcessors/МногострочнаяШапка.xml', '-FormName': 'ФормаОбработки' },
  },
  {
    name: 'form-compile: Форма МногострочнаяШапка',
    script: 'form-compile/scripts/form-compile',
    input: {
      title: 'Многострочная шапка',
      events: { OnCreateAtServer: 'ПриСозданииНаСервере' },
      attributes: [
        { name: 'Объект', type: 'DataProcessorObject.МногострочнаяШапка', main: true },
        { name: 'Таблица', type: 'ValueTable', columns: [
          { name: 'Код', type: 'String(10)', title: 'Код' },
          { name: 'Задача', type: 'String(50)', title: 'Задача' },
          { name: 'Автор', type: 'String(50)', title: 'Автор' },
          { name: 'Исполнитель', type: 'String(50)', title: 'Исполнитель' },
          { name: 'Срок', type: 'String(50)', title: 'Срок' },
          { name: 'Выполнена', type: 'String(50)', title: 'Выполнена' },
          { name: 'Субконто1', type: 'String(50)', title: 'Субконто1' },
          { name: 'Субконто2', type: 'String(50)', title: 'Субконто2' },
          { name: 'Субконто3', type: 'String(50)', title: 'Субконто3' },
        ]},
      ],
      elements: [
        { table: 'Таблица', path: 'Таблица', changeRowSet: true, columns: [
          { input: 'Код', path: 'Таблица.Код', title: 'Код', width: 8 },
          // Простая вертикальная пара: у каждой колонки своя шапка (как «Задача»/«Автор» в ERP).
          { columnGroup: 'vertical', name: 'ГруппаЗадача', showInHeader: false, children: [
            { input: 'Задача', path: 'Таблица.Задача', title: 'Задача', width: 30 },
            { input: 'Автор', path: 'Таблица.Автор', title: 'Автор', width: 30 },
          ]},
          // ПАТТЕРН «ЗАДАЧИ»: широкая колонка сверху над горизонтальной парой узких.
          // Ширина «Исполнитель» = сумма пары → его центр падает в x-диапазон «Выполнена».
          { columnGroup: 'vertical', name: 'ГруппаИсполнитель', showInHeader: false, children: [
            { input: 'Исполнитель', path: 'Таблица.Исполнитель', title: 'Исполнитель', width: 40 },
            { columnGroup: 'horizontal', name: 'ГруппаСрокВыполнена', showInHeader: false, children: [
              { input: 'Срок', path: 'Таблица.Срок', title: 'Срок', width: 20 },
              { input: 'Выполнена', path: 'Таблица.Выполнена', title: 'Выполнена', width: 20 },
            ]},
          ]},
          // ПАТТЕРН «ОПЕРАЦИЯ»: одна шапка группы над тремя под-рядами БЕЗ своих боксов в шапке
          // (showInHeader:false у детей — как «Субконто Дт» в ERP: шапка только у группы,
          // ячеек три) → readTable разворачивает в «Субконто 1/2/3». Регресс этого разворота.
          { columnGroup: 'vertical', name: 'ГруппаСубконто', title: 'Субконто', showInHeader: true, children: [
            { input: 'Субконто1', path: 'Таблица.Субконто1', showInHeader: false, width: 25 },
            { input: 'Субконто2', path: 'Таблица.Субконто2', showInHeader: false, width: 25 },
            { input: 'Субконто3', path: 'Таблица.Субконто3', showInHeader: false, width: 25 },
          ]},
        ]},
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputPath': '{workDir}/DataProcessors/МногострочнаяШапка/Forms/ФормаОбработки/Ext/Form.xml' },
    validate: { script: 'form-validate/scripts/form-validate', flag: '-FormPath', path: 'DataProcessors/МногострочнаяШапка/Forms/ФормаОбработки/Ext/Form.xml' },
  },
  {
    name: 'writeFile: МногострочнаяШапка form Module.bsl',
    writeFile: 'DataProcessors/МногострочнаяШапка/Forms/ФормаОбработки/Ext/Form/Module.bsl',
    content: `&НаСервере
Процедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)
\t// Значения уникальны по колонкам: если резолвер промахнётся, это видно сразу.
\tДля Сч = 1 По 3 Цикл
\t\tС = Формат(Сч, "ЧН=; ЧГ=");
\t\tСтрока = Таблица.Добавить();
\t\tСтрока.Код = "К" + С;
\t\tСтрока.Задача = "Задача " + С;
\t\tСтрока.Автор = "Автор " + С;
\t\tСтрока.Исполнитель = "Исполнитель " + С;
\t\tСтрока.Срок = "Срок " + С;
\t\tСтрока.Выполнена = "Выполнена " + С;
\t\tСтрока.Субконто1 = "Субконто1 " + С;
\t\tСтрока.Субконто2 = "Субконто2 " + С;
\t\tСтрока.Субконто3 = "Субконто3 " + С;
\tКонецЦикла;
КонецПроцедуры
`,
  },

  // ── 4. DCS for report ──
  // Сначала добавляем макет ОсновнаяСхемаКомпоновкиДанных к отчёту (регистрируется
  // в Reports/ОстаткиТоваров.xml + автоматически выставляется MainDataCompositionSchema),
  // затем skd-compile наполняет его содержимым.
  {
    name: 'template-add: ОсновнаяСхемаКомпоновкиДанных к отчёту ОстаткиТоваров',
    script: 'template-add/scripts/add-template',
    args: {
      '-ObjectName': 'ОстаткиТоваров',
      '-TemplateName': 'ОсновнаяСхемаКомпоновкиДанных',
      '-TemplateType': 'DataCompositionSchema',
      '-SrcDir': '{workDir}/Reports',
    },
  },
  {
    name: 'skd-compile: Схема отчёта ОстаткиТоваров',
    script: 'skd-compile/scripts/skd-compile',
    input: {
      dataSets: [{
        name: 'НаборДанных',
        query: 'ВЫБРАТЬ\n\tТовары.Ссылка КАК Документ,\n\tТовары.Номенклатура КАК Номенклатура,\n\tТовары.Количество КАК Количество,\n\tТовары.Цена КАК Цена,\n\tТовары.Сумма КАК Сумма\nИЗ\n\tДокумент.ПриходнаяНакладная.Товары КАК Товары',
        fields: [
          { field: 'Документ', title: 'Документ', type: 'DocumentRef.ПриходнаяНакладная' },
          { field: 'Номенклатура', title: 'Номенклатура', type: 'CatalogRef.Номенклатура' },
          { field: 'Количество', title: 'Количество', type: 'decimal(15,3)' },
          { field: 'Цена', title: 'Цена', type: 'decimal(15,2)' },
          { field: 'Сумма', title: 'Сумма', type: 'decimal(15,2)' },
        ],
      }],
      totalFields: ['Количество: Сумма', 'Сумма: Сумма'],
      settingsVariants: [{
        name: 'Основной',
        title: 'Остатки товаров',
        settings: {
          selection: ['Номенклатура', 'Количество', 'Сумма', 'Auto'],
          filter: ['Номенклатура = _ @off @user @quickAccess'],
          structure: 'Номенклатура > details',
        },
      }],
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
        'Catalog.Организации',
        'Catalog.Контрагенты',
        'Catalog.КонтактныеЛица',
        'Catalog.Номенклатура',
        'Enum.ВидыНоменклатуры',
        'Enum.КатегорииЦен',
        'Enum.СпособыУчёта',
        'Document.ПриходнаяНакладная',
        'Report.ОстаткиТоваров',
        'DataProcessor.МножественныйВыбор',
        'DataProcessor.БезшапочнаяТаблица',
        'DataProcessor.МногострочнаяШапка',
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
        'DataProcessor.ТестовыеОшибки',
        'DataProcessor.ДеревоНоменклатуры',
        'DataProcessor.ПроверкаДоступности',
        'DataProcessor.СтраницаНастроек',
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
        'Catalog.Организации: Read View Add Update Delete',
        'Catalog.Контрагенты: Read View Add Update Delete',
        'Catalog.КонтактныеЛица: Read View Add Update Delete',
        'Catalog.Номенклатура: Read View Add Update Delete',
        'Document.ПриходнаяНакладная: Read View Add Update Delete Posting UnPosting',
        'InformationRegister.КурсыВалют: Read View Add Update Delete',
        'Report.ОстаткиТоваров: Use View',
        'DataProcessor.ДеревоНоменклатуры: Use View',
        'DataProcessor.МножественныйВыбор: Use View',
        'DataProcessor.БезшапочнаяТаблица: Use View',
        'DataProcessor.МногострочнаяШапка: Use View',
        'DataProcessor.ПроверкаДоступности: Use View',
        'DataProcessor.СтраницаНастроек: Use View',
      ],
    },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}' },
    validate: { script: 'role-validate/scripts/role-validate', flag: '-RightsPath', path: 'Roles/Администратор' },
  },

  // ── 7. Final validation ──
  // (meta-compile, subsystem-compile, role-compile уже регистрируют объекты в Configuration.xml)
  {
    name: 'cf-validate: Финальная валидация конфигурации',
    script: 'cf-validate/scripts/cf-validate',
    args: { '-ConfigPath': '{workDir}' },
  },
];
