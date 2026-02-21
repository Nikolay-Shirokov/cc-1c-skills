---
name: form-edit
description: Добавление элементов, реквизитов и команд в существующую управляемую форму 1С. Используй когда нужно точечно модифицировать готовую форму
argument-hint: <FormPath> <JsonPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /form-edit — Редактирование формы

Добавляет элементы, реквизиты и/или команды в существующий Form.xml. Автоматически выделяет ID из правильного пула, генерирует companion-элементы (ContextMenu, ExtendedTooltip, и др.) и обработчики событий.

## Использование

```
/form-edit <FormPath> <JsonPath>
```

## Параметры

| Параметр  | Обязательный | Описание                         |
|-----------|:------------:|----------------------------------|
| FormPath  | да           | Путь к существующему Form.xml    |
| JsonPath  | да           | Путь к JSON с описанием добавлений |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/form-edit/scripts/form-edit.ps1 -FormPath "<путь>" -JsonPath "<путь>"
```

## JSON формат

```json
{
  "into": "ГруппаШапка",
  "after": "Контрагент",
  "elements": [
    { "input": "Склад", "path": "Объект.Склад", "on": ["OnChange"] }
  ],
  "attributes": [
    { "name": "СуммаИтого", "type": "decimal(15,2)" }
  ],
  "commands": [
    { "name": "Рассчитать", "action": "РассчитатьОбработка" }
  ]
}
```

### Расширения (extension-формы)

Для заимствованных форм (с `<BaseForm>`) автоматически активируется extension-режим: ID начинаются с 1000000+. Доступны дополнительные секции:

```json
{
  "formEvents": [
    { "name": "OnCreateAtServer", "handler": "Расш1_ПриСозданииПосле", "callType": "After" },
    { "name": "OnOpen", "handler": "Расш1_ПриОткрытии", "callType": "Before" }
  ],
  "elementEvents": [
    { "element": "Банк", "name": "OnChange", "handler": "Расш1_БанкПриИзменении", "callType": "Before" }
  ],
  "commands": [
    { "name": "Подбор", "action": "Расш1_ПодборПосле", "callType": "After" },
    { "name": "Запрос", "actions": [
      { "callType": "Before", "handler": "Расш1_ЗапросПеред" },
      { "callType": "After", "handler": "Расш1_ЗапросПосле" }
    ]}
  ],
  "elements": [
    { "input": "Поле", "path": "Объект.Поле", "on": [{ "event": "OnChange", "callType": "After" }] }
  ]
}
```

### Позиционирование элементов

| Ключ | По умолчанию | Описание |
|------|-------------|----------|
| `into` | корневой ChildItems | Имя группы/таблицы/страницы, куда вставлять |
| `after` | в конец | Имя элемента, после которого вставлять |

### Типы элементов

Те же DSL-ключи, что в `/form-compile`:

| Ключ | XML тег | Companions |
|------|---------|------------|
| `input` | InputField | ContextMenu, ExtendedTooltip |
| `check` | CheckBoxField | ContextMenu, ExtendedTooltip |
| `label` | LabelDecoration | ContextMenu, ExtendedTooltip |
| `labelField` | LabelField | ContextMenu, ExtendedTooltip |
| `group` | UsualGroup | ExtendedTooltip |
| `table` | Table | ContextMenu, AutoCommandBar, Search*, ViewStatus* |
| `pages` | Pages | ExtendedTooltip |
| `page` | Page | ExtendedTooltip |
| `button` | Button | ExtendedTooltip |

Группы и таблицы поддерживают `children`/`columns` для вложенных элементов.

### Кнопки: command и stdCommand

- `"command": "ИмяКоманды"` → `Form.Command.ИмяКоманды`
- `"stdCommand": "Close"` → `Form.StandardCommand.Close`
- `"stdCommand": "Товары.Add"` → `Form.Item.Товары.StandardCommand.Add` (стандартная команда элемента)

### Допустимые события (`on`)

Компилятор предупреждает об ошибках в именах событий. Основные:

- **input**: `OnChange`, `StartChoice`, `ChoiceProcessing`, `Clearing`, `AutoComplete`, `TextEditEnd`
- **check**: `OnChange`
- **table**: `OnStartEdit`, `OnEditEnd`, `OnChange`, `Selection`, `BeforeAddRow`, `BeforeDeleteRow`, `OnActivateRow`
- **label/picture**: `Click`, `URLProcessing`
- **pages**: `OnCurrentPageChange`
- **button**: `Click`

### Система типов (для attributes)

`string`, `string(100)`, `decimal(15,2)`, `boolean`, `date`, `dateTime`, `CatalogRef.XXX`, `DocumentObject.XXX`, `ValueTable`, `DynamicList`, `Type1 | Type2` (составной).

### Секции расширений

| Секция | Назначение |
|--------|-----------|
| `formEvents` | События уровня формы с `callType` (Before/After/Override) |
| `elementEvents` | События на существующих элементах заимствованной формы |
| `callType` на `commands` | callType на Action команды |
| `callType` на `on` | callType на событиях новых элементов (объектный формат) |

Все extension-секции опциональны — без них навык работает как с обычными формами.

## Вывод

```
=== form-edit: Форма ===

[EXTENSION] BaseForm detected — IDs start at 1000000+

Added form events:
  + OnCreateAtServer[After] -> Расш1_ПриСозданииПосле

Added elements (into ГруппаШапка, after Контрагент):
  + [Input] Склад -> Объект.Склад {OnChange}

Added attributes:
  + СуммаИтого: decimal(15,2) (id=1000000)

---
Total: 1 form event(s), 1 element(s) (+2 companions), 1 attribute(s)
Run /form-validate to verify.
```

## Когда использовать

- **После `/form-compile`**: добавить элементы, которые не были в исходном JSON
- **Модификация существующих форм**: добавить поле, реквизит или команду в форму из конфигурации
- **Пакетное добавление**: один JSON может содержать элементы + реквизиты + команды

## Workflow

1. `/form-info` — посмотреть текущую структуру формы
2. Создать JSON с описанием добавлений
3. `/form-edit` — добавить в форму
4. `/form-validate` — проверить корректность
5. `/form-info` — убедиться что добавилось правильно
