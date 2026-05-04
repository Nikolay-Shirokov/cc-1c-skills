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
2. **From object** (`-FromObject`) — автоматически из метаданных объекта 1С по пресету ERP

> **При проектировании формы с нуля (5+ элементов или нечёткие требования)** — вызовите `/form-patterns` для загрузки справочника. Для простых форм (1–3 поля) — не нужно.

## Параметры

| Параметр   | Обязательный | Описание                        |
|------------|:------------:|---------------------------------|
| JsonPath   | режим 1      | Путь к JSON-определению формы   |
| OutputPath | да           | Путь к выходному Form.xml       |
| FromObject | режим 2      | Флаг (без значения) — генерация по метаданным объекта |

## Команда

```powershell
# Режим JSON DSL
powershell.exe -NoProfile -File .claude/skills/form-compile/scripts/form-compile.ps1 -JsonPath "<json>" -OutputPath "<Form.xml>"

# Режим from-object (объект и purpose выводятся из OutputPath; Document и Catalog)
powershell.exe -NoProfile -File .claude/skills/form-compile/scripts/form-compile.ps1 -FromObject -OutputPath "<.../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml>"
```

## JSON DSL — справка

### Структура верхнего уровня

```json
{
  "title": "Заголовок формы",
  "properties": { "autoTitle": false, ... },
  "events": { "OnCreateAtServer": "ПриСозданииНаСервере" },
  "excludedCommands": ["Reread"],
  "elements": [ ... ],
  "attributes": [ ... ],
  "commands": [ ... ],
  "parameters": [ ... ]
}
```

- `title` — заголовок формы (multilingual). Можно указать и в `properties`, но лучше на верхнем уровне
- `properties` — свойства формы: `autoTitle`, `windowOpeningMode`, `commandBarLocation`, `saveDataInSettings`, `width`, `height` и др.
- `events` — обработчики событий формы (ключ: имя события 1С, значение: имя процедуры)
- `excludedCommands` — исключённые стандартные команды

### Элементы (ключ определяет тип)

| DSL ключ     | XML элемент       | Значение ключа                                    |
|--------------|-------------------|---------------------------------------------------|
| `"group"`    | UsualGroup        | `"horizontal"` / `"vertical"` / `"alwaysHorizontal"` / `"alwaysVertical"` / `"collapsible"` |
| `"columnGroup"` | ColumnGroup    | `"horizontal"` / `"vertical"` / `"inCell"` — только внутри `columns` таблицы |
| `"input"`    | InputField        | имя элемента                                      |
| `"check"`    | CheckBoxField     | имя                                               |
| `"radio"`    | RadioButtonField  | имя                                               |
| `"label"`    | LabelDecoration   | имя (текст задаётся через `title`)                |
| `"labelField"` | LabelField      | имя                                               |
| `"table"`    | Table             | имя                                               |
| `"pages"`    | Pages             | имя                                               |
| `"page"`     | Page              | имя                                               |
| `"button"`   | Button            | имя                                               |
| `"picture"`  | PictureDecoration | имя                                               |
| `"picField"` | PictureField      | имя                                               |
| `"calendar"` | CalendarField     | имя                                               |
| `"cmdBar"`   | CommandBar        | имя                                               |
| `"autoCmdBar"` | AutoCommandBar формы | имя — наполняет главную АКП формы (id=-1), не попадает в `<ChildItems>` |
| `"popup"`    | Popup             | имя                                               |

### Общие свойства (все типы элементов)

| Ключ | Описание |
|------|----------|
| `name` | Переопределить имя (по умолчанию = значение ключа типа) |
| `title` | Заголовок элемента |
| `visible: false` | Скрыть (синоним: `hidden: true`) |
| `enabled: false` | Сделать недоступным (синоним: `disabled: true`) |
| `readOnly: true` | Только чтение |
| `on: [...]` | События с автоименованием обработчиков |
| `handlers: {...}` | Явное задание имён обработчиков: `{"OnChange": "МоёИмя"}` |

### Допустимые имена событий (`on`)

