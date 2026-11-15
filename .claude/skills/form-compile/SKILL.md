---
name: form-compile
description: Компиляция управляемой формы 1С из JSON-определения или из метаданных объекта. Используй когда нужно создать форму с нуля по описанию элементов или сгенерировать типовую форму
argument-hint: <JsonPath> <OutputPath> | -FromObject <OutputPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /form-compile — Генерация Form.xml

Два режима:
1. **JSON DSL** — из JSON-определения формы
2. **From object** (`-FromObject`) — заготовка формы объекта конфигурации по его метаданным: поля объекта в стиле ЕРП/УТ, служебные убраны; событий, команд, связей полей и итогов в ней нет

## С чего начать

- содержимое формы уже есть — `/form-edit`;
- форма описана в задаче целиком (текстом или эскизом) — JSON по описанию;
- описана часть формы (поля, блок, поведение) — для формы объекта, списка, выбора, группы или записи заготовка `-EmitDsl`, впишите в неё описанное, сборка `-JsonPath`; для остальных форм — JSON;
- форма по образцу другой формы конфигурации («как у ЗаказКлиента») — изучите образец через `/form-info`; для этих же форм разложите по нему заготовку `-EmitDsl`, для остальных — JSON; обработчики образца переносите только вместе с кодом;
- о форме ничего не сказано — для этих же форм `-FromObject`, для остальных — JSON.

> Если раскладка формы не задана в задаче и заготовки нет — архетип формы, имена групп и ширины полей в `references/layout-patterns.md`. В заготовке `-FromObject` / `-EmitDsl` раскладка уже как в типовых.

## Параметры

| Параметр   | Обязательный | Описание                        |
|------------|:------------:|---------------------------------|
| JsonPath   | режим 1      | Путь к JSON-определению формы   |
| OutputPath | да           | Путь к выходному Form.xml       |
| FromObject | режим 2      | Флаг (без значения) — генерация по метаданным объекта |
| Purpose    | нет          | Назначение, если основная форма объекта названа нестандартно |
| EmitDsl    | нет          | Сохранить сгенерированное JSON-определение в файл |

## Команда

```powershell
# Режим JSON DSL
python "${CLAUDE_SKILL_DIR}/scripts/form-compile.py" -JsonPath "<json>" -OutputPath "<Form.xml>"

# Режим from-object: объект и назначение берутся из пути формы
python "${CLAUDE_SKILL_DIR}/scripts/form-compile.py" -FromObject -OutputPath "<.../Documents/ИмяОбъекта/Forms/ФормаДокумента/Ext/Form.xml>"

# Заготовка для доработки: сохранить JSON, доработать, собрать режимом JSON DSL
python "${CLAUDE_SKILL_DIR}/scripts/form-compile.py" -FromObject -OutputPath "<Form.xml>" -EmitDsl "<form.json>"
```

## JSON DSL

### Структура

```json
{
  "title": "Заголовок формы",
  "properties": { "windowOpeningMode": "LockOwnerWindow" },
  "events": { ... },
  "elements": [ ... ],
  "attributes": [ ... ],
  "commands": [ ... ],
  "parameters": [ ... ]
}
```

- `title` — заголовок формы (строка или `{ru, en}`)
- `properties` — свойства формы: `windowOpeningMode`, `commandBarLocation`, `width`, `height` и др. (полный список — `references/form-properties.md`)
- `events` — обработчики событий формы: `{ "ИмяСобытия": "ИмяПроцедуры" }`; имена по конвенции — списком: `["OnCreateAtServer", "OnOpen"]` → `ПриСозданииНаСервере`, `ПриОткрытии`
- `excludedCommands` — убрать стандартные команды формы: `["Reread", "Copy"]`

### Элементы (ключ определяет тип)

| Ключ | Элемент | Значение ключа |
|------|---------|----------------|
| `group` | Обычная группа | ориентация: `vertical` / `horizontalIfPossible` / `alwaysHorizontal` |
| `input` | Поле ввода | имя |
| `check` | Флажок | имя |
| `radio` | Переключатель | имя |
| `label` | Надпись | имя (текст — в `title`) |
| `labelField` | Поле-надпись (значение без редактирования) | имя |
| `table` | Таблица | имя |
| `columnGroup` | Группа колонок (внутри `columns` таблицы) | `horizontal` / `vertical` / `inCell` |
| `pages` / `page` | Страницы / страница | имя |
| `button` | Кнопка | имя |
| `buttonGroup` | Группа кнопок (в командной панели или подменю) | имя |
| `popup` | Подменю | имя |
| `cmdBar` | Командная панель в раскладке формы | имя |
| `autoCmdBar` | Командная панель самой формы | имя (обычно `ФормаКоманднаяПанель`) |
| `picture` | Картинка | имя |
| `picField` | Поле-картинка | имя |

