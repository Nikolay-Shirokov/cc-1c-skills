# JSON DSL для схемы компоновки данных (СКД)

Компактный JSON-формат для описания `DataCompositionSchema` (Template.xml).
Компилируется навыком `/skd-compile` в XML, валидируется `/skd-validate`.

---

## 1. Корневая структура

```json
{
  "dataSources": [...],
  "dataSets": [...],
  "dataSetLinks": [...],
  "calculatedFields": [...],
  "totalFields": [...],
  "parameters": [...],
  "templates": [...],
  "groupTemplates": [...],
  "settingsVariants": [...]
}
```

**Умолчания:**
- `dataSources` опущен → авто-создаётся `{ "name": "ИсточникДанных1", "type": "Local" }`
- `source` в наборе опущен → первый dataSource
- `name` набора опущен → "НаборДанных1", "НаборДанных2"...
- `settingsVariants` опущен → один вариант "Основной" с детальной группировкой и `selection: ["Auto"]`

---

## 2. Источники данных (dataSources)

```json
"dataSources": [
  { "name": "ИсточникДанных1", "type": "Local" }
]
```

| Поле | Обязат. | Умолчание | XML-маппинг |
|------|---------|-----------|-------------|
| `name` | да | — | `<name>` |
| `type` | нет | `"Local"` | `<dataSourceType>` |

Значения `type`: `"Local"`, `"External"`.

---

## 3. Наборы данных (dataSets)

Тип определяется по ключу-дискриминатору:

| Ключ | Тип | xsi:type |
|------|-----|----------|
| `query` | Запрос | `DataSetQuery` |
| `objectName` | Объект | `DataSetObject` |
| `items` | Объединение | `DataSetUnion` |

### DataSetQuery (самый частый)

```json
{ "name": "Продажи", "query": "ВЫБРАТЬ ...", "fields": [...], "autoFillFields": false }
```

### DataSetObject

```json
{ "name": "ТаблицаПроверки", "objectName": "ТаблицаПроверки", "fields": [...] }
```

### DataSetUnion

```json
{
  "name": "Объединение",
  "items": [
    { "name": "Набор1", "query": "...", "fields": [...] },
    { "name": "Набор2", "query": "...", "fields": [...] }
  ],
  "fields": [...]
}
```

| Поле | Обязат. | Описание |
|------|---------|----------|
| `name` | нет | Авто: "НаборДанных1"... |
| `source` | нет | Имя dataSource (авто: первый) |
| `query` | да* | Текст запроса (DataSetQuery) |
| `objectName` | да* | Имя объекта (DataSetObject) |
| `items` | да* | Вложенные наборы (DataSetUnion) |
| `fields` | нет | Массив полей |
| `autoFillFields` | нет | `false` — отключить автозаполнение (по умолчанию не выводится = true) |

---

## 4. Поля — shorthand и объектная форма

### Shorthand-строка

```
"<dataPath>[: <type>] [@role...] [#restrict...]"
```

Примеры:

```json
"fields": [
  "Наименование",
  "Количество: decimal(15,2)",
  "Организация: CatalogRef.Организации @dimension",
  "Служебное: string #noFilter #noOrder",
  "Счёт: CatalogRef.Хозрасчетный @account",
  "Сумма: decimal(15,2) @balance"
]
```

### Объектная форма

```json
{
  "dataPath": "Сумма",
  "field": "Сумма",
  "title": "Сумма продаж",
  "type": "decimal(15,2)",
  "role": { "dimension": true },
  "restrict": ["noFilter", "noGroup"],
  "attrRestrict": ["noFilter"],
  "appearance": { "Формат": "ЧДЦ=2" },
  "presentationExpression": "Формат(Сумма, \"ЧДЦ=2\")"
}
```

### Парсинг shorthand

1. Разделить по пробелам; найти `@`-роли и `#`-ограничения
2. Остаток до первого `:` — `dataPath` (и `field` по умолчанию)
3. После `:` до `@`/`#` — тип