Компилятор предупреждает о неизвестных событиях. Имена регистрозависимы — используйте точно как указано.

**Форма** (`events`): `OnCreateAtServer`, `OnOpen`, `BeforeClose`, `OnClose`, `NotificationProcessing`, `ChoiceProcessing`, `OnReadAtServer`, `BeforeWriteAtServer`, `OnWriteAtServer`, `AfterWriteAtServer`, `BeforeWrite`, `AfterWrite`, `FillCheckProcessingAtServer`, `BeforeLoadDataFromSettingsAtServer`, `OnLoadDataFromSettingsAtServer`, `ExternalEvent`, `Opening`

**input / picField**: `OnChange`, `StartChoice`, `ChoiceProcessing`, `AutoComplete`, `TextEditEnd`, `Clearing`, `Creating`, `EditTextChange`

**check / radio**: `OnChange`

**table**: `OnStartEdit`, `OnEditEnd`, `OnChange`, `Selection`, `ValueChoice`, `BeforeAddRow`, `BeforeDeleteRow`, `AfterDeleteRow`, `BeforeRowChange`, `BeforeEditEnd`, `OnActivateRow`, `OnActivateCell`, `Drag`, `DragStart`, `DragCheck`, `DragEnd`

**label / picture**: `Click`, `URLProcessing`

**labelField**: `OnChange`, `StartChoice`, `ChoiceProcessing`, `Click`, `URLProcessing`, `Clearing`

**button**: `Click`

**pages**: `OnCurrentPageChange`

### Поле ввода (input)

| Ключ | Описание | Пример |
|------|----------|--------|
| `path` | DataPath — привязка к данным | `"Объект.Организация"` |
| `titleLocation` | Размещение заголовка | `"none"`, `"left"`, `"top"` |
| `multiLine: true` | Многострочное поле | текстовое поле, комментарий |
| `passwordMode: true` | Режим пароля (звёздочки) | поле ввода пароля |
| `choiceButton: true` | Кнопка выбора ("...") | ссылочное поле |
| `clearButton: true` | Кнопка очистки ("X") | |
| `spinButton: true` | Кнопка прокрутки | числовые поля |
| `dropListButton: true` | Кнопка выпадающего списка | |
| `markIncomplete: true` | Пометка незаполненного | обязательные поля |
| `skipOnInput: true` | Пропускать при обходе Tab | |
| `inputHint` | Подсказка в пустом поле | `"Введите наименование..."` |
| `width` / `height` | Размер | числа |
| `autoMaxWidth: false` | Снять авто-ограничение ширины (поле растянется) | |
| `maxWidth` / `maxHeight` | Жёсткое ограничение размера | числа; обычно вместе с `autoMaxWidth: false` |
| `horizontalStretch: true` | Растягивать по ширине | |

### Чекбокс (check)

| Ключ | Описание |
|------|----------|
| `path` | DataPath |
| `titleLocation` | Размещение заголовка |

### Поле переключателя (radio)

Радиокнопки или тумблер для выбора одного значения из списка.

| Ключ | Описание | Пример |
|------|----------|--------|
| `path` | DataPath — привязка к реквизиту | `"СпособКурса"` |
| `radioButtonType` | Вид переключателя | `"Auto"` (по умолчанию), `"RadioButtons"`, `"Tumbler"` |
| `columnsCount` | Число колонок раскладки | `1`, `2`, ... |
| `titleLocation` | Размещение заголовка | по умолчанию `"none"` |
| `choiceList` | Список вариантов: массив `{value, presentation}` | см. ниже |

`choiceList[*]`:

| Ключ | Описание |
|------|----------|
| `value` | Значение варианта. Строка/число/булево; для перечисления — `"Enum.ИмяТипа.EnumValue.ИмяЗначения"` |
| `presentation` | Текст рядом с переключателем. Строка (русский) либо объект `{ru, en, ...}` для мультиязычности |

```json
{
  "radio": "СпособКурса",
  "path": "Объект.СпособУстановкиКурса",
  "radioButtonType": "Auto",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": { "ru": "Автоматически", "en": "Automatic" } },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": "вручную" }
  ]
}
```