Табличный документ, HTML, календарь, диаграммы и другие особые поля — по индексу ниже.

### Общие свойства элементов

| Ключ | Описание |
|------|----------|
| `name` | Имя элемента, если отличается от значения ключа типа. Имена в форме уникальны |
| `title` | Заголовок (строка или `{ru, en}`); `""` — без заголовка |
| `tooltip` | Всплывающая подсказка |
| `visible: false` / `enabled: false` / `readOnly: true` | Скрыть / сделать недоступным / только чтение |
| `titleLocation` | `none` / `left` / `right` / `top` / `bottom` / `auto` |
| `width` / `height` | Размер |
| `horizontalStretch` / `verticalStretch` | Растягивать |
| `autoMaxWidth: false` | Снять предел ширины (поле тянется на всю доступную ширину) |
| `events` | Обработчики: `{ "OnChange": "ИмяОбработчика" }`; имена по конвенции — списком: `["OnChange", "StartChoice"]` (элемент списка может задать имя сам: `{ "event": "Clearing", "handler": "Имя" }`) |

### События

Имена регистрозависимы.

Частые:

**Форма:** `OnCreateAtServer`, `OnOpen`, `NotificationProcessing`, `BeforeClose`, `OnClose`, `ChoiceProcessing`, `FillCheckProcessingAtServer`, `OnLoadDataFromSettingsAtServer`; у формы объекта или записи — `OnReadAtServer`, `BeforeWrite`, `BeforeWriteAtServer`, `AfterWrite`, `AfterWriteAtServer`
**input:** `OnChange`, `StartChoice`, `ChoiceProcessing`, `Clearing`, `AutoComplete`, `TextEditEnd`
**check / radio:** `OnChange`
**table:** `Selection`, `OnActivateRow`, `BeforeAddRow`, `BeforeDeleteRow`, `AfterDeleteRow`, `BeforeRowChange`, `OnStartEdit`, `OnEditEnd`, `BeforeEditEnd`, `OnChange`, `OnActivateCell`, `ChoiceProcessing`, `Drag`; только у таблицы динамического списка — `OnGetDataAtServer`, `BeforeLoadUserSettingsAtServer`, `OnUpdateUserSettingSetAtServer`
**label / labelField:** `Click`, `URLProcessing`
**picture / picField:** `Click`
**pages:** `OnCurrentPageChange`
**spreadsheet:** `Selection`, `OnChangeAreaContent`, `OnActivate`, `DetailProcessing`
**html:** `OnClick`, `DocumentComplete`

Остальные события этих и других полей (календарь, планировщик, диаграммы, документы) — `references/events.md`. У кнопки, страницы, группы колонок, командной панели и подменю событий нет.

### Поле ввода (input)

| Ключ | Описание |
|------|----------|
| `path` | Путь к данным: `"Объект.Организация"`, `"ИмяРеквизита"` |
| `multiLine: true` | Многострочное (комментарий) |
| `choiceButton` / `clearButton` / `dropListButton` | Кнопки выбора, очистки, выпадающего списка |
| `markIncomplete: true` | Подсвечивать незаполненное |
| `inputHint` | Подсказка в пустом поле |
| `skipOnInput: true` | Пропускать при переходе по Enter/Tab |
| `maxWidth` | Предел ширины |

Список выбора, маска, формат, пароль и другие кнопки — `references/input-fields.md`.

### Флажок (check) и переключатель (radio)

`check`: `path`, `titleLocation` (по умолчанию заголовок справа). Вид «выключатель» или «тумблер» — `references/input-fields.md`.

`radio`: `path`, `radioButtonType` (`Auto` / `RadioButtons` / `Tumbler`), `columnsCount`, `choiceList`:

```json
{ "radio": "СпособКурса", "path": "Объект.СпособУстановкиКурса", "radioButtonType": "Tumbler",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": "Автоматически" },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": { "ru": "Вручную", "en": "Manual" } }
  ] }
```

`value` — строка, число, булево или значение перечисления `"Enum.Тип.EnumValue.Значение"`; `presentation` — текст варианта.

### Надпись (label) и поле-надпись (labelField)

`label`: `title` — текст (поддерживает разметку, см. `references/tooltips-text.md`), `hyperlink: true` — ссылка.
`labelField`: `path`, `hyperlink: true` — значение как ссылка.

### Группа (group)

