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
powershell.exe -NoProfile -File .claude\skills\meta-edit\scripts\meta-edit.ps1 -ObjectPath "<path>" -Operation <op> -Value "<val>"
```

### JSON mode (сложные/комбинированные)

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-edit\scripts\meta-edit.ps1 -DefinitionFile "<json>" -ObjectPath "<path>"
```

| Параметр | Описание |
|----------|----------|
| ObjectPath | XML-файл или директория объекта (обязательный, авторезолв `<dirName>.xml`) |
| Operation | Inline-операция (альтернатива DefinitionFile) |
| Value | Значение для inline-операции |
| DefinitionFile | JSON-файл с операциями (альтернатива Operation) |
| NoValidate | Не запускать meta-validate после правки |

## Операции — сводная таблица

Batch через `;;` во всех операциях. Подробный синтаксис — в файлах по ссылкам.

### Дочерние элементы — [child-operations.md](child-operations.md)

| Операция | Формат Value | Пример |
|----------|-------------|--------|
| `add-attribute` | `Имя: Тип \| флаги` | `"Сумма: Число(15,2) \| req, index"` |
| `add-ts` | `ТЧ: Рекв1: Тип1, Рекв2: Тип2` | `"Товары: Ном: CatalogRef.Ном, Кол: Число(15,3)"` |
| `add-dimension` | `Имя: Тип \| флаги` | `"Организация: CatalogRef.Организации \| master"` |
| `add-resource` | `Имя: Тип` | `"Сумма: Число(15,2)"` |
| `add-enumValue` | `Имя` | `"Значение1 ;; Значение2"` |
| `add-column` | `Имя: Тип` | `"Тип: EnumRef.ТипыДокументов"` |
| `add-form` / `add-template` / `add-command` | `Имя` | `"ФормаЭлемента"` |
| `add-ts-attribute` | `ТЧ.Имя: Тип` | `"Товары.Скидка: Число(15,2)"` |
| `remove-*` | `Имя` | `"СтарыйРеквизит ;; ЕщёОдин"` |
| `remove-ts-attribute` | `ТЧ.Имя` | `"Товары.УстаревшийРекв"` |
| `modify-attribute` | `Имя: ключ=значение` | `"СтароеИмя: name=НовоеИмя, type=Строка(500)"` |
| `modify-ts-attribute` | `ТЧ.Имя: ключ=значение` | `"Товары.Рекв: name=НовоеИмя"` |
| `modify-ts` | `ТЧ: ключ=значение` | `"Товары: synonym=Товарный состав"` |

Позиционная вставка: `"Склад: CatalogRef.Склады >> after Организация"`.

### Свойства объекта — [properties-reference.md](properties-reference.md)

| Операция | Формат Value | Пример |
|----------|-------------|--------|
| `modify-property` | `Ключ=Значение` | `"CodeLength=11 ;; DescriptionLength=150"` |
| `add-owner` | `MetaType.Name` | `"Catalog.Контрагенты ;; Catalog.Организации"` |
| `add-registerRecord` | `MetaType.Name` | `"AccumulationRegister.ОстаткиТоваров"` |
| `add-basedOn` | `MetaType.Name` | `"Document.ЗаказКлиента"` |
| `add-inputByString` | `Путь поля` | `"StandardAttribute.Description"` |
| `set-owners` / `set-registerRecords` / `set-basedOn` / `set-inputByString` | Замена всего списка | `"Catalog.Орг ;; Catalog.Контр"` |
| `remove-owner` / `remove-registerRecord` / ... | Удаление из списка | `"Catalog.Контрагенты"` |

### JSON DSL — [json-dsl.md](json-dsl.md)

Для комбинированных операций (add + remove + modify в одном файле), синонимы ключей/типов, таблица поддерживаемых объектов.

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

## Верификация

```
/meta-validate <ObjectPath>    — валидация после редактирования
/meta-info <ObjectPath>        — визуальная сводка
```
