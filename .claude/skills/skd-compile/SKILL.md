---
name: skd-compile
description: Компиляция схемы компоновки данных 1С (СКД) из компактного JSON-определения. Используй когда нужно создать СКД с нуля
argument-hint: <JsonPath> <OutputPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /skd-compile — генерация СКД из JSON DSL

Принимает JSON-определение схемы компоновки данных → генерирует Template.xml (DataCompositionSchema).

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `JsonPath` | Путь к JSON-определению СКД |
| `OutputPath` | Путь к выходному Template.xml |

```powershell
powershell.exe -NoProfile -File .claude\skills\skd-compile\scripts\skd-compile.ps1 -JsonPath "<json>" -OutputPath "<Template.xml>"
```

## JSON DSL — краткий справочник

Полная спецификация: `docs/skd-dsl-spec.md`.

### Корневая структура

```json
{
  "dataSets": [...],
  "calculatedFields": [...],
  "totalFields": [...],
  "parameters": [...],
  "dataSetLinks": [...],
  "settingsVariants": [...]
}
```

Умолчания: `dataSources` → авто `ИсточникДанных1/Local`; `settingsVariants` → авто "Основной" с деталями.

### Наборы данных

Тип по ключу: `query` → DataSetQuery, `objectName` → DataSetObject, `items` → DataSetUnion.

```json
{ "name": "Продажи", "query": "ВЫБРАТЬ ...", "fields": [...] }
```

### Поля — shorthand

```
"Наименование"                              — просто имя
"Количество: decimal(15,2)"                  — имя + тип
"Организация: CatalogRef.Организации @dimension"  — + роль
"Служебное: string #noFilter #noOrder"       — + ограничения
```

Типы: `string`, `string(N)`, `decimal(D,F)`, `boolean`, `date`, `dateTime`, `CatalogRef.X`, `DocumentRef.X`, `EnumRef.X`, `StandardPeriod`. Ссылочные типы эмитируются с inline namespace `d5p1:` (`http://v8.1c.ru/8.1/data/enterprise/current-config`). Сборка EPF со ссылочными типами требует базу с соответствующей конфигурацией.

**Синонимы типов** (русские и альтернативные): `число` = decimal, `строка` = string, `булево` = boolean, `дата` = date, `датаВремя` = dateTime, `СтандартныйПериод` = StandardPeriod, `СправочникСсылка.X` = CatalogRef.X, `ДокументСсылка.X` = DocumentRef.X, `int`/`number` = decimal, `bool` = boolean. Регистронезависимые.

Роли: `@dimension`, `@account`, `@balance`, `@period`.

Ограничения: `#noField`, `#noFilter`, `#noGroup`, `#noOrder`.

### Итоги (shorthand)

```json
"totalFields": ["Количество: Сумма", "Стоимость: Сумма(Кол * Цена)"]
```

### Параметры (shorthand + @autoDates)

```json
"parameters": [
  "Период: StandardPeriod = LastMonth @autoDates"
]
```

`@autoDates` — автоматически генерирует параметры `ДатаНачала` и `ДатаОкончания` с выражениями `&Период.ДатаНачала` / `&Период.ДатаОкончания` и `availableAsField=false`. Заменяет 5 строк на 1.

### Фильтры — shorthand

```json
"filter": [
  "Организация = _ @off @user",
  "Дата >= 2024-01-01T00:00:00",
  "Статус filled"
]
```

Формат: `"Поле оператор значение @флаги"`. Значение `_` = пустое (placeholder). Флаги: `@off` (use=false), `@user` (userSettingID=auto), `@quickAccess`, `@normal`, `@inaccessible`.

В объектной форме доступны: `viewMode`, `userSettingID`, `userSettingPresentation`.

Группы фильтров (Or/And/Not):
```json
{ "group": "Or", "items": [
  { "group": "And", "items": [
    { "field": "Статус", "op": "=", "value": "Активен" },
    { "field": "Сумма", "op": ">", "value": 1000 }
  ]},
  { "field": "Количество", "op": "filled" }
]}
```

### Параметры данных — shorthand

```json
"dataParameters": [
  "Период = LastMonth @user",
  "Организация @off @user"
]
```

Формат: `"Имя [= значение] @флаги"`. Для StandardPeriod варианты (LastMonth, ThisYear и т.д.) распознаются автоматически.

### Структура — string shorthand

```json
"structure": "Организация > details"
"structure": "Организация > Номенклатура > details"
```

`>` разделяет уровни группировки. `details` (или `детали`) = детальные записи. `selection` и `order` по умолчанию `["Auto"]` на каждом уровне.

Для сложных случаев (таблицы, диаграммы, фильтры на уровне группировки) используется объектная форма.

### Варианты настроек

```json
"settingsVariants": [{
  "name": "Основной",
  "settings": {
    "selection": ["Номенклатура", "Количество", "Auto"],
    "filter": ["Организация = _ @off @user"],
    "order": ["Количество desc", "Auto"],
    "conditionalAppearance": [
      {
        "filter": ["Просрочено = true"],
        "appearance": { "ЦветТекста": "style:ПросроченныеДанныеЦвет" },
        "presentation": "Выделять просроченные",
        "viewMode": "Normal",
        "userSettingID": "auto"
      }
    ],
    "outputParameters": { "Заголовок": "Мой отчёт" },
    "dataParameters": ["Период = LastMonth @user"],
    "structure": "Организация > details"
  }
}]
```

### Условное оформление (conditionalAppearance)

```json
"conditionalAppearance": [
  {
    "selection": ["Поле1"],
    "filter": ["Поле1 notFilled"],
    "appearance": { "Текст": "Не указано", "ЦветТекста": "style:XXX" },
    "presentation": "Описание",
    "viewMode": "Normal",
    "userSettingID": "auto"
  }
]
```

Типы значений appearance: `style:XXX`/`web:XXX`/`win:XXX` → Color, `true`/`false` → Boolean, параметр `Текст` → LocalStringType, прочее → String.

### Итоги с привязкой к группировкам

```json
"totalFields": [
  { "dataPath": "Кол", "expression": "Сумма(Кол)", "group": ["Группа1", "Группа1 Иерархия", "ОбщийИтог"] }
]
```

## Примеры

### Минимальный

```json
{
  "dataSets": [{
    "query": "ВЫБРАТЬ Номенклатура.Наименование КАК Наименование ИЗ Справочник.Номенклатура КАК Номенклатура",
    "fields": ["Наименование"]
  }]
}
```

### С ресурсами, параметрами и @autoDates

```json
{
  "dataSets": [{
    "query": "ВЫБРАТЬ Продажи.Номенклатура, Продажи.Количество, Продажи.Сумма ИЗ РегистрНакопления.Продажи КАК Продажи",
    "fields": ["Номенклатура: СправочникСсылка.Номенклатура @dimension", "Количество: число(15,3)", "Сумма: число(15,2)"]
  }],
  "totalFields": ["Количество: Сумма", "Сумма: Сумма"],
  "parameters": ["Период: СтандартныйПериод = LastMonth @autoDates"],
  "settingsVariants": [{
    "name": "Основной",
    "settings": {
      "selection": ["Номенклатура", "Количество", "Сумма", "Auto"],
      "filter": ["Организация = _ @off @user"],
      "dataParameters": ["Период = LastMonth @user"],
      "structure": "Организация > details"
    }
  }]
}
```

## Верификация

```
/skd-validate <OutputPath>                  — валидация структуры XML
/skd-info <OutputPath>                      — визуальная сводка
/skd-info <OutputPath> -Mode variant -Name 1 — проверка варианта настроек
```
