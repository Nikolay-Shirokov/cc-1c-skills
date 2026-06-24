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
