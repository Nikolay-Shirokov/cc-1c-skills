---
name: form-compile
description: Компиляция управляемой формы 1С (Form.xml) из компактного JSON-определения
argument-hint: <JsonPath> <OutputPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /form-compile — Генерация Form.xml из JSON DSL

Принимает компактное JSON-определение формы (20–50 строк) и генерирует полный корректный Form.xml (100–500+ строк) с namespace-декларациями, автогенерированными companion-элементами, последовательными ID.

> При проектировании формы с нуля — см. [паттерны компоновки](../../docs/form-patterns.md): типовые архетипы (документ, обработка, список, справочник, мастер), конвенции именования, примеры DSL.

## Использование

```
/form-compile <JsonPath> <OutputPath>
```

## Параметры

| Параметр   | Обязательный | Описание                          |
|------------|:------------:|-----------------------------------|
| JsonPath   | да           | Путь к JSON-определению формы     |
| OutputPath | да           | Путь к выходному файлу Form.xml   |

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\form-compile\scripts\form-compile.ps1 -JsonPath "<json>" -OutputPath "<xml>"
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
| `"input"`    | InputField        | имя элемента                                      |
| `"check"`    | CheckBoxField     | имя                                               |
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

**check**: `OnChange`

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
| `autoMaxWidth: false` | Отключить авто-ширину | для фиксированных полей |
| `horizontalStretch: true` | Растягивать по ширине | |

### Чекбокс (check)

| Ключ | Описание |
|------|----------|
| `path` | DataPath |
| `titleLocation` | Размещение заголовка |

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
| `united: false` | Не объединять рамку |
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
| `type` | `"usual"`, `"hyperlink"`, `"commandBar"` |
| `picture` | Картинка кнопки |
| `representation` | `"Auto"`, `"Text"`, `"Picture"`, `"PictureAndText"` |
| `locationInCommandBar` | `"Auto"`, `"InCommandBar"`, `"InAdditionalSubmenu"` |

### Командная панель (cmdBar)

| Ключ | Описание |
|------|----------|
| `autofill: true` | Автозаполнение стандартными командами |
| `children: [...]` | Кнопки панели |

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
{ "name": "Итого", "type": "decimal(15,2)" }
{ "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" }
]}
```

- `savedData: true` — сохраняемые данные

### Команды (commands)

```json
{ "name": "Загрузить", "action": "ЗагрузитьОбработка", "shortcut": "Ctrl+Enter" }
```

- `title` — заголовок (если отличается от name)
- `picture` — картинка команды

### Система типов

| DSL                    | XML                                    |
|------------------------|----------------------------------------|
| `"string"` / `"string(100)"` | `xs:string` + StringQualifiers  |
| `"decimal(15,2)"`     | `xs:decimal` + NumberQualifiers        |
| `"decimal(10,0,nonneg)"` | с AllowedSign=Nonnegative           |
| `"boolean"`            | `xs:boolean`                          |
| `"date"` / `"dateTime"` / `"time"` | `xs:dateTime` + DateFractions |
| `"CatalogRef.XXX"`    | `cfg:CatalogRef.XXX`                   |
| `"DocumentRef.XXX"`   | `cfg:DocumentRef.XXX`                  |
| `"ValueTable"`         | `v8:ValueTable`                       |
| `"ValueList"`          | `v8:ValueListType`                    |
| `"Type1 \| Type2"`    | составной тип                          |

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
    { "group": "horizontal", "name": "ГруппаКнопок", "children": [
      { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
      { "button": "Закрыть", "stdCommand": "Close" }
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

## Верификация

```
/form-validate <OutputPath>    — проверка корректности XML
/form-info <OutputPath>        — визуальная сводка структуры
```

## Особенности для внешних обработок (EPF)

- **Тип главного реквизита**: `ExternalDataProcessorObject.ИмяОбработки` (не `DataProcessorObject`)
- **DataPath**: используйте реквизиты формы (`ИмяРеквизита`), а не `Объект.ИмяРеквизита` — у внешних обработок нет реквизитов объекта в метаданных
- **Ссылочные типы**: `CatalogRef.XXX`, `DocumentRef.XXX` и т.д. могут не собраться в пустой базе — используйте `string` или базовые типы для автономной сборки
