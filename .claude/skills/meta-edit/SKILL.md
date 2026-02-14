---
name: meta-edit
description: Точечное редактирование объекта метаданных 1С (добавление/удаление/модификация реквизитов, реквизитов внутри ТЧ, ТЧ, измерений, ресурсов, значений перечислений, свойств объекта, владельцев, движений, ввода по строке)
argument-hint: <ObjectPath> -Operation <op> -Value "<val>" | -DefinitionFile <json> [-NoValidate]
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /meta-edit — точечное редактирование метаданных 1С

Атомарные операции модификации существующих XML объектов метаданных: добавление, удаление и модификация реквизитов, табличных частей, измерений, ресурсов, значений перечислений, свойств объекта, владельцев, движений по регистрам, оснований, ввода по строке.

## Два режима работы

### Inline mode (рекомендуется для простых операций)

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-edit\scripts\meta-edit.ps1 -ObjectPath "<path>" -Operation <op> -Value "<val>"
```

### JSON mode (для сложных/комбинированных операций)

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-edit\scripts\meta-edit.ps1 -DefinitionFile "<json>" -ObjectPath "<path>"
```

| Параметр | Описание |
|----------|----------|
| ObjectPath | XML-файл или директория объекта (обязательный) |
| Operation | Inline-операция (альтернатива DefinitionFile) |
| Value | Значение для inline-операции |
| DefinitionFile | JSON-файл с операциями (альтернатива Operation) |
| NoValidate | Не запускать meta-validate после правки |

`ObjectPath` авторезолв: если указана директория — ищет `<dirName>.xml` в ней.

## Inline mode — операции

### Batch-режим

Несколько элементов через `;;`:
```
-Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"
```

### add-attribute / add-dimension / add-resource / add-column

Shorthand-формат: `Имя: Тип | флаги`

```powershell
-Operation add-attribute -Value "Комментарий: Строка(200)"
-Operation add-attribute -Value "Сумма: Число(15,2) | req, index"
-Operation add-attribute -Value "Ном: CatalogRef.Номенклатура | req ;; Кол: Число(15,3)"
-Operation add-dimension -Value "Организация: CatalogRef.Организации | master, mainFilter"
```

Позиционная вставка: `>> after ИмяЭлемента` или `<< before ИмяЭлемента`:
```powershell
-Operation add-attribute -Value "Склад: CatalogRef.Склады >> after Организация"
```

### add-ts

Формат: `ИмяТЧ: Реквизит1: Тип1, Реквизит2: Тип2, ...`

```powershell
-Operation add-ts -Value "Товары: Ном: CatalogRef.Ном | req, Кол: Число(15,3), Цена: Число(15,2), Сумма: Число(15,2)"
```

### add-ts-attribute / remove-ts-attribute / modify-ts-attribute

Операции над реквизитами **внутри существующей табличной части**. Формат: `ИмяТЧ.ОпределениеРеквизита` (dot-нотация).

```powershell
# Добавить реквизит в ТЧ
-Operation add-ts-attribute -Value "Товары.СтавкаНДС: EnumRef.СтавкиНДС"
-Operation add-ts-attribute -Value "Товары.Скидка: Число(15,2) ;; Товары.Бонус: Число(15,2)"

# Удалить реквизит из ТЧ
-Operation remove-ts-attribute -Value "Товары.УстаревшийРекв"
-Operation remove-ts-attribute -Value "Товары.Рекв1 ;; Товары.Рекв2"

# Изменить реквизит в ТЧ (rename, type change и т.д.)
-Operation modify-ts-attribute -Value "Товары.СтароеИмя: name=НовоеИмя, type=Строка(500)"
```

Batch через `;;` — можно указать разные ТЧ: `"Товары.А: Строка(50) ;; Услуги.Б: Число(10)"`.

### add-enumValue / add-form / add-template / add-command

Просто имена (batch через `;;`):
```powershell
-Operation add-enumValue -Value "Значение1 ;; Значение2 ;; Значение3"
-Operation add-form -Value "ФормаЭлемента ;; ФормаСписка"
```

### add-owner / add-registerRecord / add-basedOn

