---
name: skd-compile
description: Компиляция схемы компоновки данных 1С (СКД) — Template.xml из компактного JSON-определения
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

Типы: `string`, `string(N)`, `decimal(D,F)`, `boolean`, `date`, `dateTime`, `CatalogRef.X`, `DocumentRef.X`, `EnumRef.X`, `StandardPeriod`. Ссылочные типы (`CatalogRef`, `DocumentRef`, `EnumRef`) задают роли полей, но не эмитируются в `<valueType>` — платформа определяет их из запроса.

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

Формат: `"Поле оператор значение @флаги"`. Значение `_` = пустое (placeholder). Флаги: `@off` (use=false), `@user` (userSettingID=auto), `@quickAccess`.

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
    "outputParameters": { "Заголовок": "Мой отчёт" },
    "dataParameters": ["Период = LastMonth @user"],
    "structure": "Организация > details"
  }
}]
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
