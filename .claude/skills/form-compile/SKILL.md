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

## JSON DSL — краткая справка

### Элементы (ключ определяет тип)

| DSL ключ     | XML элемент       | Значение ключа                                    |
|--------------|-------------------|---------------------------------------------------|
| `"group"`    | UsualGroup        | `"horizontal"` / `"vertical"` / `"alwaysHorizontal"` / `"alwaysVertical"` / `"collapsible"` |
| `"input"`    | InputField        | имя элемента                                      |
| `"check"`    | CheckBoxField     | имя                                               |
| `"label"`    | LabelDecoration   | имя                                               |
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

### Общие свойства элементов

- `"name"` — переопределить имя (по умолчанию из значения ключа типа)
- `"path"` — DataPath (привязка к данным)
- `"title"` — заголовок
- `"visible": false` — Visible=false (скрыть элемент)
- `"enabled": false` — Enabled=false (сделать недоступным)
- `"readOnly": true` — ReadOnly=true
- `"on": ["OnChange", "StartChoice"]` — события с автоименованием обработчиков

### Система типов (shorthand)

| DSL                    | XML                                    |
|------------------------|----------------------------------------|
| `"string"` / `"string(100)"` | `xs:string` + StringQualifiers  |
| `"decimal(15,2)"`     | `xs:decimal` + NumberQualifiers        |
| `"decimal(10,0,nonneg)"` | с AllowedSign=Nonnegative           |
| `"boolean"`            | `xs:boolean`                          |
| `"date"` / `"dateTime"` / `"time"` | `xs:dateTime` + DateFractions |
| `"CatalogRef.Организации"` | `cfg:CatalogRef.Организации`     |
| `"DocumentObject.Реализация"` | `cfg:DocumentObject.Реализация` |
| `"ValueTable"`         | `v8:ValueTable`                       |
| `"ValueList"`          | `v8:ValueListType`                    |
| `"Type1 \| Type2"`    | составной тип                          |

### Пример JSON

```json
{
  "title": "Загрузка данных",
  "properties": { "autoTitle": false },
  "events": { "OnCreateAtServer": "ПриСозданииНаСервере" },
  "elements": [
    { "group": "horizontal", "name": "Шапка", "children": [
      { "input": "Организация", "path": "Объект.Организация", "on": ["OnChange"] }
    ]},
    { "table": "Товары", "path": "Объект.Товары", "columns": [
      { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура" }
    ]}
  ],
  "attributes": [
    { "name": "Объект", "type": "DataProcessorObject.ЗагрузкаДанных", "main": true }
  ],
  "commands": [
    { "name": "Загрузить", "action": "ЗагрузитьОбработка", "shortcut": "Ctrl+Enter" }
  ]
}
```

### Автогенерация

- **Companion-элементы**: ContextMenu, ExtendedTooltip и др. создаются автоматически с правильными именами и ID
- **Обработчики событий**: `"on": ["OnChange"]` → `<Event name="OnChange">ОрганизацияПриИзменении</Event>`
- **Namespace**: все 17 namespace-деклараций добавляются автоматически
- **ID**: последовательная нумерация, AutoCommandBar всегда id="-1"

## Верификация

Используйте `/form-info` для проверки результата:

```
/form-info <OutputPath>
```

Структура в сводке должна совпадать с определением в JSON.