### Надпись-декорация (label)

| Ключ | Описание |
|------|----------|
| `title` | Текст надписи (обязательно) |
| `hyperlink: true` | Сделать ссылкой |
| `width` / `height` | Размер |

### Группа (group)

Значение ключа задаёт ориентацию: `"horizontal"`, `"vertical"`, `"alwaysHorizontal"`, `"alwaysVertical"`, `"collapsible"`.

| Ключ | Описание |
|------|----------|
| `showTitle: true` | Показывать заголовок группы |
| `united: false` | Левый край полей ввода выравнивается только в пределах этой группы (по умолчанию `true` — сквозное выравнивание по самому длинному заголовку, в т.ч. с соседними группами) |
| `collapsed: true` | Только для `"group": "collapsible"` — группа создаётся свёрнутой |
| `representation` | `"none"`, `"normal"`, `"weak"`, `"strong"` |
| `children: [...]` | Вложенные элементы |

### Таблица (table)

**Важно**: таблица требует связанный реквизит формы типа `ValueTable` с колонками (см. раздел "Связки").

| Ключ | Описание |
|------|----------|
| `path` | DataPath (привязка к реквизиту-таблице) |
| `columns: [...]` | Колонки — массив элементов (обычно `input`) |
| `changeRowSet: true` | Разрешить добавление/удаление строк |
| `changeRowOrder: true` | Разрешить перемещение строк |
| `height` | Высота в строках таблицы |
| `header: false` | Скрыть шапку |
| `footer: true` | Показать подвал |
| `commandBarLocation` | `"None"`, `"Top"`, `"Auto"` |
| `searchStringLocation` | `"None"`, `"Top"`, `"Auto"` |
| `choiceMode: true` | Режим выбора (для форм выбора) |
| `initialTreeView` | `"ExpandTopLevel"` и др. (иерархические списки) |
| `enableDrag: true` | Разрешить перетаскивание |
| `enableStartDrag: true` | Разрешить начало перетаскивания |
| `rowPictureDataPath` | Путь к картинке строки (напр. `"Список.DefaultPicture"`) |
| `tableAutofill: false` | Управление Autofill внутреннего AutoCommandBar |

Колонки можно группировать через `columnGroup` (см. ниже).

### Группа колонок (columnGroup)

Используется только внутри `columns` таблицы. Значение ключа задаёт ориентацию: `"horizontal"`, `"vertical"`, `"inCell"` (склеивает колонки в одну ячейку шапки). Допускается вложение `columnGroup` в `columnGroup`.

| Ключ | Описание |
|------|----------|
| `name` | Имя элемента (рекомендуется задавать явно) |
| `title` | Заголовок группы |
| `showTitle: false` | Скрыть заголовок |
| `showInHeader: true/false` | Показывать ли группу в шапке таблицы |
| `width` | Ширина |
| `horizontalStretch: false` | Растягивание |
| `children: [...]` | Колонки внутри группы (`input`, `labelField`, `picField`, вложенный `columnGroup` …) |

```json
{ "table": "Список", "path": "Список", "columns": [
    { "columnGroup": "horizontal", "name": "ГруппаДата", "title": "Срок", "children": [
        { "input": "СрокИсполнения", "path": "Список.СрокИсполнения" },
        { "labelField": "Просрочено", "path": "Список.Просрочено" }
    ]},
    { "columnGroup": "inCell", "name": "ГруппаИсполнитель", "showInHeader": true, "children": [
        { "input": "Исполнитель", "path": "Список.Исполнитель" }
    ]},
    { "input": "Комментарий", "path": "Список.Комментарий" }
]}
```

### Страницы (pages + page)

| Ключ (pages) | Описание |
|------|----------|
| `pagesRepresentation` | `"None"`, `"TabsOnTop"`, `"TabsOnBottom"` и др. |
| `children: [...]` | Массив `page` |

