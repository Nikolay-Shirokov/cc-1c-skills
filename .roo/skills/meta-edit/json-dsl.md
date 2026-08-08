# JSON DSL — режим определений

Для сложных и комбинированных операций используйте JSON-файл вместо inline-режима.

```powershell
powershell.exe -NoProfile -File .claude/skills/meta-edit/scripts/meta-edit.ps1 -DefinitionFile "<json>" -ObjectPath "<path>"
```

## add — добавить элементы

```json
{
  "add": {
    "attributes": [
      { "name": "Комментарий", "type": "Строка(200)" },
      { "name": "Сумма", "type": "Число(15,2)", "indexing": "Index" }
    ],
    "tabularSections": [{
      "name": "Товары",
      "attrs": [
        { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
        { "name": "Количество", "type": "Число(15,3)" }
      ]
    }],
    "forms": ["ФормаЭлемента"],
    "templates": ["ПечатнаяФорма"]
  }
}
```

Реквизиты можно задавать shorthand-строками: `"Сумма: Число(15,2) | req, index"`.

## remove — удалить элементы

```json
{
  "remove": {
    "attributes": ["СтарыйРеквизит"],
    "tabularSections": ["УстаревшаяТЧ"]
  }
}
```

## modify — изменить существующие

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
    "attributes": {
      "Комментарий": { "type": "Строка(500)" },
      "СтароеИмя": { "name": "НовоеИмя" }
    }
  }
}
```

## modify — реквизиты внутри ТЧ

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

## Комбинирование

Все три операции (`add`, `remove`, `modify`) можно указать в одном JSON-файле:

```json
{
  "add": { "tabularSections": [{ "name": "НоваяТЧ", "attrs": ["Имя: Строка(100)"] }] },
  "modify": {
    "tabularSections": {
      "СуществующаяТЧ": {
        "add": ["НовыйРекв: Число(15,2)"],
        "remove": ["СтарыйРекв"]
      }
    }
  }
}
```

## Позиционная вставка

```json
{ "name": "Склад", "type": "CatalogRef.Склады", "after": "Организация" }
```

## Синонимы ключей (case-insensitive)

**Операции:** `add`/`добавить`, `remove`/`удалить`, `modify`/`изменить`

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

## Составные типы

Для полей с несколькими допустимыми типами — массив в `type`:

```json
{ "name": "Значение", "type": ["Строка", "Число(15,2)", "Дата", "CatalogRef.Контрагенты"] }
```

В inline-формате — через `+`:
```
"Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"
```

## Синонимы типов

`Строка(200)`, `Число(15,2)`, `Булево`, `Дата`, `ДатаВремя`, `ХранилищеЗначения`, `СправочникСсылка.XXX`, `ДокументСсылка.XXX`, `ПеречислениеСсылка.XXX`, `ОпределяемыйТип.XXX`.

## Поддерживаемые типы объектов

| Тип объекта | Допустимые add-типы |
|-------------|-------------------|
| Catalog, Document, ExchangePlan, ChartOf*, BP, Task, Report, DP | attributes, tabularSections, forms, templates, commands |
| Enum | enumValues, forms, templates, commands |
| *Register (4 типа) | dimensions, resources, attributes, forms, templates, commands |
| DocumentJournal | columns, forms, templates, commands |
| Constant | forms |