### Типы

| DSL | XML v8:Type | Квалификатор |
|-----|-------------|--------------|
| `string` | `xs:string` | Length=0, AllowedLength=Variable |
| `string(N)` | `xs:string` | Length=N, AllowedLength=Variable |
| `decimal(D,F)` | `xs:decimal` | Digits=D, FractionDigits=F, AllowedSign=Any |
| `decimal(D,F,nonneg)` | `xs:decimal` | Digits=D, FractionDigits=F, AllowedSign=Nonnegative |
| `boolean` | `xs:boolean` | — |
| `date` | `xs:dateTime` | DateFractions=Date |
| `dateTime` | `xs:dateTime` | DateFractions=DateTime |
| `CatalogRef.XXX` | `d5p1:CatalogRef.XXX` | inline xmlns:d5p1 |
| `DocumentRef.XXX` | `d5p1:DocumentRef.XXX` | inline xmlns:d5p1 |
| `EnumRef.XXX` | `d5p1:EnumRef.XXX` | inline xmlns:d5p1 |
| `ChartOfAccountsRef.XXX` | `d5p1:ChartOfAccountsRef.XXX` | inline xmlns:d5p1 |
| `StandardPeriod` | `v8:StandardPeriod` | — |

> **Ссылочные типы** (`CatalogRef.XXX`, `DocumentRef.XXX` и др.) эмитируются с inline namespace declaration: `<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:CatalogRef.XXX</v8:Type>`. Использование префикса `cfg:` вместо `d5p1:` с объявлением namespace приводит к ошибке XDTO. Сборка EPF со ссылочными типами требует базу с соответствующей конфигурацией (не пустую).

### Синонимы типов

Все имена типов регистронезависимые. Поддерживаются русские и альтернативные имена:

| Синоним | Канонический тип |
|---------|-----------------|
| `число`, `Число` | `decimal` |
| `строка`, `Строка` | `string` |
| `булево`, `Булево`, `bool` | `boolean` |
| `дата`, `Дата` | `date` |
| `датаВремя`, `ДатаВремя` | `dateTime` |
| `СтандартныйПериод` | `StandardPeriod` |
| `int`, `integer`, `number`, `num` | `decimal` |
| `СправочникСсылка.XXX` | `CatalogRef.XXX` |
| `ДокументСсылка.XXX` | `DocumentRef.XXX` |
| `ПеречислениеСсылка.XXX` | `EnumRef.XXX` |
| `ПланСчетовСсылка.XXX` | `ChartOfAccountsRef.XXX` |
| `ПланВидовХарактеристикСсылка.XXX` | `ChartOfCharacteristicTypesRef.XXX` |

Параметризованные: `число(15,2)` → `decimal(15,2)`, `строка(100)` → `string(100)`.

### Роли

| DSL shorthand | Объектная форма | XML |
|---------------|----------------|-----|
| `@dimension` | `"role": "dimension"` или `{"dimension": true}` | `<dcscom:dimension>true</dcscom:dimension>` |
| `@account` | `"role": "account"` или `{"account": true}` | `<dcscom:account>true</dcscom:account>` |
| `@balance` | `"role": "balance"` или `{"balance": true}` | `<dcscom:balance>true</dcscom:balance>` |
| `@period` | `"role": "period"` или `{"period": true}` | `<dcscom:periodNumber>1</dcscom:periodNumber>` + `<dcscom:periodType>Main</dcscom:periodType>` |

Объектная форма с доп. полями:
```json
"role": {
  "account": true,
  "accountTypeExpression": "Счёт.ВидСчёта",
  "balanceGroup": "/Остатки"
}
```

### Ограничения

| DSL shorthand | Объектная форма | XML useRestriction |
|---------------|----------------|-----|
| `#noField` | `"noField"` | `<field>true</field>` |
| `#noFilter` / `#noCondition` | `"noFilter"` | `<condition>true</condition>` |
| `#noGroup` | `"noGroup"` | `<group>true</group>` |
| `#noOrder` | `"noOrder"` | `<order>true</order>` |