| Ключ (page) | Описание |
|------|----------|
| `title` | Заголовок вкладки |
| `group` | Ориентация внутри страницы |
| `children: [...]` | Содержимое страницы |

### Кнопка (button)

| Ключ | Описание |
|------|----------|
| `command` | Имя команды формы → `Form.Command.Имя` |
| `stdCommand` | Стандартная команда: `"Close"` → `Form.StandardCommand.Close`; с точкой: `"Товары.Add"` → `Form.Item.Товары.StandardCommand.Add` |
| `defaultButton: true` | Кнопка по умолчанию |
| `type` | `"usual"`, `"hyperlink"`. По умолчанию `"usual"`. Конкретный XML-вид (UsualButton/Hyperlink/CommandBarButton/CommandBarHyperlink) подставляется автоматически по контексту |
| `picture` | Картинка кнопки |
| `representation` | `"Auto"`, `"Text"`, `"Picture"`, `"PictureAndText"` |
| `locationInCommandBar` | `"Auto"`, `"InCommandBar"`, `"InAdditionalSubmenu"` |

### Командная панель (cmdBar)

Дополнительная пользовательская панель команд, размещается как обычный элемент в layout формы.

| Ключ | Описание |
|------|----------|
| `autofill: true` | Автозаполнение стандартными командами |
| `children: [...]` | Кнопки панели |

### Главная автокомандная панель формы (autoCmdBar)

Наполняет встроенную AutoCommandBar формы (id=-1) кастомными кнопками. Указывать только если нужно добавить свои кнопки на главную панель или явно управлять автозаполнением.

| Ключ | Описание |
|------|----------|
| `autofill: true/false` | Автозаполнение стандартными командами |
| `horizontalAlign` | `"Left"` / `"Center"` / `"Right"` |
| `children: [...]` | Кнопки/popup |

```json
{ "autoCmdBar": "ФормаКоманднаяПанель", "autofill": true, "children": [
   { "button": "ИзменитьВыделенные", "command": "ИзменитьВыделенные",
     "locationInCommandBar": "InAdditionalSubmenu" }
]}
```

Кнопки основных действий формы и подменю размещают здесь, а не в отдельной группе на форме. Отдельной кнопкой в layout — только если она логически привязана к конкретному полю или группе.

### Выпадающее меню (popup)

| Ключ | Описание |
|------|----------|
| `title` | Заголовок подменю |
| `children: [...]` | Кнопки подменю |

Используется внутри `cmdBar` для группировки кнопок в подменю:
```json
{ "cmdBar": "Панель", "children": [
  { "popup": "Добавить", "title": "Добавить", "children": [
    { "button": "ДобавитьСтроку", "stdCommand": "Товары.Add" },
    { "button": "ДобавитьИзДокумента", "command": "ДобавитьИзДокумента", "title": "Из документа" }
  ]}
]}
```

### Реквизиты (attributes)

```json
{ "name": "Объект", "type": "DataProcessorObject.Загрузка", "main": true }
{ "name": "Список", "type": "DynamicList", "main": true, "settings": {
    "mainTable": "Catalog.Номенклатура", "dynamicDataRead": true
}}
{ "name": "Итого", "type": "decimal(15,2)" }
{ "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" }
]}
```

- `savedData: true` — сохраняемые данные
- `main: true` — главный реквизит формы (например, основной `*Object.*`, `DynamicList`, `*RecordSet.*`)

### Команды (commands)

```json
{ "name": "Загрузить", "action": "ЗагрузитьОбработка", "shortcut": "Ctrl+Enter" }
```

- `title` — заголовок (если отличается от name)
- `picture` — картинка команды

### Система типов

**Примитивные:**

| DSL                    | XML                                    |
|------------------------|----------------------------------------|
| `"string"` / `"string(100)"` | `xs:string` + StringQualifiers  |
| `"decimal(15,2)"`     | `xs:decimal` + NumberQualifiers        |
| `"decimal(10,0,nonneg)"` | с AllowedSign=Nonnegative           |
| `"boolean"`            | `xs:boolean`                          |
| `"date"` / `"dateTime"` / `"time"` | `xs:dateTime` + DateFractions |