| Ключ | Описание |
|------|----------|
| `behavior` | `collapsible` — сворачиваемая, `popup` — всплывающая; не указан — обычная |
| `showTitle: true` | Показывать заголовок (без ключа у обычной группы показан, если задан `title` или `titleDataPath`, иначе скрыт; у сворачиваемой и всплывающей — показан) |
| `representation` | `none` / `normal` / `weak` / `strong` — рамка группы |
| `united: false` | Выравнивать поля только внутри группы, а не вместе с соседними |
| `children` | Вложенные элементы |

Свёрнутая при открытии группа, интервалы, заголовок из данных — `references/groups-pages.md`.

### Таблица (table)

Таблица привязывается к реквизиту-таблице (`ValueTable`, табличная часть объекта, динамический список) — см. «Связка элемент + реквизит».

| Ключ | Описание |
|------|----------|
| `path` | Путь к реквизиту-таблице |
| `columns` | Колонки — элементы (`input`, `check`, `labelField`, `picField`, `columnGroup`); путь колонки — путь таблицы плюс имя колонки: `Объект.Товары.Сумма`, `Данные.Сумма` |
| `changeRowSet: true` / `changeRowOrder: true` | Разрешить добавлять/удалять / перемещать строки |
| `header: false` | Без шапки |
| `heightInTableRows` | Высота в строках |
| `commandBar` | Кнопки командной панели таблицы — сюда команды строк («Отметить все», «Снять отметки», «Заполнить», «Подбор»), а не в панель формы или группу на форме: `[ { "button": "ЦеныОтметитьВсе", "command": "ОтметитьВсе" } ]` (`references/buttons-commands.md`) |
| `commandBarLocation` | `None` / `Top` / `Bottom` / `Auto` |
| `searchStringLocation` | `None` / `Top` / `Bottom` / `CommandBar` / `Auto` |
| `choiceMode: true` | Таблица выбора (форма выбора) |

Подвал с итогами, дерево, выделение, закрепление колонок, перетаскивание — `references/table-advanced.md`.

`columnGroup` группирует колонки: `title`, `showInHeader`, `children`; `inCell` — несколько колонок в одной ячейке:

```json
{ "table": "Список", "path": "Список", "columns": [
    { "columnGroup": "horizontal", "name": "ГруппаСрок", "title": "Срок", "children": [
        { "input": "ДатаНачала", "path": "Список.ДатаНачала" },
        { "input": "ДатаОкончания", "path": "Список.ДатаОкончания" } ] },
    { "input": "Комментарий", "path": "Список.Комментарий" }
] }
```

### Страницы (pages + page)

`pages`: `pagesRepresentation` (`TabsOnTop` / `TabsOnBottom` / `None` — без закладок), `children` — массив `page`.
`page`: `title`, `group` (ориентация содержимого), `children`.

### Кнопки и командные панели

| Ключ (button) | Описание |
|---------------|----------|
| `command` | Команда формы → `Form.Command.Имя` |
| `stdCommand` | Стандартная: `"Close"`; с точкой — команда элемента: `"Товары.Add"` |
| `defaultButton: true` | Кнопка по умолчанию |
| `type` | `usual` / `hyperlink` |
| `representation` | `Auto` / `Text` / `Picture` / `PictureAndText` |
| `locationInCommandBar` | `InCommandBar` / `InAdditionalSubmenu` |

`autoCmdBar` — командная панель формы, сюда помещают основные действия:

```json
{ "autoCmdBar": "ФормаКоманднаяПанель", "children": [
    { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
    { "popup": "Печать", "title": "Печать", "children": [
        { "button": "ПечатьСчета", "command": "ПечатьСчета" } ] },
    { "buttonGroup": "ГруппаНавигация", "children": [
        { "button": "Назад", "command": "Назад" },
        { "button": "Далее", "command": "Далее" } ] }
] }
```

- `popup` — подменю: `title`, `children`.
- `buttonGroup` — кнопки, объединённые в группу: `title`, `children`.
- `cmdBar` — отдельная панель в раскладке формы: `autofill`, `children`.
- `autoCmdBar`: `autofill: false` — без стандартных команд, `horizontalAlign` — выравнивание.

Картинки кнопок, кнопки-переключатели, команды таблицы в группе кнопок, своё контекстное меню у элемента — `references/buttons-commands.md`.

### Картинка (picture) и поле-картинка (picField)

`picture`: `src` — `"StdPicture.X"` / `"CommonPicture.X"`, `width`, `height`.
`picField`: `path`; для булева или числа — `valuesPicture` (иначе значок не рисуется). Подробнее — `references/pictures.md`.