### Оформление (appearance)

```json
"appearance": {
  "Формат": "ЧДЦ=2",
  "ГоризонтальноеПоложение": "Center"
}
```

Маппинг на XML:
```xml
<appearance>
  <dcscor:item xsi:type="dcsset:SettingsParameterValue">
    <dcscor:parameter>Формат</dcscor:parameter>
    <dcscor:value xsi:type="xs:string">ЧДЦ=2</dcscor:value>
  </dcscor:item>
</appearance>
```

Значения `ГоризонтальноеПоложение` → `xsi:type="v8ui:HorizontalAlign"`.

---

## 5. Итоговые поля (totalFields)

### Shorthand

```
"<dataPath>: <Функция>"
"<dataPath>: <Функция>(<выражение>)"
```

Примеры:

```json
"totalFields": [
  "Количество: Сумма",
  "Цена: Максимум",
  "Стоимость: Сумма(Кол * Цена)"
]
```

**Парсинг:** `"A: Func"` → `dataPath=A`, `expression=Func(A)`. `"A: Func(expr)"` → `dataPath=A`, `expression=Func(expr)`.

Функции (русские): `Сумма`, `Количество`, `Максимум`, `Минимум`, `Среднее`.

### Объектная форма

```json
{ "dataPath": "X", "expression": "Максимум(X)", "group": "Группа1" }
```

---

## 6. Параметры (parameters)

### Shorthand

```
"<name>: <type> [= <default>] [@autoDates]"
```

Примеры:

```json
"parameters": [
  "Период: StandardPeriod = LastMonth @autoDates",
  "Организация: CatalogRef.Организации",
  "ДатаОтчета: date"
]
```

**Парсинг:** `"A: T = V"` → `name=A`, `type=T`, `value=V`. Значение `LastMonth` и другие варианты периодов → `v8:StandardPeriod` с `v8:variant`.

### @autoDates

Флаг `@autoDates` в shorthand параметра автоматически генерирует два дополнительных параметра:
- `ДатаНачала` (date, expression=`&<Имя>.ДатаНачала`, availableAsField=false)
- `ДатаОкончания` (date, expression=`&<Имя>.ДатаОкончания`, availableAsField=false)

Заменяет типовой бойлерплейт из 5 строк на 1:

```json
// Было:
"parameters": [
  "Период: StandardPeriod = LastMonth",
  { "name": "ДатаНачала", "type": "date", "expression": "&Период.ДатаНачала", "availableAsField": false },
  { "name": "ДатаОкончания", "type": "date", "expression": "&Период.ДатаОкончания", "availableAsField": false }
]

// Стало:
"parameters": ["Период: StandardPeriod = LastMonth @autoDates"]
```

### Объектная форма

```json
{
  "name": "ДатаНач",
  "title": "Дата начала",
  "type": "date",
  "value": "0001-01-01T00:00:00",
  "expression": "&Период.ДатаНачала",
  "availableAsField": false,
  "useRestriction": true,
  "use": "Always"
}
```

| Поле | Описание |
|------|----------|
| `name` | Имя параметра |
| `title` | Заголовок (умолч. = name) |
| `type` | Тип (см. таблицу типов) |
| `value` | Значение по умолчанию |
| `expression` | Выражение для вычисления |
| `availableAsField` | `false` — скрыть из полей |
| `useRestriction` | `true` — скрыть от пользователя |
| `use` | `"Always"`, `"Auto"` |

### Значения параметров по типу

| Тип | value | XML |
|-----|-------|-----|
| `StandardPeriod` | `"LastMonth"`, `"ThisYear"` и др. | `<v8:variant xsi:type="v8:StandardPeriodVariant">LastMonth</v8:variant>` |
| `date` | `"0001-01-01T00:00:00"` | `xsi:type="xs:dateTime"` |
| `string` | `"текст"` | `xsi:type="xs:string"` |
| `boolean` | `true`/`false` | `xsi:type="xs:boolean"` |