**Ссылочные и объектные (`cfg:Prefix.Name`):**

| DSL | Описание |
|-----|----------|
| `"CatalogRef.XXX"` / `"CatalogObject.XXX"` | Справочник |
| `"DocumentRef.XXX"` / `"DocumentObject.XXX"` | Документ |
| `"EnumRef.XXX"` | Перечисление |
| `"DataProcessorObject.XXX"` / `"ReportObject.XXX"` | Обработка / Отчёт |
| `"InformationRegisterRecordSet.XXX"` | Набор записей регистра сведений |
| `"AccumulationRegisterRecordSet.XXX"` | Набор записей регистра накопления |
| `"DynamicList"` | Динамический список |

Также допустимы: `ChartOfAccountsRef/Object`, `ChartOfCharacteristicTypesRef/Object`, `ChartOfCalculationTypesRef/Object`, `ExchangePlanRef/Object`, `BusinessProcessRef/Object`, `TaskRef/Object`, `AccountingRegisterRecordSet`, `InformationRegisterRecordManager`, `ConstantsSet`.

**Платформенные:**

| DSL | XML |
|-----|-----|
| `"ValueTable"` | `v8:ValueTable` |
| `"ValueTree"` | `v8:ValueTree` |
| `"ValueList"` | `v8:ValueListType` |
| `"TypeDescription"` | `v8:TypeDescription` |
| `"UUID"` | `v8:UUID` |
| `"FormattedString"` | `v8ui:FormattedString` |
| `"Picture"` / `"Color"` / `"Font"` | `v8ui:*` |
| `"DataCompositionSettings"` | `dcsset:DataCompositionSettings` |
| `"Type1 \| Type2"` | составной тип (несколько `<v8:Type>`) |

**Недопустимые типы (XDTO-ошибка при загрузке):**

> `FormDataStructure`, `FormDataCollection`, `FormDataTree` — runtime-типы 1С, не существуют в XML-схеме. Вместо них используйте `CatalogObject.XXX`, `DocumentObject.XXX`, `DataProcessorObject.XXX`, `ValueTable`, `ValueTree`.

## Связки: элемент + реквизит

Таблица и некоторые поля требуют связанный реквизит. Элемент ссылается на реквизит через `path`.

**Таблица** — элемент `table` + реквизит `ValueTable`:
```json
{
  "elements": [
    { "table": "Товары", "path": "Объект.Товары", "columns": [
      { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура" }
    ]}
  ],
  "attributes": [
    { "name": "Объект", "type": "DataProcessorObject.Загрузка", "main": true,
      "columns": [
        { "name": "Товары", "type": "ValueTable", "columns": [
          { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" }
        ]}
      ]
    }
  ]
}
```

Или, если таблица привязана к реквизиту формы (не к Объект):
```json
{
  "elements": [
    { "table": "ТаблицаДанных", "path": "ТаблицаДанных", "columns": [
      { "input": "Наименование", "path": "ТаблицаДанных.Наименование" }
    ]}
  ],
  "attributes": [
    { "name": "ТаблицаДанных", "type": "ValueTable", "columns": [
      { "name": "Наименование", "type": "string(150)" }
    ]}
  ]
}
```

## Паттерны

### Диалог загрузки файла