Полное имя метаданных `MetaType.Name`:
```powershell
-Operation add-owner -Value "Catalog.Контрагенты ;; Catalog.Организации"
-Operation add-registerRecord -Value "AccumulationRegister.ОстаткиТоваров"
-Operation add-basedOn -Value "Document.ЗаказКлиента"
```

### add-inputByString

Пути полей (префикс `MetaType.Name.` добавляется автоматически):
```powershell
-Operation add-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
```

### remove-*

Имя элемента (или несколько через `;;`):
```powershell
-Operation remove-attribute -Value "СтарыйРеквизит ;; ЕщёОдин"
-Operation remove-owner -Value "Catalog.Контрагенты"
-Operation remove-inputByString -Value "Catalog.МойСпр.StandardAttribute.Code"
```

### modify-attribute / modify-dimension / modify-resource / modify-enumValue / modify-column

Формат: `ИмяЭлемента: ключ=значение, ключ=значение`

Ключи: `name` (rename), `type`, `synonym`, `indexing`, `fillChecking`, `use` и др.

```powershell
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"
-Operation modify-attribute -Value "Комментарий: indexing=Index"
```

### modify-property

Формат: `Ключ=Значение` (batch через `;;`):
```powershell
-Operation modify-property -Value "CodeLength=11 ;; DescriptionLength=150"
-Operation modify-property -Value "Hierarchical=true"
```

### set-owners / set-registerRecords / set-basedOn / set-inputByString

Заменяют **весь список** (в отличие от add/remove):
```powershell
-Operation set-owners -Value "Catalog.Организации ;; Catalog.Контрагенты"
-Operation set-registerRecords -Value "AccumulationRegister.Продажи ;; AccumulationRegister.ОстаткиТоваров"
-Operation set-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
```

## JSON DSL

### add — добавить элементы

```json
{
  "add": {
    "реквизиты": [
      { "name": "Комментарий", "type": "Строка(200)" },
      { "name": "Сумма", "type": "Число(15,2)", "indexing": "Index" }
    ],
    "ТЧ": [{
      "name": "Товары",
      "attrs": [
        { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
        { "name": "Количество", "type": "Число(15,3)" }
      ]
    }],
    "формы": ["ФормаЭлемента"],
    "макеты": ["ПечатнаяФорма"]
  }
}
```

### remove — удалить элементы

```json
{
  "remove": {
    "реквизиты": ["СтарыйРеквизит"],
    "ТЧ": ["УстаревшаяТЧ"]
  }
}
```

### modify — изменить существующие

```json
{
  "modify": {
    "properties": {
      "CodeLength": 11,
      "Hierarchical": true,
      "Owners": ["Catalog.Контрагенты", "Catalog.Организации"],
      "RegisterRecords": ["AccumulationRegister.Продажи"],
      "InputByString": ["StandardAttribute.Description"]
    },
    "реквизиты": {
      "Комментарий": { "type": "Строка(500)" },
      "СтароеИмя": { "name": "НовоеИмя" }
    }
  }
}
```

### modify — реквизиты внутри ТЧ (JSON)

```json
{
  "modify": {
    "tabularSections": {
      "Товары": {
        "add": ["СтавкаНДС: EnumRef.СтавкиНДС", "Скидка: Число(15,2)"],
        "remove": ["УстаревшийРекв"],
        "modify": {
          "СтароеИмя": { "name": "НовоеИмя", "type": "Строка(500)" }
        }
      }
    }
  }
}
```

### Комбинирование

Все три операции можно указать в одном JSON-файле. Для сложных сценариев (ТЧ с реквизитами + удаление + модификация) используйте JSON DSL.

### Синонимы ключей (case-insensitive)

**Операции:** `add`/`добавить`, `remove`/`удалить`, `modify`/`изменить`

**Типы дочерних элементов:**

| Каноническое | Синонимы |
|-------------|----------|
| attributes | реквизиты, attrs |
| tabularSections | табличныеЧасти, тч, ts |
| dimensions | измерения, dims |
| resources | ресурсы, res |
| enumValues | значения, values |
| columns | графы, колонки |
| forms | формы |
| templates | макеты |
| commands | команды |
| properties | свойства |

### Синонимы типов