Стандартные варианты периодов: `Custom`, `Today`, `ThisWeek`, `ThisMonth`, `ThisQuarter`, `ThisYear`, `LastMonth`, `LastQuarter`, `LastYear`.

---

## 7. Вычисляемые поля (calculatedFields)

### Shorthand

```
"<dataPath> = <expression>"
```

```json
"calculatedFields": [
  "УИД = Строка(Ссылка.УникальныйИдентификатор())",
  "Итого = Количество * Цена"
]
```

### Объектная форма

```json
{
  "dataPath": "Итого",
  "expression": "Количество * Цена",
  "title": "Итого",
  "type": "decimal(15,2)",
  "restrict": ["noGroup"],
  "appearance": { "Формат": "ЧДЦ=2" }
}
```

---

## 8. Связи наборов (dataSetLinks)

Только объектная форма:

```json
"dataSetLinks": [
  {
    "source": "Периоды",
    "dest": "Данные",
    "sourceExpr": "Месяц",
    "destExpr": "Месяц",
    "parameter": "НачалоМесяца"
  }
]
```

| Поле | XML |
|------|-----|
| `source` | `<sourceDataSet>` |
| `dest` | `<destinationDataSet>` |
| `sourceExpr` | `<sourceExpression>` |
| `destExpr` | `<destinationExpression>` |
| `parameter` | `<parameter>` (опц.) |

---

## 9. Варианты настроек (settingsVariants)

```json
"settingsVariants": [{
  "name": "Основной",
  "presentation": "Основной вариант",
  "settings": {
    "selection": [...],
    "filter": [...],
    "order": [...],
    "outputParameters": {...},
    "dataParameters": [...],
    "structure": [...]
  }
}]
```

### selection

```json
"selection": [
  "Наименование",
  { "field": "Количество", "title": "Кол-во" },
  "Auto"
]
```

- Строка → `SelectedItemField`
- `"Auto"` → `SelectedItemAuto` (только на уровне группировок; на верхнем уровне settings игнорируется)
- Объект с `field`/`title` → `SelectedItemField` с `lwsTitle`

### filter

#### Shorthand-строка

```json
"filter": [
  "Организация = _ @off @user",
  "Дата >= 2024-01-01T00:00:00",
  "Статус filled",
  "Количество > 0"
]
```

Формат: `"<Поле> <оператор> [<значение>] [@off] [@user] [@quickAccess]"`.

- Значение `_` — пустое (placeholder, не выводится в XML)
- `@off` → `use=false`
- `@user` → `userSettingID=auto` (генерировать GUID)
- `@quickAccess` → `viewMode=QuickAccess`
- Типы значений автоопределяются: `true`/`false` → boolean, `2024-01-01T00:00:00` → dateTime, числа → decimal, прочее → string

#### Объектная форма

```json
"filter": [
  { "field": "Организация", "op": "=", "use": false, "userSettingID": "auto" },
  { "field": "Дата", "op": ">=", "value": "0001-01-01T00:00:00", "valueType": "xs:dateTime" },
  { "group": "Or", "items": [
    { "field": "Статус", "op": "=", "value": true, "valueType": "xs:boolean" },
    { "field": "Пометка", "op": "filled" }
  ]}
]
```

| Поле | Описание |
|------|----------|
| `field` | Имя поля |
| `op` | Оператор (см. таблицу) |
| `value` | Правая часть (опц.) |
| `valueType` | xsi:type для значения (опц.) |
| `use` | Включён (`true` по умолчанию) |
| `presentation` | Текст подсказки |
| `viewMode` | `"Normal"`, `"QuickAccess"`, `"Inaccessible"` |
| `userSettingID` | `"auto"` → генерировать GUID |

Операторы:

| DSL | XML comparisonType |
|-----|--------------------|
| `=` | `Equal` |
| `<>` | `NotEqual` |
| `>` | `Greater` |
| `>=` | `GreaterOrEqual` |
| `<` | `Less` |
| `<=` | `LessOrEqual` |
| `in` | `InList` |
| `notIn` | `NotInList` |
| `inHierarchy` | `InHierarchy` |
| `contains` | `Contains` |
| `notContains` | `NotContains` |
| `beginsWith` | `BeginsWith` |
| `filled` | `Filled` |
| `notFilled` | `NotFilled` |

Группа условий: `{ "group": "And"|"Or"|"Not", "items": [...] }` → `FilterItemGroup` с `groupType`.

### order

```json
"order": ["Количество desc", "Наименование", "Auto"]
```

- `"Field"` → `OrderItemField`, `orderType=Asc`
- `"Field desc"` → `OrderItemField`, `orderType=Desc`
- `"Field asc"` → `OrderItemField`, `orderType=Asc`
- `"Auto"` → `OrderItemAuto` (только на уровне группировок; на верхнем уровне settings игнорируется)

### outputParameters

```json
"outputParameters": {
  "Заголовок": "Мой отчёт",
  "ВыводитьЗаголовок": "Output",
  "МакетОформления": "ОформлениеОтчетовЧерноБелый"
}
```

Ключ → `dcscor:parameter`, значение → `dcscor:value`.

Типы значений определяются автоматически:
- `"Заголовок"` → `v8:LocalStringType`
- `"ВыводитьЗаголовок"`, `"ВыводитьПараметрыДанных"`, `"ВыводитьОтбор"` → `dcsset:DataCompositionTextOutputType`
- `"РасположениеПолейГруппировки"` → `dcsset:DataCompositionGroupFieldsPlacement`
- `"РасположениеРеквизитов"` → `dcsset:DataCompositionAttributesPlacement`
- `"ГоризонтальноеРасположениеОбщихИтогов"`, `"ВертикальноеРасположениеОбщихИтогов"` → `dcscor:DataCompositionTotalPlacement`
- Прочие → `xs:string`

### dataParameters

#### Shorthand-строка

```json
"dataParameters": [
  "Период = LastMonth @user",
  "Организация @off @user"
]
```

Формат: `"<Имя> [= <значение>] [@off] [@user] [@quickAccess] [@normal]"`.

- Значения-варианты периодов (`LastMonth`, `ThisYear` и др.) автоматически оборачиваются в `v8:StandardPeriod`
- `@off` → `use=false`, `@user` → `userSettingID=auto`

#### Объектная форма

```json
"dataParameters": [
  { "parameter": "Период", "value": { "variant": "LastMonth" }, "userSettingID": "auto" },
  { "parameter": "Организация", "use": false, "viewMode": "Normal", "userSettingID": "auto" }
]
```

### structure

#### String shorthand (рекомендуется для типичных случаев)

```json
"structure": "Организация > details"
"structure": "Организация > Номенклатура > details"
"structure": "Период > Организация > Номенклатура > details"
```

`>` разделяет уровни вложенности. Каждый сегмент — группировка по указанному полю. `details` (или `детали`) — детальные записи (пустой `groupBy`). Для каждого уровня `selection` и `order` автоматически `["Auto"]`.

#### Массив объектов

```json
"structure": [
  {
    "type": "group",
    "groupBy": ["Организация"],
    "children": [
      { "type": "group" }
    ]
  }
]
```

**Умолчания:** `selection` и `order` по умолчанию `["Auto"]` на каждом уровне (в группировках, строках/колонках таблиц, точках/сериях диаграмм). Указывать явно нужно только если требуется другой набор полей.

#### Группировка (group)

| Поле | Описание |
|------|----------|
| `type` | `"group"` |
| `name` | Имя группировки (опц.) |
| `groupBy` | Массив полей. Пусто/опущено = детальные записи |
| `groupType` | `"Items"` (умолч.), `"Hierarchy"`, `"HierarchyOnly"` |
| `selection` | Выборка (умолч. `["Auto"]`) |
| `filter` | Отборы (как в settings) |
| `order` | Сортировка (умолч. `["Auto"]`) |
| `outputParameters` | Параметры вывода (как в settings) |
| `children` | Вложенные элементы структуры |