### Реквизиты (attributes)

```json
{ "name": "Объект", "type": "DataProcessorObject.Загрузка", "main": true }
{ "name": "Итого", "type": "decimal(15,2)", "title": "Итого" }
{ "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" } ] }
{ "name": "Список", "type": "DynamicList", "main": true,
  "settings": { "mainTable": "Catalog.Номенклатура" } }
```

- `main: true` — основной реквизит формы (объект, набор записей, динамический список)
- `savedData: true` — сохраняемые данные (у основного реквизита-объекта ставится само)
- `columns` — колонки `ValueTable` / `ValueTree`
- `settings` — настройки динамического списка (`references/dynamic-list.md`)

Сохранение в настройках, проверка заполнения, функциональные опции — `references/attributes-advanced.md`.

### Команды (commands) и параметры (parameters)

```json
"commands": [ { "name": "Загрузить", "action": "ЗагрузитьОбработка", "title": "Загрузить", "shortcut": "Ctrl+Enter", "picture": "StdPicture.Refresh" } ]
"parameters": [ { "name": "Основание", "type": "DocumentRef.Заказ" } ]
```

Команды: `name`, `action` (процедура-обработчик), `title`, `shortcut`, `picture`. Параметры: `name`, `type`, `key: true` — ключевой.

### Система типов

| DSL | Тип |
|-----|-----|
| `string` / `string(100)` | Строка (неограниченная / длины 100) |
| `decimal(15,2)` / `decimal(10,0,nonneg)` | Число / неотрицательное |
| `boolean` | Булево |
| `date` / `dateTime` / `time` | Дата / дата и время / время |
| `CatalogRef.X` / `DocumentRef.X` / `EnumRef.X` / … | Ссылки |
| `CatalogObject.X` / `DocumentObject.X` / `DataProcessorObject.X` / `ReportObject.X` | Объекты (основной реквизит) |
| `InformationRegisterRecordSet.X` / `AccumulationRegisterRecordSet.X` | Наборы записей |
| `ValueTable` / `ValueTree` / `ValueList` | Таблица / дерево / список значений |
| `DynamicList` | Динамический список |
| `TypeDescription`, `UUID`, `FormattedString`, `Picture`, `Color`, `Font`, `DataCompositionSettings`, `StandardPeriod`, `mxl:SpreadsheetDocument` | Платформенные |
| `Тип1 \| Тип2` | Составной |

Также `ChartOfAccountsRef/Object`, `ChartOfCharacteristicTypesRef/Object`, `ChartOfCalculationTypesRef/Object`, `ExchangePlanRef/Object`, `BusinessProcessRef/Object`, `TaskRef/Object`, `AccountingRegisterRecordSet`, `InformationRegisterRecordManager`, `ConstantsSet`. Наборы типов — `references/type-system-advanced.md`.

> `FormDataStructure`, `FormDataCollection`, `FormDataTree` — не типы реквизита (ошибка при загрузке). Вместо них — объектный тип (`DocumentObject.X`…), `ValueTable`, `ValueTree`.

## Связка элемент + реквизит

Элемент показывает данные реквизита через `path`.

Табличная часть основного реквизита — путь `Объект.<ТЧ>`, колонки — `Объект.<ТЧ>.<Реквизит>`:

```json
{ "table": "Товары", "path": "Объект.Товары", "columns": [
    { "input": "ТоварыНоменклатура", "path": "Объект.Товары.Номенклатура" },
    { "input": "ТоварыКоличество", "path": "Объект.Товары.Количество" } ] }
```

Таблица на реквизите формы — реквизит `ValueTable` с колонками:

```json
{
  "elements": [
    { "table": "Данные", "path": "Данные", "changeRowSet": true, "columns": [
        { "input": "ДанныеДата", "path": "Данные.Дата" },
        { "input": "ДанныеСумма", "path": "Данные.Сумма" } ] }
  ],
  "attributes": [
    { "name": "Данные", "type": "ValueTable", "columns": [
        { "name": "Дата", "type": "date" },
        { "name": "Сумма", "type": "decimal(15,2)" } ] }
  ]
}
```

## Пример: диалог загрузки

