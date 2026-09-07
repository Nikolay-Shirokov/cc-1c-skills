---
name: meta-edit
description: Точечное редактирование объекта метаданных 1С. Используй когда нужно добавить, удалить или изменить реквизиты, табличные части, измерения, ресурсы или свойства существующего объекта конфигурации
argument-hint: <ObjectPath> -Operation <op> -Value "<val>" | -DefinitionFile <json> [-NoValidate]
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /meta-edit — точечное редактирование метаданных 1С

Атомарные операции модификации существующих XML объектов метаданных.

## Команда

### Inline mode (простые операции)

```powershell
powershell.exe -NoProfile -File ".cline/skills/meta-edit/scripts/meta-edit.ps1" -ObjectPath "<path>" -Operation <op> -Value "<val>"
```

### JSON mode (сложные/комбинированные)

```powershell
powershell.exe -NoProfile -File ".cline/skills/meta-edit/scripts/meta-edit.ps1" -DefinitionFile "<json>" -ObjectPath "<path>"
```

| Параметр | Описание |
|----------|----------|
| ObjectPath | XML-файл или директория объекта (обязательный, авторезолв `<dirName>.xml`) |
| Operation | Inline-операция (альтернатива DefinitionFile) |
| Value | Значение для inline-операции |
| DefinitionFile | JSON-файл с операциями (альтернатива Operation) |
| NoValidate | Не запускать meta-validate после правки |

## Частые операции

Batch через `;;` во всех операциях.

| Операция | Формат Value | Пример |
|----------|-------------|--------|
| `add-attribute` | `Имя: Тип \| флаги` | `"Сумма: Число(15,2) \| req, index"` |
| `add-dimension` | `Имя: Тип \| флаги` | `"Организация: CatalogRef.Организации \| master"` |
| `add-resource` | `Имя: Тип` | `"Сумма: Число(15,2)"` |
| `add-column` | `Имя: Тип` | `"Тип: EnumRef.ТипыДокументов"` |
| `add-ts` | `ТЧ: Рекв1: Тип1, Рекв2: Тип2` | `"Товары: Ном: CatalogRef.Ном, Кол: Число(15,3)"` |
| `add-ts-attribute` | `ТЧ.Имя: Тип` | `"Товары.Скидка: Число(15,2)"` |
| `remove-*` | `Имя` | `"СтарыйРеквизит ;; ЕщёОдин"` |
| `remove-ts-attribute` | `ТЧ.Имя` | `"Товары.УстаревшийРекв"` |
| `modify-attribute` | `Имя: ключ=значение` | `"СтароеИмя: name=НовоеИмя, type=Строка(500)"` |
| `modify-ts-attribute` | `ТЧ.Имя: ключ=значение` | `"Товары.Рекв: name=НовоеИмя"` |
| `modify-ts` | `ТЧ: ключ=значение` | `"Товары: synonym=Товарный состав"` |
| `modify-property` | `Ключ=Значение` | `"CodeLength=11 ;; DescriptionLength=150"` |

Позиционная вставка: `"Склад: CatalogRef.Склады >> after Организация"`.

Составной тип — через `+`: `"Значение: Строка + Число(15,2) + Дата"`.

## Быстрые примеры

```powershell
# Добавить реквизиты
-Operation add-attribute -Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"

# Добавить ТЧ с реквизитами
-Operation add-ts -Value "Товары: Ном: CatalogRef.Ном | req, Кол: Число(15,3), Цена: Число(15,2)"

# Удалить реквизит
-Operation remove-attribute -Value "УстаревшийРеквизит"

# Переименовать + сменить тип
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"

# Изменить свойства объекта
-Operation modify-property -Value "CodeLength=11 ;; DescriptionLength=150"

# Владельцы справочника
-Operation set-owners -Value "Catalog.Контрагенты ;; Catalog.Организации"
```

## Индекс: что правишь → файл

| Что нужно | Файл |
|-----------|------|
| Реквизит, измерение, ресурс, графа: флаги, составные типы, структурные свойства (`Format`, `ChoiceParameters`, `FillValue`, …) | `reference/attributes.md` |
| Табличная часть и её реквизиты | `reference/tabular-sections.md` |
| Свойства самого объекта, списочные свойства (владельцы, движения, основание, ввод по строке) | `reference/properties.md` |
| Предопределённые элементы | `reference/predefined.md` |
| Значения перечисления, команды | `reference/other-children.md` |
| Внешний источник данных: поля, таблицы, функции | `reference/external-data-source.md` |
| Комбинированные операции в одном JSON, синонимы ключей и типов, какие дети допустимы у типа объекта | `reference/json-dsl.md` |

Форму добавляет и удаляет навык `form-add` / `form-remove`, макет — навык `template-add` /
`template-remove`: кроме записи в `ChildObjects` у них есть собственные файлы, и `meta-edit` их не трогает.

## Верификация

```
/meta-validate <ObjectPath>    — валидация после редактирования
/meta-info <ObjectPath>        — визуальная сводка
```