Пустой `groupBy` (или `[]`) = детальные записи (без `groupItems` в XML).

#### Таблица (table)

```json
{
  "type": "table",
  "name": "Таблица",
  "rows": [
    { "groupBy": ["Номенклатура"], "selection": ["Auto"], "order": ["Auto"] }
  ],
  "columns": [
    { "groupBy": ["Период"], "selection": ["Auto"], "order": ["Auto"] }
  ]
}
```

#### Диаграмма (chart)

```json
{
  "type": "chart",
  "points": { "groupBy": ["Организация"], "order": ["Auto"] },
  "series": { "groupBy": ["Месяц"], "order": ["Auto"] },
  "selection": ["Сумма"]
}
```

---

## 10. Макеты и привязки (templates, groupTemplates)

Редко используются. Поддерживаются в объектной форме, близкой к XML.

### templates

```json
"templates": [
  {
    "name": "Макет1",
    "template": "<raw XML dcsat:AreaTemplate>",
    "parameters": [
      { "name": "ТипЦены", "expression": "Представление(ТипЦен)" }
    ]
  }
]
```

### groupTemplates

```json
"groupTemplates": [
  { "groupField": "ТипЦен", "templateType": "Header", "template": "Макет1" }
]
```

---

## 11. Полный пример — минимальный

```json
{
  "dataSets": [
    {
      "name": "НаборДанных1",
      "query": "ВЫБРАТЬ\n\tНоменклатура.Наименование КАК Наименование,\n\tКОЛИЧЕСТВО(1) КАК Количество\nИЗ\n\tСправочник.Номенклатура КАК Номенклатура\nСГРУППИРОВАТЬ ПО\n\tНоменклатура.Наименование",
      "fields": [
        { "dataPath": "Наименование", "title": "Наименование" },
        "Количество"
      ]
    }
  ],
  "totalFields": ["Количество: Сумма"],
  "settingsVariants": [{
    "name": "Основной",
    "settings": {
      "selection": ["Наименование", "Количество"],
      "structure": [{ "type": "group" }]
    }
  }]
}
```

## 12. Полный пример — средний (с shorthand v2)

```json
{
  "dataSets": [
    {
      "name": "Продажи",
      "query": "ВЫБРАТЬ\n\tПродажи.Организация,\n\tПродажи.Номенклатура,\n\tПродажи.Количество,\n\tПродажи.Сумма\nИЗ\n\tРегистрНакопления.Продажи КАК Продажи\n{ГДЕ\n\tПродажи.Период >= &ДатаНачала\n\tИ Продажи.Период < &ДатаОкончания}",
      "fields": [
        "Организация: СправочникСсылка.Организации @dimension",
        "Номенклатура: СправочникСсылка.Номенклатура @dimension",
        "Количество: число(15,3)",
        "Сумма: число(15,2)"
      ]
    }
  ],
  "totalFields": ["Количество: Сумма", "Сумма: Сумма"],
  "parameters": [
    "Период: СтандартныйПериод = LastMonth @autoDates"
  ],
  "settingsVariants": [{
    "name": "Основной",
    "presentation": "Продажи по организациям",
    "settings": {
      "selection": ["Номенклатура", "Количество", "Сумма", "Auto"],
      "filter": ["Организация = _ @off @user"],
      "order": ["Сумма desc", "Auto"],
      "outputParameters": {
        "Заголовок": "Анализ продаж",
        "ВыводитьЗаголовок": "Output"
      },
      "dataParameters": ["Период = LastMonth @user"],
      "structure": "Организация > details"
    }
  }]
}
```

**Сравнение с v1:** средний пример сократился с 58 до 33 строк (−43%). Основная экономия: `@autoDates` (−4 строки), structure shorthand (−9 строк), filter/dataParam shorthand (−4 строки).