```json
{
  "title": "Загрузка из файла",
  "elements": [
    { "autoCmdBar": "ФормаКоманднаяПанель", "children": [
      { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
      { "button": "Закрыть", "stdCommand": "Close" }
    ]},
    { "group": "horizontal", "name": "ГруппаФайл", "children": [
      { "input": "ИмяФайла", "path": "ИмяФайла", "title": "Файл", "inputHint": "Выберите файл...",
        "choiceButton": true, "events": { "StartChoice": "ИмяФайлаНачалоВыбора" } },
      { "check": "ПерваяСтрокаЗаголовок", "path": "ПерваяСтрокаЗаголовок" }
    ]},
    { "input": "Результат", "path": "Результат", "multiLine": true, "height": 8, "readOnly": true, "title": "Лог" }
  ],
  "attributes": [
    { "name": "Объект", "type": "ExternalDataProcessorObject.ЗагрузкаИзФайла", "main": true },
    { "name": "ИмяФайла", "type": "string" },
    { "name": "ПерваяСтрокаЗаголовок", "type": "boolean" },
    { "name": "Результат", "type": "string" }
  ],
  "commands": [
    { "name": "Загрузить", "action": "ЗагрузитьОбработка", "shortcut": "Ctrl+Enter" }
  ]
}
```

Служебные узлы элементов (контекстное меню, расширенная подсказка, панели таблицы) и идентификаторы создаются сами. Неизвестный ключ — предупреждение в выводе.

## Задача → справочник

Описанного выше хватает для большинства форм. Под задачу подгрузите файл из `references/`:

| Задача | Справочник |
|--------|-----------|
| Раскладка формы, не заданной в задаче: архетипы документа, списка, обработки, диалога, мастера; имена групп и элементов; ширины полей | `layout-patterns.md` |
| Список выбора, быстрый выбор, своя форма выбора, маска, формат числа, пароль, выключатель/тумблер, кнопки открытия и создания, поле составного типа | `input-fields.md` |
| Ограничить выбор отбором, связать поле с другим полем, связь по типу | `choice-params.md` |
| Свёрнутая группа, интервалы и ширины колонок в группе, заголовок группы или страницы из данных, значок закладки, мастер по шагам (страницы без закладок) | `groups-pages.md` |
| Итоги в подвале таблицы, дерево, выделение нескольких строк, закрепление колонок, поиск, перетаскивание, убрать стандартные команды таблицы | `table-advanced.md` |
| Форма списка: источник данных, запрос, отбор, сортировка, группировка, иерархия | `dynamic-list.md` |
| Кнопка с картинкой, переключатель в панели, команды таблицы в группе кнопок, своё контекстное меню или панель у поля, команда для текущей строки таблицы | `buttons-commands.md` |
| Подсветить цветом, шрифт, рамка, условное оформление (в форме списка — `dynamic-list.md`) | `appearance.md` |
| Расширенная подсказка под полем, текст с выделением или ссылкой | `tooltips-text.md` |
| Картинка, значок в колонке, иконка по значению | `pictures.md` |
| Печатная форма или отчёт на форме (табличный документ) | `spreadsheet.md` |
| HTML, текстовый документ, индикатор, ползунок, календарь, период | `special-fields.md` |
| Диаграмма, диаграмма Ганта, планировщик | `charts.md` |
| Модальность, размер, прокрутка, Enter, свойства формы документа (время, проведение) | `form-properties.md` |
| Форма отчёта (СКД) | `report-form.md` |
| Сохранить значение в настройках, проверка заполнения, функциональные опции, тип элементов списка значений | `attributes-advanced.md` |
| Видимость и доступ по ролям | `roles-access.md` |
| Командный интерфейс формы (переходы, важные команды) | `command-interface.md` |
| Выравнивание, предел размера, фокус по умолчанию, узкие экраны | `layout-advanced.md` |
| Какие события есть у элемента или формы, имена обработчиков, с какой платформы | `events.md` |
| Наборы и составные типы | `type-system-advanced.md` |
| Изменить, как `-FromObject` раскладывает формы во всём проекте (стиль проекта) | `../presets/README.md` |

## Workflow

1. **Каркас**: `/form-add` создаёт метаданные формы, `Module.bsl` и регистрирует форму у объекта.
2. **Компиляция**: `/form-compile` наполняет `Form.xml`; для обработчиков событий и команд, которых ещё нет в модуле, добавляет в `Module.bsl` пустые процедуры с нужной сигнатурой — остаётся написать тело.
3. **Проверка**: `/form-validate`, `/form-info`.

## Внешние обработки (EPF)

- **Основной реквизит**: `ExternalDataProcessorObject.ИмяОбработки` (не `DataProcessorObject`)
- **Пути данных**: реквизиты формы (`ИмяРеквизита`), а не `Объект.ИмяРеквизита` — у внешней обработки нет реквизитов объекта в метаданных
- **Ссылочные типы** (`CatalogRef.XXX` и т.п.) допустимы, но для сборки EPF нужна база с целевой конфигурацией (см. `/epf-build`)