`Строка(200)`, `Число(15,2)`, `Булево`, `Дата`, `ДатаВремя`, `ХранилищеЗначения`, `СправочникСсылка.XXX`, `ДокументСсылка.XXX`, `ПеречислениеСсылка.XXX`, `ОпределяемыйТип.XXX`.

### Позиционная вставка

JSON: `{ "name": "Склад", "type": "CatalogRef.Склады", "after": "Организация" }`

Inline: `"Склад: CatalogRef.Склады >> after Организация"` или `"Склад: CatalogRef.Склады << before Комментарий"`

### Shorthand-формат реквизитов

```
"ИмяРеквизита: Тип | req, index"
```

## Complex properties — Owners, RegisterRecords, BasedOn, InputByString

Свойства со вложенной XML-структурой (не скалярный InnerText). Поддерживаются через inline-операции `add-*` / `remove-*` / `set-*` и через JSON `modify.properties`.

| Свойство | Объекты | XML-тег | Inline-значение |
|----------|---------|---------|-----------------|
| Owners | Catalog, ChartOfCharacteristicTypes | `<xr:Item xsi:type="xr:MDObjectRef">` | `Catalog.XXX` |
| RegisterRecords | Document | `<xr:Item xsi:type="xr:MDObjectRef">` | `AccumulationRegister.XXX` |
| BasedOn | Document, Catalog, BP, Task | `<xr:Item xsi:type="xr:MDObjectRef">` | `Document.XXX` |
| InputByString | Catalog, ChartOf*, Task | `<xr:Field>` | `StandardAttribute.Description` |

## Поддерживаемые типы объектов

| Тип объекта | Допустимые add-типы |
|-------------|-------------------|
| Catalog, Document, ExchangePlan, ChartOf*, BP, Task, Report, DP | attributes, tabularSections, forms, templates, commands |
| Enum | enumValues, forms, templates, commands |
| *Register (4 типа) | dimensions, resources, attributes, forms, templates, commands |
| DocumentJournal | columns, forms, templates, commands |
| Constant | forms |

## Примеры

### Inline: добавить реквизиты

```powershell
-Operation add-attribute -Value "Комментарий: String(200) ;; Сумма: Число(15,2) | index"
```

### Inline: добавить ТЧ с реквизитами

```powershell
-Operation add-ts -Value "Товары: Ном: CatalogRef.Ном | req, Кол: Число(15,3), Цена: Число(15,2)"
```

### Inline: удалить + изменить (два вызова)

```powershell
-Operation remove-attribute -Value "УстаревшийРеквизит"
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=String(500)"
```

### Inline: владельцы справочника

```powershell
-Operation set-owners -Value "Catalog.Контрагенты ;; Catalog.Организации"
```

### Inline: движения документа

```powershell
-Operation add-registerRecord -Value "AccumulationRegister.Продажи ;; AccumulationRegister.ОстаткиТоваров"
```

### JSON: комплексное редактирование

```json
{
  "add": {
    "attributes": ["Комментарий: String(200)"],
    "tabularSections": [{
      "name": "Товары",
      "attrs": ["Ном: CatalogRef.Ном | req", "Кол: Number(15,3)"]
    }]
  },
  "remove": { "attributes": ["УстаревшийРеквизит"] },
  "modify": {
    "properties": {
      "DescriptionLength": 150,
      "Owners": ["Catalog.Контрагенты", "Catalog.Организации"]
    },
    "attributes": { "СтароеИмя": { "name": "НовоеИмя" } }
  }
}
```

## Верификация

```
/meta-validate <ObjectPath>    — валидация после редактирования
/meta-info <ObjectPath>        — визуальная сводка
```

## Когда использовать

- **Добавление реквизитов/ТЧ** к существующим объектам конфигурации
- **Редактирование реквизитов внутри ТЧ** — добавление, удаление, переименование, смена типа
- **Удаление устаревших** реквизитов, табличных частей
- **Переименование** реквизитов, смена типа
- **Изменение свойств** объекта (длина кода, иерархия и т.д.)
- **Добавление значений** перечислений
- **Добавление измерений/ресурсов** в регистры
- **Управление владельцами** справочников (Owners)
- **Управление движениями** документов (RegisterRecords)
- **Настройка ввода по строке** (InputByString)
- **Управление основаниями** (BasedOn)