```json
{
  "title": "Загрузка из файла",
  "properties": { "autoTitle": false },
  "events": { "OnCreateAtServer": "ПриСозданииНаСервере" },
  "elements": [
    { "group": "horizontal", "name": "ГруппаФайл", "children": [
      { "input": "ИмяФайла", "path": "ИмяФайла", "title": "Файл", "inputHint": "Выберите файл...", "choiceButton": true, "on": ["StartChoice"] },
      { "check": "ПерваяСтрокаЗаголовок", "path": "ПерваяСтрокаЗаголовок" }
    ]},
    { "input": "Результат", "path": "Результат", "multiLine": true, "height": 8, "readOnly": true, "title": "Лог" },
    { "autoCmdBar": "ФормаКоманднаяПанель", "children": [
      { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
      { "button": "Закрыть",   "stdCommand": "Close" }
    ]}
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

### Мастер (wizard) с шагами

```json
{
  "title": "Мастер настройки",
  "properties": { "autoTitle": false },
  "elements": [
    { "pages": "СтраницыМастера", "pagesRepresentation": "None", "children": [
      { "page": "Шаг1", "title": "Параметры", "children": [
        { "input": "Параметр1", "path": "Параметр1" }
      ]},
      { "page": "Шаг2", "title": "Результат", "children": [
        { "input": "Итог", "path": "Итог", "readOnly": true }
      ]}
    ]},
    { "group": "horizontal", "name": "Навигация", "children": [
      { "button": "Назад", "command": "Назад", "title": "< Назад" },
      { "button": "Далее", "command": "Далее", "title": "Далее >" }
    ]}
  ],
  "attributes": [
    { "name": "Объект", "type": "ExternalDataProcessorObject.Мастер", "main": true },
    { "name": "Параметр1", "type": "string" },
    { "name": "Итог", "type": "string" }
  ],
  "commands": [
    { "name": "Назад", "action": "НазадОбработка" },
    { "name": "Далее", "action": "ДалееОбработка" }
  ]
}
```

### Список с фильтром и таблицей

```json
{
  "title": "Просмотр данных",
  "elements": [
    { "group": "horizontal", "name": "Фильтр", "children": [
      { "input": "Период", "path": "Период", "on": ["OnChange"] },
      { "input": "Организация", "path": "Организация", "on": ["OnChange"] }
    ]},
    { "table": "Данные", "path": "Данные", "changeRowSet": true, "columns": [
      { "input": "Дата", "path": "Данные.Дата" },
      { "input": "Сумма", "path": "Данные.Сумма" },
      { "input": "Комментарий", "path": "Данные.Комментарий" }
    ]}
  ],
  "attributes": [
    { "name": "Объект", "type": "ExternalDataProcessorObject.Просмотр", "main": true },
    { "name": "Период", "type": "date" },
    { "name": "Организация", "type": "string" },
    { "name": "Данные", "type": "ValueTable", "columns": [
      { "name": "Дата", "type": "date" },
      { "name": "Сумма", "type": "decimal(15,2)" },
      { "name": "Комментарий", "type": "string(200)" }
    ]}
  ]
}
```

## Автогенерация

- **Companion-элементы**: ContextMenu, ExtendedTooltip и др. создаются автоматически
- **Обработчики событий**: `"on": ["OnChange"]` → `ОрганизацияПриИзменении`
- **Namespace**: все 17 namespace-деклараций
- **ID**: последовательная нумерация, AutoCommandBar = id="-1"
- **Unknown keys**: выводится предупреждение о нераспознанных ключах

## Workflow

1. **Компиляция**: `/form-compile` генерирует `Form.xml` и автоматически регистрирует `<Form>` в `ChildObjects` родительского объекта (если OutputPath следует конвенции `.../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml`).
2. **Метаданные формы** (`ФормаСписка.xml`) и `Module.bsl` создаёт `/form-add`. Если `/form-add` ещё не вызывался — вызови после `/form-compile`. Он не перезаписывает существующий Form.xml.
3. **Проверка**: `/form-validate`, `/form-info`.

## Верификация

```
/form-validate <OutputPath>    — проверка корректности XML
/form-info <OutputPath>        — визуальная сводка структуры
```

## Особенности для внешних обработок (EPF)

- **Тип главного реквизита**: `ExternalDataProcessorObject.ИмяОбработки` (не `DataProcessorObject`)
- **DataPath**: используйте реквизиты формы (`ИмяРеквизита`), а не `Объект.ИмяРеквизита` — у внешних обработок нет реквизитов объекта в метаданных
- **Ссылочные типы**: `CatalogRef.XXX`, `DocumentRef.XXX` допустимы в XML, но для сборки EPF потребуется база с целевой конфигурацией (см. `/epf-build`)
